import Foundation
import CallKit
import Combine

/// Observes call state exposed by CallKit. This does not expose call audio.
@MainActor
final class CallMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published private(set) var hasActiveCall = false
    @Published private(set) var lastChangeAt: Date?
    @Published private(set) var callStateDescription = "Нет обнаруженного активного вызова"

    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        refresh()
    }

    private func refresh() {
        let calls = observer.calls
        hasActiveCall = calls.contains { !$0.hasEnded }
        if hasActiveCall {
            callStateDescription = calls.contains(where: { $0.hasConnected }) ?
                "Обнаружен активный разговор" : "Обнаружен вызов"
        } else {
            callStateDescription = "Нет обнаруженного активного вызова"
        }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        refresh()
        lastChangeAt = Date()
    }
}
