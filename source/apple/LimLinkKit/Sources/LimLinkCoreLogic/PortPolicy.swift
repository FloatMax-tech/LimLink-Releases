public enum PortChoice: Hashable, Sendable {
    case specified(UInt16)
    /// Bind port 0 and read back the port the system assigned.
    case systemAssigned
}

public enum PortDiagnosticCode: Hashable, Sendable {
    case primary
    case fallback(port: UInt16, offset: Int)
    case systemAssigned
}

/// Main HTTPS port: 52470, then +1…+9, then a system-assigned port (protocol section 10).
public enum MainPortPolicy {
    public static var primary: UInt16 { LimLinkProtocol.primaryPort }
    public static var lastFixed: UInt16 { LimLinkProtocol.primaryPort + UInt16(LimLinkProtocol.portFallbackCount) }

    public static func candidates() -> [PortChoice] {
        (0...LimLinkProtocol.portFallbackCount).map { offset in
            .specified(LimLinkProtocol.primaryPort + UInt16(offset))
        } + [.systemAssigned]
    }

    public static func select(occupied: Set<UInt16>) -> (choice: PortChoice, diagnostic: PortDiagnosticCode) {
        for offset in 0...LimLinkProtocol.portFallbackCount {
            let port = LimLinkProtocol.primaryPort + UInt16(offset)
            if occupied.contains(port) { continue }
            if offset == 0 {
                return (.specified(port), .primary)
            }
            return (.specified(port), .fallback(port: port, offset: offset))
        }
        return (.systemAssigned, .systemAssigned)
    }
}
