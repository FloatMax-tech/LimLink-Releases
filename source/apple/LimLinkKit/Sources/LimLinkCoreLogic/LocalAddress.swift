import Foundation

/// "本机地址" from protocol 1.2: current NIC addresses plus loopback `127.0.0.0/8` and `::1`.
public enum LocalAddressMatch {
    public static func isLocal(_ address: String, interfaceAddresses: Set<String>) -> Bool {
        let normalized = normalize(address)
        if isLoopback(normalized) { return true }
        let known = Set(interfaceAddresses.map(normalize))
        return known.contains(normalized)
    }

    public static func isLoopback(_ address: String) -> Bool {
        let value = normalize(address)
        if value == "::1" || value == "0:0:0:0:0:0:0:1" { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), UInt8(part) != nil else {
                return false
            }
            return true
        }
    }

    /// Fold presentation differences the protocol does not enumerate.
    ///
    /// // TODO(protocol §1.2): IPv4-mapped IPv6, scoped zone ids beyond a single `%`,
    /// and IPv6 with a trailing port are not specified. This only strips one pair of
    /// brackets, one zone id, and an IPv4 `:port`.
    public static func normalize(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<end])
        } else if ipv4PortSuffix(value) != nil {
            value = String(value[..<value.lastIndex(of: ":")!])
        }
        if let percent = value.firstIndex(of: "%") {
            value = String(value[..<percent])
        }
        return asciiFold(value)
    }

    private static func ipv4PortSuffix(_ value: String) -> Bool? {
        guard value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":") else { return nil }
        let host = value[..<colon]
        let port = value[value.index(after: colon)...]
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4, !port.isEmpty, port.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.allSatisfy({ $0 >= "0" && $0 <= "9" }) && UInt8(label) != nil
        }) else { return nil }
        return true
    }
}
