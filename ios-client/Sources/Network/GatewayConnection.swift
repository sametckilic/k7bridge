import CryptoKit
import Foundation
import Security

@MainActor
final class GatewayConnection: NSObject, ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var lastError: String?
    var onMessage: ((String, Data) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sequence: UInt64 = 0
    private var lastIncomingSequence: UInt64 = 0
    private var pin = ""
    private var pairing: PairingMaterial?

    func connect(_ pairing: PairingMaterial) {
        disconnect()
        pin = pairing.document.certificateSHA256.lowercased()
        self.pairing = pairing
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        var components = URLComponents(); components.scheme = "wss"; components.host = pairing.document.host
        components.port = Int(pairing.document.port); components.path = "/v1/control"
        guard let url = components.url else { lastError = "Geçersiz gateway adresi"; return }
        task = session?.webSocketTask(with: url); task?.resume(); connected = true
        receive(); Task { await heartbeatLoop() }
        send(type: "pair", payload: PairCommand(clientId: UUID(), clientPublicKey: pairing.clientPublicKey, oneTimeCode: pairing.document.oneTimeCode), authenticated: false)
        send(type: "snapshotRequest", payload: EmptyPayload())
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil); task = nil; session = nil; connected = false
    }

    func send<P: Codable & Sendable>(type: String, payload: P, authenticated: Bool = true) {
        guard let task else { lastError = "Gateway bağlı değil"; return }
        sequence += 1
        do {
            let messageId = UUID()
            let auth: String?
            if authenticated, let secret = pairing?.sharedSecret {
                let payloadData = try JSONEncoder.k7Sorted.encode(payload)
                let payloadHash = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
                let signing = Data("\(type)|\(messageId.uuidString)|\(sequence)|\(payloadHash)".utf8)
                auth = Data(HMAC<SHA256>.authenticationCode(for: signing, using: SymmetricKey(data: secret))).base64EncodedString()
            } else { auth = nil }
            let data = try JSONEncoder.k7.encode(ControlEnvelope(type: type, messageId: messageId, sequence: sequence, payload: payload, auth: auth))
            task.send(.data(data)) { [weak self] error in
                if let error { Task { @MainActor in self?.lastError = error.localizedDescription; self?.connected = false } }
            }
        } catch { lastError = error.localizedDescription }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: return }
                    do {
                        let header = try JSONDecoder.k7.decode(IncomingHeader.self, from: data)
                        guard header.v == 1, header.sequence > self.lastIncomingSequence else { throw ConnectionError.replayedMessage }
                        if self.lastIncomingSequence != 0 && header.sequence != self.lastIncomingSequence + 1 { self.send(type: "snapshotRequest", payload: EmptyPayload()) }
                        self.lastIncomingSequence = header.sequence; self.onMessage?(header.type, data); self.receive()
                    } catch { self.lastError = error.localizedDescription; self.receive() }
                case .failure(let error): self.connected = false; self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled && task != nil {
            try? await Task.sleep(for: .seconds(5))
            if task != nil { send(type: "heartbeat", payload: HeartbeatPayload(activeCallId: nil)) }
        }
    }
}

extension GatewayConnection: URLSessionDelegate {
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            if digest == pin { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}

enum ConnectionError: Error { case replayedMessage }
