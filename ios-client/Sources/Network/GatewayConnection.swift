import CryptoKit
import Combine
import Darwin
@preconcurrency import Foundation
import Security

@MainActor
final class GatewayConnection: NSObject, ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .unpaired
    @Published private(set) var lastError: String?
    @Published private(set) var lastMessageAt: Date?

    var connected: Bool { phase.isOnline }
    var onMessage: ((String, Data) -> Void)?
    var onReady: (() -> Void)?
    var onProtocolError: ((String) -> Void)?
    var onDiagnostic: ((String, String, String, [String: String]) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var lastIncomingSequence: UInt64 = 0
    private var pin = ""
    private var pairing: PairingMaterial?
    private var manualDisconnect = false
    private let hotspotHost = "172.20.10.1"
    private var endpointHosts: [String] = []
    private var endpointIndex = 0
    private var activeHost: String?

    func connect(_ pairing: PairingMaterial) {
        let configurationChanged = self.pairing.map {
            $0.document.gatewayId != pairing.document.gatewayId ||
            $0.document.host != pairing.document.host ||
            $0.document.port != pairing.document.port ||
            $0.clientPublicKey != pairing.clientPublicKey
        } ?? true
        if !configurationChanged,
           (phase == .connecting || phase == .authenticating || phase == .online) {
            diagnostic("connect_ignored", fields: ["reason": "attempt_already_active"])
            return
        }
        manualDisconnect = true
        closeTransport()
        manualDisconnect = false

        self.pairing = pairing
        if configurationChanged || endpointHosts.isEmpty {
            endpointHosts = candidateHosts(for: pairing)
            endpointIndex = 0
        }
        let host = endpointHosts[endpointIndex]
        activeHost = host
        pin = pairing.document.certificateSHA256.lowercased()
        sequence = 0
        lastIncomingSequence = 0
        lastError = nil
        phase = .connecting
        diagnostic("connect_started", fields: ["host": host,
                                                "port": String(pairing.document.port)])

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = Int(pairing.document.port)
        components.path = "/v1/control"
        guard let url = components.url else {
            diagnostic("invalid_gateway_address", level: "error")
            fail(ConnectionError.invalidGatewayAddress)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let socket = session!.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive()
    }

    func reconnect() {
        guard let pairing else { phase = .unpaired; return }
        manualDisconnect = true
        closeTransport()
        manualDisconnect = false
        endpointHosts = candidateHosts(for: pairing)
        endpointIndex = 0
        phase = .reconnecting
        connect(pairing)
    }

    func forget() {
        manualDisconnect = true
        pairing = nil
        endpointHosts = []
        endpointIndex = 0
        activeHost = nil
        closeTransport()
        lastError = nil
        phase = .unpaired
    }

    func requestSnapshot() {
        send(type: "snapshotRequest", payload: EmptyPayload())
    }

    func send<P: Codable & Sendable>(type: String, payload: P) {
        guard phase.isOnline else {
            lastError = "Gateway henüz komut almaya hazır değil."
            return
        }
        sendInternal(type: type, payload: payload, authenticated: true)
    }

    private func sendPair() {
        guard let pairing else { return }
        let command = PairCommand(clientId: UUID(), clientPublicKey: pairing.clientPublicKey,
                                  oneTimeCode: pairing.document.oneTimeCode)
        sendInternal(type: "pair", payload: command, authenticated: false)
    }

    private func sendInternal<P: Codable & Sendable>(type: String, payload: P, authenticated: Bool) {
        guard let task else { return }
        sequence += 1
        if type != "heartbeat" { diagnostic("message_sent", fields: ["type": type, "sequence": String(sequence)]) }
        do {
            let messageId = UUID()
            let auth: String?
            if authenticated, let secret = pairing?.sharedSecret {
                let payloadData = try JSONEncoder.k7Sorted.encode(payload)
                let payloadHash = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
                let signing = Data("\(type)|\(messageId.uuidString)|\(sequence)|\(payloadHash)".utf8)
                auth = Data(HMAC<SHA256>.authenticationCode(for: signing,
                    using: SymmetricKey(data: secret))).base64EncodedString()
            } else {
                auth = nil
            }
            let envelope = ControlEnvelope(type: type, messageId: messageId, sequence: sequence,
                                           payload: payload, auth: auth)
            let data = try JSONEncoder.k7.encode(envelope)
            task.send(.data(data)) { [weak self, weak task] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.task === task else { return }
                    self.handleTransportFailure(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func receive() {
        guard let task else { return }
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: self.receive(); return
                    }
                    self.process(data)
                    if self.task != nil { self.receive() }
                case .failure(let error):
                    self.handleTransportFailure(error)
                }
            }
        }
    }

    private func process(_ data: Data) {
        do {
            let header = try JSONDecoder.k7.decode(IncomingHeader.self, from: data)
            guard header.v == 1, header.sequence > lastIncomingSequence else {
                throw ConnectionError.replayedMessage
            }
            let sequenceGap = lastIncomingSequence != 0 && header.sequence != lastIncomingSequence + 1
            lastIncomingSequence = header.sequence
            lastMessageAt = Date()

            switch header.type {
            case "pairResult":
                let result = try JSONDecoder.k7.decode(ControlEnvelope<PairResultPayload>.self, from: data).payload
                guard result.gatewayId == pairing?.document.gatewayId else { throw ConnectionError.gatewayMismatch }
                phase = .online
                lastError = nil
                diagnostic("connection_online")
                startHeartbeat()
                onReady?()
            case "error":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<ErrorPayload>.self, from: data).payload
                lastError = value.message
                diagnostic("gateway_error", level: "error", fields: ["code": value.code, "message": value.message])
                onProtocolError?(value.message)
                if phase == .authenticating {
                    phase = .failed(value.message)
                    closeTransport()
                } else if value.code == "unauthorized" {
                    handleTransportFailure(ConnectionError.authenticationLost)
                }
            default:
                if header.type != "heartbeat" && header.type != "deviceStatus" {
                    diagnostic("message_received", fields: ["type": header.type,
                                                              "sequence": String(header.sequence)])
                }
                onMessage?(header.type, data)
            }
            if sequenceGap, phase.isOnline { requestSnapshot() }
        } catch {
            lastError = error.localizedDescription
            diagnostic("message_decode_failed", level: "error", fields: ["error": error.localizedDescription])
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.phase.isOnline else { return }
                self.sendInternal(type: "heartbeat", payload: HeartbeatPayload(activeCallId: nil), authenticated: true)
            }
        }
    }

    private func handleTransportFailure(_ error: Error) {
        guard !manualDisconnect else { return }
        closeTransport()
        lastError = error.localizedDescription
        diagnostic("transport_failed", level: "error", fields: ["error": error.localizedDescription])
        guard pairing != nil else { phase = .unpaired; return }
        if endpointHosts.count > 1 {
            let previous = activeHost ?? endpointHosts[endpointIndex]
            endpointIndex = (endpointIndex + 1) % endpointHosts.count
            let next = endpointHosts[endpointIndex]
            diagnostic("endpoint_fallback", level: "warning", fields: ["from": previous, "to": next])
        }
        phase = .reconnecting
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let pairing = self.pairing else { return }
            self.connect(pairing)
        }
    }

    private func candidateHosts(for pairing: PairingMaterial) -> [String] {
        let saved = pairing.document.host
        guard saved != hotspotHost else { return [hotspotHost] }
        return isOnGatewayHotspot() ? [hotspotHost, saved] : [saved, hotspotHost]
    }

    private func isOnGatewayHotspot() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        for pointer in Swift.sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0, String(cString: host).hasPrefix("172.20.10.") { return true }
        }
        return false
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        phase = .failed(error.localizedDescription)
        diagnostic("connection_failed", level: "error", fields: ["error": error.localizedDescription])
    }

    private func closeTransport() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func diagnostic(_ event: String, level: String = "info", fields: [String: String] = [:]) {
        onDiagnostic?("network", event, level, fields)
    }
}

extension GatewayConnection: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.phase = .authenticating
            self.diagnostic("websocket_open")
            self.sendPair()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            let message = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "WebSocket kapandı (\(closeCode.rawValue))."
            self.diagnostic("websocket_closed", level: "warning", fields: ["code": String(closeCode.rawValue)])
            self.handleTransportFailure(ConnectionError.closed(message))
        }
    }

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            guard self.session === session else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if digest == self.pin {
                self.diagnostic("certificate_pin_verified")
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                self.diagnostic("certificate_pin_rejected", level: "error")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

enum ConnectionError: LocalizedError {
    case invalidGatewayAddress, replayedMessage, gatewayMismatch, authenticationLost, closed(String)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayAddress: return "Gateway adresi geçerli değil."
        case .replayedMessage: return "Tekrarlanan gateway mesajı reddedildi."
        case .gatewayMismatch: return "Bağlanılan gateway eşleştirmeyle uyuşmuyor."
        case .authenticationLost: return "Gateway doğrulaması yenileniyor."
        case .closed(let message): return message
        }
    }
}
