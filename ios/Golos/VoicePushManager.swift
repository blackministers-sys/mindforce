import Foundation
import PushKit

/// Receives VoIP pushes. iOS requires VoIP calls to be reported through CallKit.
final class VoicePushManager: NSObject, PKPushRegistryDelegate {
    static let shared = VoicePushManager()
    private var registry: PKPushRegistry?

    private override init() { super.init() }

    func start() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate credentials: PKPushCredentials,
                      for type: PKPushType) {
        VoiceCallManager.shared.credentialsUpdated(credentials)
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        NSLog("VoIP push token was invalidated; iOS will provide a replacement token when available.")
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        VoiceCallManager.shared.incomingPushReceived(payload)
        completion()
    }
}