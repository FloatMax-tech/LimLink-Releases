import Foundation

@MainActor
public final class DeviceNamePreference {
    private static let storageKey = "limlink.customDeviceName"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Uses the caller's valid fallback when no valid custom name is stored.
    public func resolvedName(fallback: String) -> String {
        guard let stored = defaults.object(forKey: Self.storageKey) as? String,
              let name = try? Self.validatedName(stored) else {
            return fallback
        }
        return name
    }

    @discardableResult
    public func save(_ proposed: String) throws -> String {
        let name = try Self.validatedName(proposed)
        defaults.set(name, forKey: Self.storageKey)
        return name
    }

    public static func validatedName(_ proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { throw DeviceNameValidationError.empty }
        // Unicode format scalars include emoji joiners, which are valid in names.
        guard !name.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }) else {
            throw DeviceNameValidationError.invalidCharacters
        }
        guard name.utf8.count <= 63 else { throw DeviceNameValidationError.tooLong }
        return name
    }
}

private enum DeviceNameValidationError: LocalizedError, LocalizedMessageError {
    case empty
    case invalidCharacters
    case tooLong

    var errorDescription: String? { localizedMessage.text }

    var localizedMessage: LocalizedMessage {
        switch self {
        case .empty: L10n.message("设备名称不能为空。")
        case .invalidCharacters: L10n.message("设备名称不能包含换行或控制字符。")
        case .tooLong: L10n.message("设备名称太长，请缩短后重试。")
        }
    }
}
