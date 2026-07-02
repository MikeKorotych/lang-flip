import Foundation
import UserNotifications

/// Tiny façade over UNUserNotificationCenter for the few places we
/// surface a banner to the user (OCR result, AI not-ready hint).
/// Authorization is requested lazily on first call so users who never
/// trigger an AI feature aren't prompted at all.
enum Notifications {

    private static var didRequestAuthorization = false

    static func show(title: String, body: String, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        let center = UNUserNotificationCenter.current()
        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert]) { _, _ in
                center.add(request, withCompletionHandler: nil)
            }
        } else {
            center.add(request, withCompletionHandler: nil)
        }
    }
}
