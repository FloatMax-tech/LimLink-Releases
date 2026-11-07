import Foundation
import Observation

public enum AppLanguage {
    public static let supported = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it"]
    public static let names = ["zh-Hans": "简体中文", "zh-Hant": "繁體中文", "en": "English", "ja": "日本語", "ko": "한국어", "fr": "Français", "de": "Deutsch", "es": "Español", "it": "Italiano"]

    public static func resolve(_ preferredLanguages: [String]) -> String {
        for preferred in preferredLanguages {
            let parts = preferred.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let language = parts.first else { continue }
            if language == "zh" {
                if parts.contains("hant") { return "zh-Hant" }
                if parts.contains("hans") { return "zh-Hans" }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
            }
            if supported.contains(language) { return language }
        }
        return "en"
    }
}

/// Shared by views, background error formatting and notifications. No view or transfer model is
/// recreated when the selection changes. Defaults stay local to each app container; the share
/// extension follows its own system language even when files use the shared App Group inbox.
@Observable
public final class LanguagePreference: @unchecked Sendable {
    public static let shared = LanguagePreference()
    public static let storageKey = "limlink.language"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemLanguages: @Sendable () -> [String]
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var storedSelection: String

    public init(defaults: UserDefaults = .standard, systemLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages
        let saved = defaults.string(forKey: Self.storageKey) ?? "system"
        storedSelection = AppLanguage.supported.contains(saved) ? saved : "system"
    }

    public var selection: String {
        get {
            access(keyPath: \.selection)
            return lock.withLock { storedSelection }
        }
        set {
            let value = AppLanguage.supported.contains(newValue) ? newValue : "system"
            withMutation(keyPath: \.selection) {
                lock.withLock {
                    storedSelection = value
                    defaults.set(value, forKey: Self.storageKey)
                }
            }
        }
    }

    public var resolvedLanguage: String {
        let value = selection
        return value == "system" ? AppLanguage.resolve(systemLanguages()) : value
    }
    public var locale: Locale { Locale(identifier: resolvedLanguage) }

    /// Refresh system locale-dependent SwiftUI bodies when returning from Settings.
    public func refreshSystemLanguage() {
        withMutation(keyPath: \.selection) { }
    }
}

public enum L10n {
    public static var locale: Locale { LanguagePreference.shared.locale }

    public static func text(_ key: String, _ arguments: String...) -> String {
        localized(key, arguments: arguments)
    }

    public static func localized(_ key: String, arguments: [String] = [], language: String? = nil, bundle: Bundle = .main) -> String {
        let language = language ?? LanguagePreference.shared.resolvedLanguage
        let localizedBundle = bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let englishBundle = bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let fallback = englishBundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        let template = localizedBundle?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
        return interpolate(template, arguments: arguments)
    }

    /// One pass: braces, percent signs and language-like text in filenames stay verbatim.
    public static func interpolate(_ template: String, arguments: [String]) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let end = template[index...].firstIndex(of: "}"),
               let argument = Int(template[template.index(after: index)..<end]), arguments.indices.contains(argument) {
                result += arguments[argument]
                index = template.index(after: end)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }
}

/// Retains the source and arguments so an already-visible error changes language with the UI.
public struct LocalizedMessage: Equatable, Sendable, ExpressibleByStringLiteral {
    public let key: String
    public let arguments: [String]
    private let isVerbatim: Bool

    public init(_ key: String, arguments: [String] = [], verbatim: Bool = false) {
        self.key = key
        self.arguments = arguments
        self.isVerbatim = verbatim
    }
    public init(stringLiteral value: String) { self.init(value) }
    public static func verbatim(_ text: String) -> Self { .init(text, verbatim: true) }
    public var text: String { isVerbatim ? key : L10n.localized(key, arguments: arguments) }
}

extension L10n {
    public static func message(_ key: String, _ arguments: String...) -> LocalizedMessage {
        LocalizedMessage(key, arguments: arguments)
    }
}

public protocol LocalizedMessageError: Error {
    var localizedMessage: LocalizedMessage { get }
}

extension L10n {
    public static func error(_ error: Error) -> LocalizedMessage {
        (error as? any LocalizedMessageError)?.localizedMessage ?? .verbatim(error.localizedDescription)
    }
    public static func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false).locale(locale))
    }
}
