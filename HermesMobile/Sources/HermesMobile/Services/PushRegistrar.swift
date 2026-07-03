import SwiftUI
import UIKit
import UserNotifications

/// Bridges UIKit's remote-notification callbacks into the SwiftUI app and
/// hands the APNs device token to the Mac relay. From then on the relay
/// pushes gate decisions straight to this phone anywhere — closed app,
/// cellular, the other side of the world — with Greenlight/Kill buttons
/// right on the notification. Requires the relay's ~/.hermes/apns.json key;
/// without it everything degrades gracefully to the existing local alerts.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            let relay = HermesRuntimeController.persistedRelayConfiguration()
            guard relay.isConfigured else { return }
            try? await HermesRelayClient(configuration: relay).registerPushToken(token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or missing entitlement — local notifications still cover
        // the app-open case, so this is not an error worth surfacing.
    }

    /// Ask for permission, then for a device token. Safe to call every
    /// launch — iOS dedupes, and a NEW token (reinstall, device restore)
    /// re-registers with the relay automatically.
    static func registerForPush() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
    }
}
