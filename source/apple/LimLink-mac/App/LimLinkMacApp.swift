import LimLinkAppSupport
import SwiftUI

@main
struct LimLinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var folderStore: ReceiveFolderStore
    @State private var transfer: MacTransferModel
    @StateObject private var surfaces = ProgressSurfaces()

    init() {
        let folders = ReceiveFolderStore.live()
        _folderStore = StateObject(wrappedValue: folders)
        _transfer = State(initialValue: MacTransferModel(folderStore: folders))
    }

    var body: some Scene {
        WindowGroup("LimLink", id: MainWindowOpener.windowID) {
            RootView().appLanguage()
                .environment(\.limLinkTheme, .limLink)
                .environment(transfer)
                .environmentObject(folderStore)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["LIMLINK_STORE_SCREENSHOTS"] == "1" {
                        DispatchQueue.main.async {
                            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
                                  !window.styleMask.contains(.fullScreen) else { return }
                            window.toggleFullScreen(nil)
                        }
                    }
                    #endif
                    appDelegate.attach(transfer)
                    appDelegate.menuBar.makeContent = { [transfer, folderStore] in
                        let host = NSHostingController(rootView: MenuBarPanel().appLanguage()
                            .environment(transfer)
                            .environmentObject(folderStore))
                        host.sizingOptions = .preferredContentSize
                        return host
                    }
                    surfaces.attach(dock: appDelegate.dock, menuBar: appDelegate.menuBar)
                    surfaces.observe(transfer)
                }
                .task {
                    #if DEBUG
                    // The app-hosted StoreKit test creates its local session before it starts
                    // the purchase coordinator. Unrelated networking would show a system
                    // permission modal and leave it in front of later fixture UI tests.
                    if ProcessInfo.processInfo.environment["LIMLINK_ISOLATED_STOREKIT_HOST"] == "1" { return }
                    #endif
                    #if !LIMLINK_DIRECT_DISTRIBUTION
                    SupportPurchases.shared.start()
                    #endif
                    await transfer.start()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dock = DockTileController()
    let menuBar = MenuBarProgressController()
    private(set) var transfer: MacTransferModel?
    let notifications = MacNotifications()
    private var lastOfferID: String?
    private var sentNotifications = SentTransferNotificationTracker()
    private var bindingNotifications: MacBindingRequestObserver?
    private var receivedNotifications: MacReceiveCompletionObserver?

    func attach(_ model: MacTransferModel) {
        guard transfer !== model else { return }
        transfer = model
        notifications.install { [weak self] offerID, accept in
            self?.transfer?.decideOffer(id: offerID, accept: accept)
        }
        watchOffers()
        watchSentTransfer()
        bindingNotifications = MacBindingRequestObserver(
            requestID: { [weak model] in model?.bindingRequest?.id },
            isFrontmost: { NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } },
            present: { [weak self] in
                guard let self, let request = self.transfer?.bindingRequest else { return }
                self.menuBar.showPopover()
                self.notifications.bindingRequest(alias: request.alias, id: request.id)
            }
        )
        receivedNotifications = MacReceiveCompletionObserver(history: model.receiveCompletions) { [weak self] name in
            self?.notifications.received(fileName: name)
        }
    }

    private func watchSentTransfer() {
        guard let transfer else { return }
        let completed = withObservationTracking { transfer.recentSends } onChange: { [weak self] in
            Task { @MainActor in self?.watchSentTransfer() }
        }
        for sent in sentNotifications.unseenCompletions(completed) {
            notifications.delivered(fileName: sent.name, peer: sent.peer)
        }
    }

    /// Runs for the app's lifetime, also while the main window is closed. With no window in front,
    /// a new receive request opens the menu bar popover.
    private func watchOffers() {
        guard let transfer else { return }
        let current = withObservationTracking { transfer.offer?.id } onChange: { [weak self] in
            Task { @MainActor in self?.watchOffers() }
        }
        defer { lastOfferID = current }
        guard current != nil, current != lastOfferID else { return }
        let windowInFront = NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !windowInFront {
            menuBar.showPopover()
            if let offer = transfer.offer {
                notifications.offer(offer, saveLocation: offer.saveLocation ?? transfer.folderStore.decision.displayName)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        #if DEBUG
        snapshotWindowIfRequested()
        #endif
    }

    #if DEBUG
    /// For UI checks: writes the main window as a PNG named `LIMLINK_SNAPSHOT_PATH` into the
    /// app's temporary directory (inside the sandbox container), then quits.
    private func snapshotWindowIfRequested() {
        guard let name = ProcessInfo.processInfo.environment["LIMLINK_SNAPSHOT_PATH"] else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let view = NSApp.windows.first(where: { $0.canBecomeMain })?.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
    #endif
    func applicationWillTerminate(_ notification: Notification) { transfer?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindowOpener.shared.show() }
        return true
    }
}
