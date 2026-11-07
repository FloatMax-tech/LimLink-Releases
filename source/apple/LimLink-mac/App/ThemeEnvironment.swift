import AppKit
import SwiftUI

private struct LimLinkThemeKey: EnvironmentKey {
    static let defaultValue = LimLinkTheme.limLink
}

extension EnvironmentValues {
    var limLinkTheme: LimLinkTheme {
        get { self[LimLinkThemeKey.self] }
        set { self[LimLinkThemeKey.self] = newValue }
    }
}

enum BrandFont {
    static func font(token: BrandFontToken, style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        let resolved = BrandFontResolver.resolve(token: token, isRegistered: isRegistered)
        switch resolved {
        case .custom(let name):
            let size = NSFont.preferredFont(forTextStyle: nsTextStyle(style)).pointSize
            return Font.custom(name, size: size, relativeTo: style).weight(weight)
        case .system:
            return .system(style, weight: weight)
        }
    }

    static func isRegistered(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 12) != nil
    }

    private static func nsTextStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}
