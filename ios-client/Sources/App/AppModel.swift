import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var call: GatewayCall?
    @Published var messages: [SMSMessage] = []
    @Published var device = DeviceStatus()
    @Published var countryCode = "+90"
    @Published var errorMessage: String?
    @Published var pairing: PairingMaterial?

    let connection = GatewayConnection()
    let calls = CallCoordinator()
    let pushes = PushCoordinator()
    let media = MediaEngine()

    init() {
        pairing = try? PairingStore.shared.load()
        connection.onMessage = { [weak self] type, data in self?.handle(type: type, data: data) }
        calls.command = { [weak self] type, command in self?.connection.send(type: type, payload: command) }
        calls.dialCommand = { [weak self] command in
            self?.call = GatewayCall(id: command.callId, handle: command.handle, displayName: nil, state: .dialing)
            self?.connection.send(type: "dial", payload: command)
        }
        calls.audioDeactivated = { [weak self] in self?.media.stop() }
        pushes.onIncomingCall = { [weak self] call, done in
            self?.calls.reportIncoming(call) { error in
                if let error { self?.errorMessage = error.localizedDescription }; done()
            }
            self?.connect()
        }
        pushes.onToken = { [weak self] token in Task { await self?.registerPushToken(token) } }
        connect()
    }

    func connect() { if let pairing { connection.connect(pairing) } }

    func pair(url: URL) {
        do { let document = try PairingStore.shared.parse(url: url); pairing = try PairingStore.shared.pair(document: document); connect() }
        catch { errorMessage = error.localizedDescription }
    }

    func dial(_ value: String) {
        do { try calls.startOutgoing(rawNumber: value, countryCode: countryCode) }
        catch { errorMessage = error.localizedDescription }
    }

    func sendSMS(handle: String, text: String) {
        guard let number = PhoneNumberPolicy.normalize(handle, countryCode: countryCode), !text.isEmpty else { errorMessage = "Numara veya mesaj geçersiz"; return }
        let id = UUID().uuidString
        messages.insert(SMSMessage(id: id, handle: number, text: text, date: Date(), isFromMe: true, state: .queued), at: 0)
        connection.send(type: "smsSend", payload: SMSSendCommand(smsId: id, handle: number, text: text))
    }

    func refreshSMS(cursor: String? = nil) { connection.send(type: "smsList", payload: SMSListCommand(cursor: cursor, limit: 50)) }

    private func handle(type: String, data: Data) {
        do {
            switch type {
            case "incomingCall":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<IncomingCallPayload>.self, from: data).payload
                call = GatewayCall(id: value.callId, handle: value.handle, displayName: value.displayName, state: .incoming)
                calls.reportIncoming(value)
            case "callUpdate":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<CallUpdatePayload>.self, from: data).payload
                if call?.id == value.callId { call?.state = value.state }; calls.reportUpdate(value)
            case "snapshot":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SnapshotPayload>.self, from: data).payload
                call = value.call; device = value.device
            case "smsPage":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SMSPagePayload>.self, from: data).payload
                var keyed = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }); value.items.forEach { keyed[$0.id] = $0 }
                messages = keyed.values.sorted { $0.date > $1.date }
            case "smsUpdate":
                let value = try JSONDecoder.k7.decode(ControlEnvelope<SMSUpdatePayload>.self, from: data).payload
                if let index = messages.firstIndex(where: { $0.id == value.smsId }) { messages[index].state = value.state }
            case "deviceStatus": device = try JSONDecoder.k7.decode(ControlEnvelope<DeviceStatus>.self, from: data).payload
            default: break
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func registerPushToken(_ token: String) async {
        guard !token.isEmpty, let pairing else { return }
        var request = URLRequest(url: pairing.document.relayURL.appending(path: "v1/registrations"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = ["gatewayId": pairing.document.gatewayId, "relaySecret": pairing.document.relaySecret,
            "deviceToken": token, "bundleId": Bundle.main.bundleIdentifier ?? "", "environment": "production"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do { let (_, response) = try await URLSession.shared.data(for: request); guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw URLError(.badServerResponse) } }
        catch { errorMessage = "Push kaydı başarısız: \(error.localizedDescription)" }
    }
}
