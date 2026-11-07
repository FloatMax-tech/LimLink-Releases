public enum SASError: Error, Sendable, Equatable {
    case invalidLength
}

/// Six-digit pairing code from protocol 4.3. Computed in the Kit, not in the Rust core.
public enum SAS {
    public static func commit(nonceA: [UInt8]) -> [UInt8] {
        SHA256.hash(nonceA)
    }

    public static func compute(fpA: [UInt8], fpB: [UInt8], nonceA: [UInt8], nonceB: [UInt8]) throws -> String {
        guard fpA.count == 32, fpB.count == 32, nonceA.count == 32, nonceB.count == 32 else {
            throw SASError.invalidLength
        }
        var input = Array(LimLinkProtocol.sasLabel.utf8)
        input.append(contentsOf: fpA)
        input.append(contentsOf: fpB)
        input.append(contentsOf: nonceA)
        input.append(contentsOf: nonceB)
        let digest = SHA256.hash(input)
        let value = (UInt32(digest[0]) << 24)
            | (UInt32(digest[1]) << 16)
            | (UInt32(digest[2]) << 8)
            | UInt32(digest[3])
        let code = value % 1_000_000
        let digits = String(code)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    public static func sha256Hex(fpA: [UInt8], fpB: [UInt8], nonceA: [UInt8], nonceB: [UInt8]) throws -> String {
        guard fpA.count == 32, fpB.count == 32, nonceA.count == 32, nonceB.count == 32 else {
            throw SASError.invalidLength
        }
        var input = Array(LimLinkProtocol.sasLabel.utf8)
        input.append(contentsOf: fpA)
        input.append(contentsOf: fpB)
        input.append(contentsOf: nonceA)
        input.append(contentsOf: nonceB)
        return SHA256.hex(SHA256.hash(input))
    }
}
