import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: [UInt8]

    public init(method: String, target: String, headers: [String: String], body: [UInt8]) {
        var folded: [String: String] = [:]
        for (key, value) in headers {
            folded[key.lowercased()] = value
        }
        self.method = method
        self.target = target
        self.headers = folded
        self.body = body
    }

    public func value(for name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: [UInt8]

    public init(status: Int, headers: [String: String] = [:], body: [UInt8] = []) {
        var folded: [String: String] = [:]
        for (key, value) in headers {
            folded[key.lowercased()] = value
        }
        self.status = status
        self.headers = folded
        self.body = body
    }

    public func value(for name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct HTTPRequestLimits: Equatable, Sendable {
    /// Maximum bytes through the terminating CRLFCRLF, excluding the body.
    public var maximumHeaderBytes: Int?
    /// Maximum declared Content-Length, checked before waiting for the body.
    public var maximumBodyBytes: Int?
    /// Additional request-only caps, checked from the target before receiving a body.
    public var maximumBodyBytesByPathPrefix: [String: Int]

    public init(maximumHeaderBytes: Int? = nil, maximumBodyBytes: Int? = nil, maximumBodyBytesByPathPrefix: [String: Int] = [:]) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumBodyBytesByPathPrefix = maximumBodyBytesByPathPrefix
    }

    public static let unlimited = HTTPRequestLimits()
}

/// Response limits share the same independent header and body byte caps.
public typealias HTTPResponseLimits = HTTPRequestLimits

public enum HTTPCodecError: Error, Equatable, Sendable {
    case incomplete
    case malformed
    case headerTooLarge
    case bodyTooLarge
}

public enum HTTPCodec {
    public static func encode(_ request: HTTPRequest) -> [UInt8] {
        var headers = request.headers
        headers["content-length"] = String(request.body.count)
        return encode(start: "\(request.method) \(request.target) HTTP/1.1", headers: headers, body: request.body)
    }

    public static func encode(_ response: HTTPResponse) -> [UInt8] {
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        return encode(start: "HTTP/1.1 \(response.status) \(reason(response.status))", headers: headers, body: response.body)
    }

    public static func parseRequest(_ bytes: [UInt8], limits: HTTPRequestLimits = .unlimited) throws -> (HTTPRequest, Int) {
        let message = try parse(bytes, requestLimits: limits)
        let parts = message.start.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/1.1") else { throw HTTPCodecError.malformed }
        let request = HTTPRequest(
            method: String(parts[0]),
            target: String(parts[1]),
            headers: message.headers,
            body: message.body
        )
        return (request, message.consumed)
    }

    public static func parseResponse(_ bytes: [UInt8], limits: HTTPResponseLimits = .unlimited) throws -> (HTTPResponse, Int) {
        let message = try parse(bytes, responseLimits: limits)
        let parts = message.start.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "HTTP/1.1", let status = Int(parts[1]) else {
            throw HTTPCodecError.malformed
        }
        return (HTTPResponse(status: status, headers: message.headers, body: message.body), message.consumed)
    }

    private static func encode(start: String, headers: [String: String], body: [UInt8]) -> [UInt8] {
        var text = start + "\r\n"
        for key in headers.keys.sorted() {
            text += "\(key): \(headers[key] ?? "")\r\n"
        }
        text += "\r\n"
        var bytes = Array(text.utf8)
        bytes.append(contentsOf: body)
        return bytes
    }

    private static func parse(_ bytes: [UInt8], requestLimits: HTTPRequestLimits? = nil, responseLimits: HTTPResponseLimits? = nil) throws -> (start: String, headers: [String: String], body: [UInt8], consumed: Int) {
        let limits = requestLimits ?? responseLimits
        let searchEnd = min(bytes.count, max(0, limits?.maximumHeaderBytes ?? bytes.count))
        guard let headerEnd = find(bytes, pattern: [13, 10, 13, 10], from: 0, through: searchEnd) else {
            if let maximum = limits?.maximumHeaderBytes, bytes.count >= maximum {
                throw HTTPCodecError.headerTooLarge
            }
            throw HTTPCodecError.incomplete
        }
        let headerBytes = Array(bytes[..<headerEnd])
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else { throw HTTPCodecError.malformed }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let start = lines.first, !start.isEmpty else { throw HTTPCodecError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPCodecError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if requestLimits != nil {
                guard name != "transfer-encoding" else { throw HTTPCodecError.malformed }
                if name == "content-length", headers[name] != nil { throw HTTPCodecError.malformed }
            }
            headers[name] = value
        }
        let bodyStart = headerEnd + 4
        let declaredLength = headers["content-length"] ?? "0"
        if requestLimits != nil {
            guard !declaredLength.isEmpty, declaredLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                throw HTTPCodecError.malformed
            }
        }
        let length = Int(declaredLength) ?? -1
        guard length >= 0 else { throw HTTPCodecError.malformed }
        if let maximum = limits?.maximumBodyBytes, length > maximum {
            throw HTTPCodecError.bodyTooLarge
        }
        if let requestLimits, let target = start.split(separator: " ").dropFirst().first {
            for (prefix, maximum) in requestLimits.maximumBodyBytesByPathPrefix where target.hasPrefix(prefix) {
                if length > maximum { throw HTTPCodecError.bodyTooLarge }
            }
        }
        let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(length)
        guard !overflow else { throw HTTPCodecError.malformed }
        guard bytes.count >= bodyEnd else { throw HTTPCodecError.incomplete }
        let body = Array(bytes[bodyStart..<bodyEnd])
        return (start, headers, body, bodyEnd)
    }

    private static func find(_ bytes: [UInt8], pattern: [UInt8], from start: Int, through end: Int) -> Int? {
        guard pattern.count > 0, start >= 0, end >= pattern.count, end <= bytes.count else { return nil }
        let lastStart = end - pattern.count
        var index = start
        while index <= lastStart {
            if pattern.indices.allSatisfy({ bytes[index + $0] == pattern[$0] }) { return index }
            index += 1
        }
        return nil
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        default: return "Status"
        }
    }
}

