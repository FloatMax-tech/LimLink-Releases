public enum TXTError: Error, Sendable, Equatable {
    case entryTooLong(Int)
    case truncated
    case invalidUTF8
}

/// DNS-SD TXT as a case-insensitive map. Later duplicate keys win (RFC 6763).
public struct TXTFields: Hashable, Sendable {
    public var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        var folded: [String: String] = [:]
        for (key, value) in entries {
            folded[key.lowercased()] = value
        }
        self.entries = folded
    }

    public var fingerprint: String? { entries["fp"] }
    public var deviceType: String? { entries["dt"] }
    public var protocolVersions: String? { entries["pv"] }
    public var capabilities: String? { entries["cap"] }
    /// Raw `app` value. Nil when the key is absent.
    public var app: String? { entries["app"] }
    /// Provisional TXT `app`. Missing becomes `limlink`. Unrecognized values stay raw and fail the allow-list.
    public var normalizedApp: String {
        switch HostAppIdentity.observe(entries["app"]) {
        case .implicitLimlink:
            return LimLinkProtocol.defaultApp
        case .named(let value):
            return value
        case .unrecognized:
            return entries["app"] ?? ""
        }
    }
    public var inviting: Bool { entries["inv"] == "1" }

    public static func decodeWire(_ bytes: [UInt8]) throws -> TXTFields {
        var fields = TXTFields()
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count else { throw TXTError.truncated }
            let slice = bytes[index..<(index + length)]
            index += length
            if slice.isEmpty { continue }
            guard let text = String(bytes: slice, encoding: .utf8) else { throw TXTError.invalidUTF8 }
            let key: String
            let value: String
            if let equals = text.firstIndex(of: "=") {
                key = String(text[..<equals])
                value = String(text[text.index(after: equals)...])
            } else {
                key = text
                value = ""
            }
            fields.entries[key.lowercased()] = value
        }
        return fields
    }

    public func encodeWire(order: [String]? = nil) throws -> [UInt8] {
        let keys = order ?? entries.keys.sorted()
        var output = [UInt8]()
        for key in keys {
            guard let value = entries[key.lowercased()] else { continue }
            let text = Array("\(key)=\(value)".utf8)
            guard text.count <= 255 else { throw TXTError.entryTooLong(text.count) }
            output.append(UInt8(text.count))
            output.append(contentsOf: text)
        }
        return output
    }
}

/// TXT record this device advertises. `app` is always written. `inv=1` is omitted unless inviting.
public struct ServiceTXT: Hashable, Sendable {
    public var protocolVersions: [String]
    public var fingerprint: String
    public var deviceType: String
    public var capabilities: [String]
    public var inviting: Bool
    public var app: String

    public init(
        protocolVersions: [String] = ["1"],
        fingerprint: String,
        deviceType: String,
        capabilities: [String] = [],
        inviting: Bool = false,
        app: String
    ) {
        self.protocolVersions = protocolVersions
        self.fingerprint = fingerprint
        self.deviceType = deviceType
        self.capabilities = capabilities
        self.inviting = inviting
        self.app = app
    }

    public init(configurationFields fields: TXTFields) {
        self.protocolVersions = fields.protocolVersions?.split(separator: ",").map { String($0) } ?? []
        self.fingerprint = fields.fingerprint ?? ""
        self.deviceType = fields.deviceType ?? ""
        self.capabilities = fields.capabilities?.split(separator: ",").map { String($0) }.filter { !$0.isEmpty } ?? []
        self.inviting = fields.inviting
        self.app = fields.normalizedApp
    }

    public func encodeWire() throws -> [UInt8] {
        var pairs: [(String, String)] = [
            ("pv", protocolVersions.joined(separator: ",")),
            ("fp", fingerprint),
            ("dt", deviceType),
        ]
        if !capabilities.isEmpty {
            pairs.append(("cap", capabilities.joined(separator: ",")))
        }
        pairs.append(("app", app))
        if inviting {
            pairs.append(("inv", "1"))
        }
        var output = [UInt8]()
        for (key, value) in pairs {
            let text = Array("\(key)=\(value)".utf8)
            guard text.count <= 255 else { throw TXTError.entryTooLong(text.count) }
            output.append(UInt8(text.count))
            output.append(contentsOf: text)
        }
        return output
    }
}

/// Temporary Bonjour record while an invite code is on screen in stealth mode (15.3, 13:26).
/// Always includes `app`. The instance name is the display name and is not a TXT key.
///
/// // TODO(protocol §15.3): this record does not carry `fp`, so the 3.3 self-filter cannot use it.
public enum StealthInviteTXT {
    public static func encode(app: String) throws -> [UInt8] {
        let normalized = try HostAppIdentity.normalizeHostApp(app)
        let pairs = [("app", normalized), ("inv", "1")]
        var output = [UInt8]()
        for (key, value) in pairs {
            let text = Array("\(key)=\(value)".utf8)
            guard text.count <= 255 else { throw TXTError.entryTooLong(text.count) }
            output.append(UInt8(text.count))
            output.append(contentsOf: text)
        }
        return output
    }
}

public enum InstanceNameError: Error, Sendable, Equatable {
    case empty
}

/// Bonjour instance name: the host's display name, UTF-8, at most 63 bytes, cut on a character boundary.
public func bonjourInstanceName(_ displayName: String) throws -> String {
    let scalars = Array(displayName.utf8)
    if scalars.isEmpty { throw InstanceNameError.empty }
    if scalars.count <= LimLinkProtocol.maxInstanceNameUTF8Bytes {
        return displayName
    }
    var count = LimLinkProtocol.maxInstanceNameUTF8Bytes
    while count > 0 && scalars[count] & 0b1100_0000 == 0b1000_0000 {
        count -= 1
    }
    guard count > 0, let text = String(bytes: scalars[..<count], encoding: .utf8), !text.isEmpty else {
        throw InstanceNameError.empty
    }
    return text
}
