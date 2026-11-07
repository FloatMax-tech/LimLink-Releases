import LimLinkAppSupport
import UserNotifications
import UIKit

/// Notifications for events that happen while LimLink is not in front.
///
/// iOS does not let a local-network listener keep running in the background, so these can only
/// fire while the process is still alive (for example, an active transfer finishing, or an offer
/// that arrives in the short window after leaving the app). True background receiving would need
/// a push/relay server, which this app deliberately does not have.
@MainActor
final class LocalNotifications: NSObject {
    static let shared = LocalNotifications()

    private let center = UNUserNotificationCenter.current()
    private var prepared = false

    /// Asks for permission once. Skipped in UI tests so the system alert does not block them.
    func prepare() {
        guard !prepared,
              ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SCENARIO"] == nil,
              ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_SHARE"] == nil else { return }
        prepared = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func offerReceived(sender: String, fileName: String) {
        post(
            identifier: "offer-\(UUID().uuidString)",
            title: L10n.text("{0} 想发送文件", String(describing: sender)),
            body: L10n.text("{0} · 打开 LimLink 接收", String(describing: fileName)),
            thread: sender
        )
    }

    func transferDelivered(fileName: String, peer: String) {
        post(identifier: "sent-\(UUID().uuidString)", title: L10n.text("已送达 {0}", String(describing: peer)), body: fileName, thread: peer)
    }

    func fileReceived(fileName: String) {
        post(identifier: "received-\(UUID().uuidString)", title: L10n.text("已收到 {0}", String(describing: fileName)), body: L10n.text("已校验并保存"), thread: "received")
    }

    private func post(identifier: String, title: String, body: String, thread: String) {
        // Only useful when the person is looking at something else.
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

extension LocalNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
