import Observation
import AppKit
import LimLinkAppSupport
import UserNotifications

/// System notifications for receive requests and finished transfers while the window is not in
/// front. The app keeps running in the menu bar, so unlike iOS this also works when the window is
/// closed. Offers carry 接收 / 拒绝 actions.
@MainActor
final class MacNotifications: NSObject {
    static let offerCategory = "LIMLINK_OFFER"

    private let center = UNUserNotificationCenter.current()
    private var decide: ((String, Bool) -> Void)?
    private var installed = false

    func install(decide: @escaping (String, Bool) -> Void) {
        self.decide = decide
        guard !installed else { return }
        installed = true
        center.delegate = self
        updateCategories()
        observeLanguage()
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIMLINK_STORE_SCREENSHOTS"] == "1" { return }
        #endif
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func observeLanguage() {
        _ = withObservationTracking { LanguagePreference.shared.selection } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateCategories()
                self?.observeLanguage()
            }
        }
    }

    private func updateCategories() {
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.offerCategory,
                actions: [
                    UNNotificationAction(identifier: "ACCEPT", title: L10n.text("接收")),
                    UNNotificationAction(identifier: "REJECT", title: L10n.text("拒绝"), options: [.destructive]),
                ],
                intentIdentifiers: []
            )
        ])
    }

    func offer(_ offer: IncomingOffer, saveLocation: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("{0} 想发送文件", String(describing: offer.senderName))
        content.body = L10n.text("{0} · {1} · 保存到 {2}", String(describing: offer.fileName), String(describing: formatNotificationSize(offer.size)), String(describing: saveLocation))
        content.sound = .default
        content.categoryIdentifier = Self.offerCategory
        content.threadIdentifier = offer.senderName
        content.userInfo = ["offerID": offer.id]
        deliver(identifier: "offer-\(offer.id)", content: content)
    }

    func delivered(fileName: String, peer: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("已送达 {0}", String(describing: peer))
        content.body = fileName
        content.sound = .default
        deliver(identifier: "sent-\(UUID().uuidString)", content: content)
    }

    func bindingRequest(alias: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("设备绑定请求")
        content.body = alias + "\n" + L10n.text("确认绑定后，双方将自动接收彼此发送的文件。请确认这是你选择的设备，名称可自行修改。")
        content.sound = .default
        // Opening the notification only reveals the confirmation UI; it never grants consent.
        deliver(identifier: "binding-\(id)", content: content)
    }

    func received(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("已收到 {0}", String(describing: fileName))
        content.body = L10n.text("已校验并保存")
        deliver(identifier: "received-\(UUID().uuidString)", content: content)
    }

    private func deliver(identifier: String, content: UNMutableNotificationContent) {
        // The in-app panel already covers the case where the window is in front.
        guard !isFrontmost else { return }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private var isFrontmost: Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}

extension MacNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let offerID = response.notification.request.content.userInfo["offerID"] as? String
        let actionIdentifier = response.actionIdentifier
        await MainActor.run {
            MacNotificationResponseHandler.handle(
                offerID: offerID, actionIdentifier: actionIdentifier,
                decide: { self.decide?($0, $1) },
                openWindow: {
                    NSApp.activate(ignoringOtherApps: true)
                    MainWindowOpener.shared.show()
                }
            )
        }
    }
}

private func formatNotificationSize(_ bytes: Int) -> String {
    L10n.byteCount(Int64(bytes))
}
