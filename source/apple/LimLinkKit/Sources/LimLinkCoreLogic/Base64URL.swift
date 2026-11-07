enum Base64URL {
    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var output = [UInt8]()
        output.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let value = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8) | UInt32(bytes[index + 2])
            output.append(alphabet[Int((value >> 18) & 63)])
            output.append(alphabet[Int((value >> 12) & 63)])
            output.append(alphabet[Int((value >> 6) & 63)])
            output.append(alphabet[Int(value & 63)])
            index += 3
        }
        if index < bytes.count {
            var value = UInt32(bytes[index]) << 16
            if index + 1 < bytes.count {
                value |= UInt32(bytes[index + 1]) << 8
            }
            output.append(alphabet[Int((value >> 18) & 63)])
            output.append(alphabet[Int((value >> 12) & 63)])
            if index + 1 < bytes.count {
                output.append(alphabet[Int((value >> 6) & 63)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var map = [UInt8: UInt8](minimumCapacity: alphabet.count)
        for (index, symbol) in alphabet.enumerated() {
            map[symbol] = UInt8(index)
        }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ map[$0] != nil }) else { return nil }
        var output: [UInt8] = []
        var index = 0
        while index + 4 <= bytes.count {
            let value = (UInt32(map[bytes[index]]!) << 18)
                | (UInt32(map[bytes[index + 1]]!) << 12)
                | (UInt32(map[bytes[index + 2]]!) << 6)
                | UInt32(map[bytes[index + 3]]!)
            output.append(UInt8((value >> 16) & 0xff))
            output.append(UInt8((value >> 8) & 0xff))
            output.append(UInt8(value & 0xff))
            index += 4
        }
        let rest = bytes.count - index
        if rest == 0 { return output }
        if rest == 1 { return nil }
        let first = UInt32(map[bytes[index]]!) << 18
        let second = UInt32(map[bytes[index + 1]]!) << 12
        if rest == 2 {
            output.append(UInt8(((first | second) >> 16) & 0xff))
            return output
        }
        let third = UInt32(map[bytes[index + 2]]!) << 6
        let value = first | second | third
        output.append(UInt8((value >> 16) & 0xff))
        output.append(UInt8((value >> 8) & 0xff))
        return output
    }
}

/// TODO(protocol §5.3): session ids and the 128-bit token encoding are not specified.
/// This is unpadded base64url, the same convention as other raw byte fields.
public enum OpaqueToken {
    public static func encode(_ bytes: [UInt8]) -> String {
        Base64URL.encode(bytes)
    }
}
