import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var call: GatewayCall?
    @Published var messages: [SMSMessage] = []
    @Published var device = DeviceStatus()
    @Published var countryCode: String {
        didSet { UserDefaults.standard.set(countryCode, forKey: "defaultCountryCode") }
    }
    @Published var errorMessage: String?
    @Published var pairing: PairingMaterial?
    @Published var pairingNotice: String?
    @Published var lastStatusUpdate: Date?

    let connection = GatewayConnection()
    let calls = CallCoordinator()
    let pushes = PushCoordinator()
    let media = MediaEngine()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        countryCode = UserDefaults.standard.string(forKey: "defaultCountryCode") ?? "+90"
        pairing = try? PairingStore.shared.load()
        connection.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        calls.dialCommand = { [weak self] command in
            self?.call = GatewayCall(id: command.callId, handle: command.handle, displayName: nil, state: .dialing)
            self?.connection.send(type: "dial", payload: command)
        }
        calls.audioDeactivated = { [weak self] in self?.media.stop() }
        pushes.onIncomingCall = { [weak self] call, done in
            self?.calls.reportIncoming(call) { error in
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

    func dial(_ value: String) {
        guard connection.connected else { errorMessage = "Önce gateway bağlantısını kurun."; return }
        do { try calls.startOutgoing(rawNumber: value, countryCode: countryCode) }
        catch { errorMessage = error.localizedDescription }
    }

    func answer(_ callID: UUID) { calls.answer(callID) }
    func end(_ callID: UUID) { calls.end(callID) }

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

    private func handle(type: String, data: Data) {
        do {
            switch type {
            case "incomingCall":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<IncomingCallPayload>.self, from: data).payload
                call = GatewayCall(id: value.callId, handle: value.handle, displayName: value.displayName, state: .incoming)
                calls.reportIncoming(value)
            case "callUpdate":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<CallUpdatePayload>.self, from: data).payload
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
                let previousCallID = call?.id
                call = value.call
                device = value.device
                lastStatusUpdate = Date()
                if value.call?.state == .incoming, value.call?.id != previousCallID, let incoming = value.call {
                    calls.reportIncoming(IncomingCallPayload(callId: incoming.id, handle: incoming.handle,
                                                             displayName: incoming.displayName))
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
            default:
                break
            }
        } catch {
            errorMessage = "Gateway cevabı okunamadı: \(error.localizedDescription)"
        }
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
