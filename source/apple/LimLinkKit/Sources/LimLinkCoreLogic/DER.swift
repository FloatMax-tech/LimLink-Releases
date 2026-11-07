enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ value: Int) -> [UInt8] {
        if value < 0x80 {
            return [UInt8(value)]
        }
        var rest = value
        var bytes: [UInt8] = []
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xff), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] {
        tlv(0x30, parts.flatMap { $0 })
    }

    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = magnitude
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tlv(0x02, bytes)
    }

    static func bitString(_ payload: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(0x03, [unusedBits] + payload)
    }

    static func octetString(_ payload: [UInt8]) -> [UInt8] {
        tlv(0x04, payload)
    }

    static func utf8(_ text: String) -> [UInt8] {
        tlv(0x0c, Array(text.utf8))
    }

    static func oid(_ body: [UInt8]) -> [UInt8] {
        tlv(0x06, body)
    }

    static func context(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(0xa0 | number, content)
    }

    struct Node {
        var tag: UInt8
        var content: [UInt8]
        var span: [UInt8]
    }

    static func readNode(_ bytes: ArraySlice<UInt8>) throws -> (node: Node, rest: ArraySlice<UInt8>) {
        var cursor = bytes.startIndex
        guard cursor < bytes.endIndex else { throw CertificateError.truncated }
        let tag = bytes[cursor]
        cursor = bytes.index(after: cursor)
        guard cursor < bytes.endIndex else { throw CertificateError.truncated }
        var length = Int(bytes[cursor])
        cursor = bytes.index(after: cursor)
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, bytes.distance(from: cursor, to: bytes.endIndex) >= count else {
                throw CertificateError.truncated
            }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor = bytes.index(after: cursor)
            }
        }
        guard bytes.distance(from: cursor, to: bytes.endIndex) >= length else { throw CertificateError.truncated }
        let contentEnd = bytes.index(cursor, offsetBy: length)
        let headerStart = bytes.startIndex
        let content = Array(bytes[cursor..<contentEnd])
        let span = Array(bytes[headerStart..<contentEnd])
        return (Node(tag: tag, content: content, span: span), bytes[contentEnd...])
    }

    static func children(_ content: [UInt8]) throws -> [Node] {
        var rest = content[...]
        var nodes: [Node] = []
        while !rest.isEmpty {
            let parsed = try readNode(rest)
            nodes.append(parsed.node)
            rest = parsed.rest
        }
        return nodes
    }
}

public enum CertificateError: Error, Sendable, Equatable {
    case truncated
    case unexpectedStructure
    case invalidPublicPoint
    case commonNameMissing
}
