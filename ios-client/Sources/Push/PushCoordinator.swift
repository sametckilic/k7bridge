import Foundation
import PushKit

@MainActor
final class PushCoordinator: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    var onToken: ((String) -> Void)?
    var onIncomingCall: ((IncomingCallPayload, @escaping () -> Void) -> Void)?

    override init() {
        super.init(); registry.delegate = self; registry.desiredPushTypes = [.voIP]
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in onToken?(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in onToken?("") }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        Task { @MainActor in
            guard let nonceString = payload.dictionaryPayload["nonce"] as? String,
                  let cipherString = payload.dictionaryPayload["envelope"] as? String,
                  let nonce = Data(base64Encoded: nonceString), let cipher = Data(base64Encoded: cipherString),
                  let call = try? PairingStore.shared.decryptPush(nonce: nonce, ciphertext: cipher) else { completion(); return }
            onIncomingCall?(call, completion)
        }
    }
}