public enum JSONWire {
    public static func data(_ object: [String: Any]) -> [UInt8] {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return Array("{}".utf8)
        }
        return [UInt8](data)
    }

    public static func object(_ bytes: [UInt8]) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(bytes)),
              let object = value as? [String: Any] else { return nil }
        // Foundation may round a fractional JSON token before NSNumber reaches `int`.
        // All numeric fields in this wire protocol are integers. Canonicalize them from
        // their original text; invalid integers stay present as null so callers can reject them.
        let exactBytes = exactIntegerJSON(bytes)
        if exactBytes == bytes { return object }
        return (try? JSONSerialization.jsonObject(with: Data(exactBytes))) as? [String: Any]
    }

    public static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    public static func int(_ object: [String: Any], _ key: String) -> Int? {
        guard let value = object[key] else { return nil }
        // JSON true/false bridges to Int. On swift-corelibs, the integers 0 and 1 also bridge to Bool.
        if isBoolean(value) { return nil }
        guard let number = value as? NSNumber else { return nil }
        return exactInteger(number.stringValue)
    }

    /// Runs only after Foundation has validated the JSON grammar. Strings (including
    /// escapes) are copied verbatim; only numeric tokens are rewritten.
    private static func exactIntegerJSON(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                result.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                index += 1
            } else if byte == 45 || (48...57).contains(byte) {
                let start = index
                repeat { index += 1 }
                while index < bytes.count && ((48...57).contains(bytes[index]) || [45, 43, 46, 69, 101].contains(bytes[index]))
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                let replacement = exactInteger(token).map(String.init) ?? "null"
                result.append(contentsOf: replacement.utf8)
            } else {
                if byte == 34 { inString = true }
                result.append(byte)
                index += 1
            }
        }
        return result
    }

    /// Decimal arithmetic on the token avoids both Double rounding and Int overflow.
    private static func exactInteger(_ text: String) -> Int? {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count <= 2 else { return nil }
        var mantissa = String(parts[0])
        let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        let coefficient = decimal.joined()
        guard !coefficient.isEmpty, coefficient.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var digits = String(coefficient.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let fractionalDigits = decimal.count == 2 ? decimal[1].count : 0
        let (shift, overflow) = exponent.subtractingReportingOverflow(fractionalDigits)
        guard !overflow else { return nil }
        if shift >= 0 {
            let maximumDigits = String(Int.max).count
            guard digits.count <= maximumDigits, shift <= maximumDigits - digits.count else { return nil }
            digits.append(contentsOf: repeatElement(Character("0"), count: shift))
        } else {
            guard shift >= -digits.count else { return nil }
            let removed = -shift
            guard digits.suffix(removed).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(removed)
        }
        return Int((negative ? "-" : "") + digits)
    }

    /// A JSON boolean. Not the integers 0 and 1, which corelibs also reports as `Bool`.
    static func isBoolean(_ value: Any) -> Bool {
        guard value is Bool else { return false }
        guard let number = value as? NSNumber else { return true }
        let encoding = String(cString: number.objCType)
        return encoding == "c" || encoding == "B"
    }

    public static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        guard let value = object[key], isBoolean(value) else { return nil }
        return value as? Bool
    }
}

public enum FileDigest {
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hex(SHA256.hash(bytes))
    }

    /// Receiver compares without case. A bad length or a non-hex character is `E_BAD_REQUEST`.
    public static func parse(_ field: String) -> Result<String, ProtocolError> {
        let folded = asciiFold(field)
        let hex = folded.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
        guard folded.count == 64, hex else {
            return .failure(ProtocolError(code: .badRequest, httpStatus: 400, retryable: false))
        }
        return .success(folded)
    }
}

public enum HalfFilePaths {
    public static let incomingDirectory = ".limlink-incoming"
    public static let partSuffix = ".limlink-part"

    public static func partFileName(_ finalName: String) -> String {
        finalName + partSuffix
    }
}
