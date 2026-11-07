import LimLinkAppSupport
import SwiftUI

struct LanguagePicker: View {
    @Bindable private var preference = LanguagePreference.shared

    var body: some View {
        Picker(L10n.text("语言"), selection: $preference.selection) {
            Text(L10n.text("跟随系统")).tag("system")
            ForEach(AppLanguage.supported, id: \.self) { language in
                Text(verbatim: AppLanguage.names[language] ?? language).tag(language)
            }
        }
        .accessibilityIdentifier("settings.language")
    }
}

/// Locale propagation also updates system-provided SwiftUI controls, with stable view identity.
struct AppLanguageModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.locale, LanguagePreference.shared.locale)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { LanguagePreference.shared.refreshSystemLanguage() }
            }
    }
}

extension View {
    func appLanguage() -> some View { modifier(AppLanguageModifier()) }
}
