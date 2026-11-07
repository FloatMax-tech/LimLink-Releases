import LimLinkAppSupport
import SwiftUI

@main
struct LimLinkIOSApp: App {
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIMLINK_UI_TEST_RESET_LANGUAGE"] == "1" {
            LanguagePreference.shared.selection = "system"
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TransferHomeView().appLanguage()
                .task { SupportPurchases.shared.start() }
        }
    }
}
