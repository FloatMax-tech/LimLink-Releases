import Foundation

public enum FingerprintError: Error, Sendable, Equatable {
    case invalidLength
}

/// SHA-256 of the certificate SubjectPublicKeyInfo (DER), as defined in protocol 4.1.
public struct Fingerprint: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(rawSHA256 bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw FingerprintError.invalidLength }
        self.bytes = bytes
    }

    public init(spkiDER: [UInt8]) {
        self.bytes = SHA256.hash(spkiDER)
    }

    public init?(base64URL text: String) {
        guard let decoded = Base64URL.decode(text), decoded.count == 32 else { return nil }
        self.bytes = decoded
    }

    /// base64url, no padding. SHA-256 is 43 characters.
    public var base64URL: String {
        Base64URL.encode(bytes)
    }

    /// First 16 characters of `base64URL`, grouped by four.
    /// The protocol example `Ab3D-9xQk-...` abbreviates this; the ellipsis is not part of the text.
    public var displayGrouped: String {
        let prefix = base64URL.prefix(16)
        var groups: [String] = []
        var rest = Substring(prefix)
        while !rest.isEmpty {
            let take = rest.prefix(4)
            groups.append(String(take))
            rest = rest.dropFirst(take.count)
        }
        return groups.joined(separator: "-")
    }

    public var hex: String {
        SHA256.hex(bytes)
    }
}
