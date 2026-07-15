import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var call: GatewayCall?
    @Published var messages: [SMSMessage] = []
    @Published var device = DeviceStatus()
    @Published var countryCode: String {
        didSet {
            UserDefaults.standard.set(countryCode, forKey: "defaultCountryCode")
            contacts.updateCountryCode(countryCode)
        }
    }
    @Published var errorMessage: String?
    @Published var pairing: PairingMaterial?
    @Published var pairingNotice: String?
    @Published var lastStatusUpdate: Date?
    @Published private(set) var gatewayDiagnostics: [DiagnosticEntry] = []
    @Published private(set) var telephonyStatus: TelephonyBridgeStatus?
    @Published var diagnosticsNotice: String?

    let connection = GatewayConnection()
    let calls = CallCoordinator()
    let pushes = PushCoordinator()
    let media = MediaEngine()
    let contacts: ContactDirectory
    let diagnostics = ClientDiagnostics()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let savedCountryCode = UserDefaults.standard.string(forKey: "defaultCountryCode") ?? "+90"
        countryCode = savedCountryCode
        contacts = ContactDirectory(countryCode: savedCountryCode)
        pairing = try? PairingStore.shared.load()
        connection.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        contacts.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { self?.refreshCurrentCallName() }
            }
            .store(in: &cancellables)
        diagnostics.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        connection.onDiagnostic = { [weak self] component, event, level, fields in
            self?.diagnostics.record(component: component, event: event, level: level, fields: fields)
        }
        connection.onMessage = { [weak self] type, data in self?.handle(type: type, data: data) }
        connection.onReady = { [weak self] in
            guard let self else { return }
            do {
                if let pairing = self.pairing { try PairingStore.shared.store(pairing) }
                self.pairingNotice = "Gateway güvenli şekilde bağlandı."
            } catch {
                self.errorMessage = "Eşleştirme doğrulandı ancak kaydedilemedi: \(error.localizedDescription)"
            }
            self.refreshAll()
        }
        connection.onProtocolError = { [weak self] message in self?.errorMessage = message }
        calls.command = { [weak self] type, command in self?.connection.send(type: type, payload: command) }
        calls.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
        calls.onDiagnostic = { [weak self] event, level, fields in
            self?.diagnostics.record(component: "callkit", event: event, level: level, fields: fields)
        }
        calls.dialCommand = { [weak self] command in
            self?.call = GatewayCall(id: command.callId, handle: command.handle,
                                     displayName: self?.contacts.name(for: command.handle), state: .dialing)
            self?.connection.send(type: "dial", payload: command)
        }
        calls.audioDeactivated = { [weak self] in self?.media.stop() }
        pushes.onIncomingCall = { [weak self] call, done in
            let resolved = self?.resolvedIncoming(call) ?? call
            self?.call = GatewayCall(id: resolved.callId, handle: resolved.handle,
                                     displayName: resolved.displayName, state: .incoming)
            self?.calls.reportIncoming(resolved) { error in
                if let error { self?.errorMessage = error.localizedDescription }
                done()
            }
            self?.connect()
        }
        pushes.onToken = { [weak self] token in Task { await self?.registerPushToken(token) } }
        connect()
    }

    func connect() {
        guard let pairing else { return }
        connection.connect(pairing)
    }

    func pair(url: URL) {
        do {
            let document = try PairingStore.shared.parse(url: url)
            pairing = try PairingStore.shared.pair(document: document)
            pairingNotice = "Gateway doğrulanıyor…"
            connect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pair(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Eşleştirme metni geçerli bir bağlantı değil."
            return
        }
        pair(url: url)
    }

    func forgetGateway() {
        do {
            try PairingStore.shared.delete()
            connection.forget()
            pairing = nil
            pairingNotice = nil
            device = DeviceStatus()
            messages = []
            call = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateGatewayAddress(_ rawValue: String) -> Bool {
        let host = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = pairing,
              !host.isEmpty, host.count <= 253,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil else {
            errorMessage = "Gateway adresi geçerli değil. Yalnız IP adresi veya .local adı girin."
            return false
        }
        guard host != current.document.host else {
            connection.reconnect()
            return true
        }
        let document = PairingDocument(
            gatewayId: current.document.gatewayId,
            host: host,
            port: current.document.port,
            oneTimeCode: current.document.oneTimeCode,
            gatewayPublicKey: current.document.gatewayPublicKey,
            certificateSHA256: current.document.certificateSHA256,
            relayURL: current.document.relayURL,
            relaySecret: current.document.relaySecret
        )
        let updated = PairingMaterial(document: document,
                                      clientPrivateKey: current.clientPrivateKey,
                                      clientPublicKey: current.clientPublicKey,
                                      sharedSecret: current.sharedSecret)
        do {
            try PairingStore.shared.store(updated)
            pairing = updated
            pairingNotice = "Gateway adresi güncellendi; bağlantı yenileniyor…"
            diagnostics.record(component: "pairing", event: "gateway_address_updated",
                               fields: ["oldHost": current.document.host, "newHost": host])
            connection.connect(updated)
            return true
        } catch {
            errorMessage = "Gateway adresi kaydedilemedi: \(error.localizedDescription)"
            return false
        }
    }

    func dial(_ value: String) {
        guard connection.connected else { errorMessage = "Önce gateway bağlantısını kurun."; return }
        do { try calls.startOutgoing(rawNumber: value, countryCode: countryCode) }
        catch { errorMessage = error.localizedDescription }
    }

    func answer(_ callID: UUID) { calls.answer(callID) }
    func end(_ callID: UUID) { calls.end(callID) }

    func enableContacts() { contacts.requestAccess() }

    func rememberContact(_ selection: ContactSelection) {
        contacts.remember(name: selection.name, number: selection.number)
    }

    func displayName(for number: String) -> String? { contacts.name(for: number) }

    func applicationDidBecomeActive() {
        diagnostics.record(component: "lifecycle", event: "application_active")
        contacts.reloadIfAuthorized()
        if connection.connected { refreshAll() }
        else if pairing != nil, connection.phase != .connecting,
                connection.phase != .authenticating, connection.phase != .reconnecting {
            connection.reconnect()
        }
    }

    @discardableResult
    func sendSMS(handle: String, text: String) -> Bool {
        errorMessage = nil
        guard connection.connected else { errorMessage = "SMS göndermek için gateway bağlantısı gerekli."; return false }
        guard let number = PhoneNumberPolicy.normalize(handle, countryCode: countryCode),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Numara veya mesaj geçersiz."
            return false
        }
        let id = UUID().uuidString
        messages.insert(SMSMessage(id: id, handle: number, text: text, date: Date(), isFromMe: true, state: .queued), at: 0)
        connection.send(type: "smsSend", payload: SMSSendCommand(smsId: id, handle: number, text: text))
        return true
    }

    func refreshAll() {
        guard connection.connected else { return }
        connection.requestSnapshot()
        refreshSMS()
    }

    func refreshSMS(cursor: String? = nil) {
        guard connection.connected else { return }
        connection.send(type: "smsList", payload: SMSListCommand(cursor: cursor, limit: 50))
    }

    func refreshDiagnostics() {
        guard connection.connected else {
            diagnosticsNotice = "Tanı kayıtları için gateway bağlantısı gerekli."
            return
        }
        diagnostics.record(component: "diagnostics", event: "gateway_logs_requested")
        connection.send(type: "diagnosticsRequest", payload: DiagnosticsRequestPayload(limit: 300))
    }

    func copyDiagnostics() {
        let text = diagnostics.exportText(gatewayEntries: gatewayDiagnostics)
        guard !text.isEmpty else {
            diagnosticsNotice = "Henüz kopyalanacak tanı kaydı yok."
            return
        }
        UIPasteboard.general.string = text
        diagnosticsNotice = "Tanı kayıtları panoya kopyalandı."
    }

    var recentDiagnostics: [DiagnosticEntry] {
        Array((diagnostics.entries + gatewayDiagnostics).sorted { $0.timestamp > $1.timestamp }.prefix(20))
    }

    private func handle(type: String, data: Data) {
        do {
            switch type {
            case "incomingCall":
                let raw = try JSONDecoder.k7.decode(ControlEnvelope<IncomingCallPayload>.self, from: data).payload
                let value = resolvedIncoming(raw)
                diagnostics.record(component: "protocol", event: "incoming_call_received",
                                   fields: ["callId": value.callId.uuidString,
                                            "handlePresent": String(!value.handle.isEmpty)])
                call = GatewayCall(id: value.callId, handle: value.handle, displayName: value.displayName, state: .incoming)
                calls.reportIncoming(value)
            case "callUpdate":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<CallUpdatePayload>.self, from: data).payload
                diagnostics.record(component: "protocol", event: "call_update_received",
                                   fields: ["callId": value.callId.uuidString, "state": value.state.rawValue])
                if call?.id == value.callId { call?.state = value.state }
                calls.reportUpdate(value)
                if value.state == .ended || value.state == .failed {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        if self?.call?.id == value.callId { self?.call = nil }
                    }
                }
            case "snapshot":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SnapshotPayload>.self, from: data).payload
                let previousCall = call
                call = value.call
                if let current = call, let name = contacts.name(for: current.handle) {
                    call?.displayName = name
                }
                device = value.device
                lastStatusUpdate = Date()
                if let previousCall, value.call?.id != previousCall.id {
                    calls.reportUpdate(CallUpdatePayload(callId: previousCall.id, state: .ended,
                                                         reason: "gateway_snapshot"))
                }
                if value.call?.state == .incoming, value.call?.id != previousCall?.id, let incoming = value.call {
                    calls.reportIncoming(resolvedIncoming(IncomingCallPayload(callId: incoming.id,
                        handle: incoming.handle, displayName: incoming.displayName)))
                }
            case "smsPage":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SMSPagePayload>.self, from: data).payload
                var keyed = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                value.items.forEach { keyed[$0.id] = $0 }
                messages = keyed.values.sorted { $0.date > $1.date }
            case "smsUpdate":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SMSUpdatePayload>.self, from: data).payload
                if let index = messages.firstIndex(where: { $0.id == value.smsId }) {
                    messages[index].state = value.state
                }
                if let error = value.error { errorMessage = error }
            case "deviceStatus":
                device = try JSONDecoder.k7.decode(ControlEnvelope<DeviceStatus>.self, from: data).payload
                lastStatusUpdate = Date()
            case "diagnosticsPage":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<DiagnosticsPagePayload>.self, from: data).payload
                gatewayDiagnostics = value.entries
                telephonyStatus = value.telephonyStatus
                diagnosticsNotice = "\(value.entries.count) gateway kaydı alındı."
                diagnostics.record(component: "diagnostics", event: "gateway_logs_received",
                                   fields: ["count": String(value.entries.count)])
            default:
                break
            }
        } catch {
            errorMessage = "Gateway cevabı okunamadı: \(error.localizedDescription)"
            diagnostics.record(component: "protocol", event: "payload_decode_failed", level: "error",
                               fields: ["type": type, "error": error.localizedDescription])
        }
    }

    private func resolvedIncoming(_ value: IncomingCallPayload) -> IncomingCallPayload {
        let existing = value.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = contacts.name(for: value.handle) ?? (existing?.isEmpty == false ? existing : nil)
        return IncomingCallPayload(callId: value.callId, handle: value.handle, displayName: name)
    }

    private func refreshCurrentCallName() {
        guard var current = call, let name = contacts.name(for: current.handle), current.displayName != name else { return }
        current.displayName = name
        call = current
        calls.updateCall(current)
    }

    private func registerPushToken(_ token: String) async {
        guard !token.isEmpty, let pairing, pairing.document.relayURL.host != "example.invalid" else { return }
        var request = URLRequest(url: pairing.document.relayURL.appending(path: "v1/registrations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "gatewayId": pairing.document.gatewayId,
            "relaySecret": pairing.document.relaySecret,
            "deviceToken": token,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "environment": "production"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw URLError(.badServerResponse) }
        } catch {
            errorMessage = "Push kaydı başarısız: \(error.localizedDescription)"
        }
    }
}
