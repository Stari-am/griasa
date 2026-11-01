import Foundation
import UserNotifications

/// Griasa's banners: asks for permission the first time; a refusal or any
/// failure just means no banner. A banner can name the hub tab its click opens.
enum Notifier {
    static let tabKey = "openTab"

    static func post(title: String, body: String, opens tab: HubTab? = nil) {
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let tab { content.userInfo = [tabKey: tab.rawValue] }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Routes a click on a banner to the tab it names. Set once at launch.
    static func install() {
        UNUserNotificationCenter.current().delegate = Router.shared
    }

    private final class Router: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Router()

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let raw = response.notification.request.content.userInfo[Notifier.tabKey] as? String
            Task { @MainActor in
                if let raw, let tab = HubTab(rawValue: raw) { HubController.shared.open(tab) }
                completionHandler()
            }
        }

        /// Shown even while Griasa is the active app: it is a menu-bar app, so
        /// "active" says nothing about whether its window is in view.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner])
        }
    }
}
