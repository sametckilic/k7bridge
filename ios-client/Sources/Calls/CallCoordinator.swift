import AVFAudio
import CallKit
import Foundation

@MainActor
final class CallCoordinator: NSObject, ObservableObject {
    let provider: CXProvider
    private let controller = CXCallController()
    var command: ((String, CallCommand) -> Void)?
    var dialCommand: ((DialCommand) -> Void)?
    var audioActivated: (() -> Void)?
    var audioDeactivated: (() -> Void)?
    var muteChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onDiagnostic: ((String, String, [String: String]) -> Void)?
    private(set) var audioSessionActive = false
    private var incomingCallIDs: Set<UUID> = []
    private var incomingOriginIDs: Set<UUID> = []
    private var reportedCallIDs: Set<UUID> = []
    private var pendingEndCallIDs: Set<UUID> = []

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "K7Bridge")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(_ call: IncomingCallPayload, completion: @escaping (Error?) -> Void = { _ in }) {
        guard reportedCallIDs.insert(call.callId).inserted else { completion(nil); return }
        diagnostic("incoming_report_requested", fields: ["callId": call.callId.uuidString])
        incomingCallIDs.insert(call.callId)
        incomingOriginIDs.insert(call.callId)
        let update = CXCallUpdate()
        update.remoteHandle = callKitHandle(call.handle)
        update.localizedCallerName = call.displayName?.isEmpty == false ? call.displayName : nil
        update.hasVideo = false
        provider.reportNewIncomingCall(with: call.callId, update: update) { [weak self] error in
            Task { @MainActor in
                if error != nil {
                    self?.incomingCallIDs.remove(call.callId)
                    self?.reportedCallIDs.remove(call.callId)
                }
                self?.diagnostic(error == nil ? "incoming_reported" : "incoming_report_failed",
                                 level: error == nil ? "info" : "error",
                                 fields: ["callId": call.callId.uuidString,
                                          "error": error?.localizedDescription ?? ""])
                completion(error)
            }
        }
    }

    func startOutgoing(rawNumber: String, countryCode: String) throws {
        guard let number = PhoneNumberPolicy.normalize(rawNumber, countryCode: countryCode) else { throw CallError.invalidNumber }
        let id = UUID()
        diagnostic("outgoing_requested", fields: ["callId": id.uuidString])
        let handle = CXHandle(type: .phoneNumber, value: number)
        let transaction = CXTransaction(action: CXStartCallAction(call: id, handle: handle))
        controller.request(transaction) { [weak self] error in
            Task { @MainActor in
                if let error { self?.onError?(error); return }
                self?.reportedCallIDs.insert(id)
                self?.dialCommand?(DialCommand(callId: id, handle: number))
            }
        }
    }

    func answer(_ callID: UUID) {
        request(CXAnswerCallAction(call: callID), kind: "answer")
    }

    func end(_ callID: UUID) {
        guard reportedCallIDs.contains(callID) else {
            diagnostic("transaction_skipped", fields: ["callId": callID.uuidString,
                                                        "kind": "end",
                                                        "reason": "call_not_reported"])
            return
        }
        guard pendingEndCallIDs.insert(callID).inserted else {
            diagnostic("transaction_skipped", fields: ["callId": callID.uuidString,
                                                        "kind": "end",
                                                        "reason": "already_pending"])
            return
        }
        request(CXEndCallAction(call: callID), kind: "end")
    }

    func setMuted(_ muted: Bool, callID: UUID) {
        request(CXSetMutedCallAction(call: callID, muted: muted), kind: "mute")
    }

    private func request(_ action: CXCallAction, kind: String) {
        let callID = action.callUUID
        guard reportedCallIDs.contains(callID) else {
            pendingEndCallIDs.remove(callID)
            diagnostic("transaction_skipped", fields: ["callId": callID.uuidString,
                                                        "kind": kind,
                                                        "reason": "call_not_reported"])
            return
        }
        controller.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if kind == "end" { self.pendingEndCallIDs.remove(callID) }
                guard let error else { return }
                let value = error as NSError
                self.diagnostic("transaction_failed", level: "warning",
                                fields: ["callId": callID.uuidString,
                                         "kind": kind,
                                         "domain": value.domain,
                                         "code": String(value.code)])
                if self.isUnknownCallUUID(error) {
                    self.forgetCall(callID)
                    return
                }
                self.onError?(error)
            }
        }
    }

    private func isUnknownCallUUID(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == CXErrorDomainRequestTransaction &&
            value.code == CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue
    }

    private func forgetCall(_ callID: UUID) {
        incomingCallIDs.remove(callID)
        incomingOriginIDs.remove(callID)
        reportedCallIDs.remove(callID)
        pendingEndCallIDs.remove(callID)
    }

    func reportUpdate(_ update: CallUpdatePayload) {
        diagnostic("state_received", fields: ["callId": update.callId.uuidString,
                                               "state": update.state.rawValue])
        switch update.state {
        case .connecting:
            if !incomingOriginIDs.contains(update.callId) {
                provider.reportOutgoingCall(with: update.callId, startedConnectingAt: Date())
            }
        case .active:
            if !incomingOriginIDs.contains(update.callId) {
                provider.reportOutgoingCall(with: update.callId, connectedAt: Date())
            }
        case .ended:
            if reportedCallIDs.contains(update.callId) {
                provider.reportCall(with: update.callId, endedAt: Date(), reason: .remoteEnded)
            }
            forgetCall(update.callId)
        case .failed:
            if reportedCallIDs.contains(update.callId) {
                provider.reportCall(with: update.callId, endedAt: Date(), reason: .failed)
            }
            forgetCall(update.callId)
        default: break
        }
    }

    func updateCall(_ call: GatewayCall) {
        let update = CXCallUpdate()
        update.remoteHandle = callKitHandle(call.handle)
        update.localizedCallerName = call.displayName
        update.hasVideo = false
        provider.reportCall(with: call.id, updated: update)
    }

    private func callKitHandle(_ value: String) -> CXHandle {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CXHandle(type: .generic, value: "Gizli numara") }
        return CXHandle(type: .phoneNumber, value: trimmed)
    }

    private func diagnostic(_ event: String, level: String = "info", fields: [String: String] = [:]) {
        onDiagnostic?(event, level, fields)
    }
}

extension CallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            incomingCallIDs.removeAll(); incomingOriginIDs.removeAll(); reportedCallIDs.removeAll()
            pendingEndCallIDs.removeAll()
            audioSessionActive = false; audioDeactivated?()
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            incomingCallIDs.remove(action.callUUID)
            diagnostic("answer_action", fields: ["callId": action.callUUID.uuidString])
            command?("answer", CallCommand(callId: action.callUUID)); action.fulfill()
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let type = incomingCallIDs.remove(action.callUUID) != nil ? "reject" : "end"
            diagnostic("end_action", fields: ["callId": action.callUUID.uuidString, "type": type])
            command?(type, CallCommand(callId: action.callUUID)); action.fulfill()
            forgetCall(action.callUUID)
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            diagnostic("mute_action", fields: ["callId": action.callUUID.uuidString,
                                                "muted": String(action.isMuted)])
            muteChanged?(action.isMuted)
            action.fulfill()
        }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in audioSessionActive = true; audioActivated?() }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in audioSessionActive = false; audioDeactivated?() }
    }
}

enum CallError: LocalizedError { case invalidNumber
    var errorDescription: String? { "Geçersiz veya acil numara uzaktan çevrilemez." }
}
