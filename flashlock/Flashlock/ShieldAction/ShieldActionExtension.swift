import Foundation
import ManagedSettings
import UserNotifications

/// Handles taps on the shield's buttons (docs/02-architecture.md §2.2).
///
/// There is no supported way to open the containing app from this extension on
/// iOS ≤ 26.4, so the primary button records a pending gate request in the App
/// Group and posts a local notification whose tap deep-links into the gate
/// (the "notification dance"). The app also checks `pendingGateRequest` on
/// every foreground, so the flow works even if the notification is suppressed
/// by Focus or never tapped.
final class ShieldActionExtension: ShieldActionDelegate {

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, completionHandler: completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handle(action: action, completionHandler: completionHandler)
    }

    /// Shared handler: the response never depends on which token was shielded.
    private func handle(
        action: ShieldAction,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            // NOTE: iOS 26.5 added ShieldActionResponse.openParentalControlsApp,
            // the official way to open Flashlock directly from the shield.
            // Building it requires the iOS 26.5 SDK, so it is left commented
            // out until the project's toolchain is on that SDK; enable with:
            //
            //   if #available(iOS 26.5, *) {
            //       completionHandler(.openParentalControlsApp)
            //       return
            //   }
            //
            // Until then, fall through to the notification path unconditionally
            // (on 26.5+ devices it still works — just with one extra tap).
            SharedStore().pendingGateRequest = PendingGateRequest(requestedAt: Date())
            postGateNotification()
            completionHandler(.close)

        case .secondaryButtonPressed:
            // The shield renders no secondary button (label is nil), but the
            // system may still deliver the case; leave the shield as-is.
            completionHandler(.none)

        @unknown default:
            completionHandler(.none)
        }
    }

    /// Local notification that deep-links into the gate flow. NOTE: posting
    /// from a shield-action extension is a widely used community pattern but
    /// is not officially documented by Apple; it requires the app to have
    /// obtained notification permission, and delivery can be delayed or
    /// suppressed by Focus — the App Group `pendingGateRequest` is the backup.
    private func postGateNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Earn time back"
        content.body = "Tap to practice your flashcards and unlock your apps."
        content.sound = .default
        content.userInfo = ["url": "flashlock://gate"]

        let request = UNNotificationRequest(
            identifier: "com.flashlock.app.gate",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
