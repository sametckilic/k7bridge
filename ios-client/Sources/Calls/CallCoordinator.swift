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
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: call.handle)
        update.localizedCallerName = call.displayName?.isEmpty == false ? call.displayName : nil
        update.hasVideo = false
        provider.reportNewIncomingCall(with: call.callId, update: update, completion: completion)
    }

    func startOutgoing(rawNumber: String, countryCode: String) throws {
        guard let number = PhoneNumberPolicy.normalize(rawNumber, countryCode: countryCode) else { throw CallError.invalidNumber }
        let id = UUID()
        let handle = CXHandle(type: .phoneNumber, value: number)
        let transaction = CXTransaction(action: CXStartCallAction(call: id, handle: handle))
        controller.request(transaction) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in self?.dialCommand?(DialCommand(callId: id, handle: number)) }
        }
    }

    func reportUpdate(_ update: CallUpdatePayload) {
        switch update.state {
        case .connecting: provider.reportOutgoingCall(with: update.callId, startedConnectingAt: Date())
        case .active: provider.reportOutgoingCall(with: update.callId, connectedAt: Date())
        case .ended: provider.reportCall(with: update.callId, endedAt: Date(), reason: .remoteEnded)
        case .failed: provider.reportCall(with: update.callId, endedAt: Date(), reason: .failed)
        default: break
        }
    }
}

extension CallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in audioDeactivated?() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in command?("answer", CallCommand(callId: action.callUUID)); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in command?("end", CallCommand(callId: action.callUUID)); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in audioActivated?() } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in audioDeactivated?() } }
}

enum CallError: LocalizedError { case invalidNumber
    var errorDescription: String? { "Geçersiz veya acil numara uzaktan çevrilemez." }
}

