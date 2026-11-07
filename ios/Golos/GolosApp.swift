import SwiftUI
import UIKit

@main
struct GolosApp: App {
    @UIApplicationDelegateAdaptor(GolosAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class GolosAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        VoicePushManager.shared.start()
        return true
    }
}
