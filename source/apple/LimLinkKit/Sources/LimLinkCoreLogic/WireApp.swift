import Foundation

public struct HelloBody: Equatable, Sendable {
    public var alias: String?
    public var devType: String?
    public var port: Int?
    /// Absent on the wire means `limlink`. Responses we send always set this.
    public var app: String?
    public var appPresent: Bool
    public var trusted: Bool?
    public var busy: Bool?

    public init(
        alias: String? = nil,
        devType: String? = nil,
        port: Int? = nil,
        app: String? = nil,
        appPresent: Bool,
        trusted: Bool? = nil,
        busy: Bool? = nil
    ) {
        self.alias = alias
        self.devType = devType
        self.port = port
        self.app = app
        self.appPresent = appPresent
        self.trusted = trusted
        self.busy = busy
    }
}

/// Outbound `app` is always written. A missing inbound value still means `limlink`.
public enum WireApp {
    public static func header(app: String) -> (String, String) {
        (LimLinkProtocol.appHeader, app)
    }

    public static func helloRequest(
        app: String,
        alias: String,
        devType: String,
        port: Int,
        hostHeader: String,
        bindingID: String? = nil
    ) -> HTTPRequest {
        var object: [String: Any] = [
            "proto": ["1.0"],
            "alias": alias,
            "devType": devType,
            "port": port,
            "app": app,
        ]
        if app == "limlink" {
            object["caps"] = ["binding-v1"]
            if let bindingID { object["bindingId"] = bindingID }
        }
        let body = JSONWire.data(object)
        return request(method: "POST", path: "/limlink/v1/hello", app: app, hostHeader: hostHeader, body: body, json: true)
    }

    public static func helloResponse(app: String, alias: String, devType: String, port: Int, trusted: Bool, busy: Bool) -> HTTPResponse {
        let body = JSONWire.data([
            "proto": ["1.0"],
            "alias": alias,
            "devType": devType,
            "port": port,
            "app": app,
            "trusted": trusted,
            "busy": busy,
        ])
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }

    public static func inviteHelloResponse(
        app: String,
        inviteSessionId: String,
        nonceS: String,
        alias: String,
        inviteAgeSec: Int,
        suite: String
    ) -> HTTPResponse {
        let body = JSONWire.data([
            "inviteSessionId": inviteSessionId,
            "nonceS": nonceS,
            "alias": alias,
            "inviteAgeSec": inviteAgeSec,
            "suite": suite,
            "app": app,
        ])
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }

    public static func decodeHello(_ body: [UInt8]) -> HelloBody? {
        guard let object = JSONWire.object(body) else { return nil }
        return HelloBody(
            alias: JSONWire.string(object, "alias"),
            devType: JSONWire.string(object, "devType"),
            port: JSONWire.int(object, "port"),
            app: JSONWire.string(object, "app"),
            appPresent: object["app"] != nil,
            trusted: JSONWire.bool(object, "trusted"),
            busy: JSONWire.bool(object, "busy")
        )
    }

    public static func decodeInviteHello(_ body: [UInt8]) -> InviteHelloBody? {
        guard let object = JSONWire.object(body), let session = JSONWire.string(object, "inviteSessionId") else {
            return nil
        }
        let present = object["app"] != nil
        return InviteHelloBody(
            inviteSessionId: session,
            nonceS: JSONWire.string(object, "nonceS"),
            alias: JSONWire.string(object, "alias"),
            inviteAgeSec: JSONWire.int(object, "inviteAgeSec"),
            suite: JSONWire.string(object, "suite"),
            app: JSONWire.string(object, "app"),
            appPresent: present
        )
    }

    /// Multicast announce. Protocol 3.4 lists `app` as optional on receipt; we always send it.
    public static func multicastAnnounce(
        app: String,
        fingerprint: String,
        alias: String,
        devType: String,
        port: Int,
        nonce: String
    ) -> [UInt8] {
        JSONWire.data([
            "t": "announce",
            "proto": ["1"],
            "fp": fingerprint,
            "alias": alias,
            "devType": devType,
            "port": port,
            "nonce": nonce,
            "app": app,
        ])
    }

    public static func request(
        method: String,
        path: String,
        app: String,
        hostHeader: String,
        body: [UInt8],
        json: Bool,
        extra: [String: String] = [:]
    ) -> HTTPRequest {
        // TODO(protocol §2): the HTTP Host value and the JSON media type are not specified.
        var headers = [
            "host": hostHeaderWithoutScope(hostHeader),
            LimLinkProtocol.appHeader: app,
        ]
        if json {
            headers["content-type"] = "application/json"
        }
        for (key, value) in extra {
            headers[key] = value
        }
        return HTTPRequest(method: method, target: path, headers: headers, body: body)
    }

    /// Apple's network stack can hand back a scope-qualified address such as `192.168.0.229%en0`.
    /// RFC 3986 forbids the zone id in a URI host and strict HTTP parsers (Kestrel) reject it as a 400.
    static func hostHeaderWithoutScope(_ host: String) -> String {
        guard let percent = host.firstIndex(of: "%") else { return host }
        return String(host[host.startIndex..<percent])
    }

    public static func errorResponse(_ error: ProtocolError) -> HTTPResponse {
        var detail: [String: Any] = [:]
        for (key, value) in error.detail {
            detail[key] = value
        }
        for (key, value) in error.numericDetail {
            detail[key] = value
        }
        // TODO(protocol §13): `message` is "给人看的说明", but the language is not specified for the module. Hosts use spec 6.15.
        let body = JSONWire.data([
            "code": error.code.rawValue,
            "message": error.code.rawValue,
            "retryable": error.retryable,
            "detail": detail,
        ])
        return HTTPResponse(
            status: error.httpStatus ?? 400,
            headers: ["content-type": "application/json"],
            body: body
        )
    }

    public static func decodeError(_ body: [UInt8]) -> ProtocolError? {
        guard let object = JSONWire.object(body),
              let codeText = JSONWire.string(object, "code"),
              let code = ProtocolErrorCode(rawValue: codeText) else { return nil }
        let spec = code.specification
        var detail: [String: String] = [:]
        var numeric: [String: Int] = [:]
        if let raw = object["detail"] as? [String: Any] {
            for (key, value) in raw {
                if JSONWire.isBoolean(value) {
                    continue
                } else if let text = value as? String {
                    detail[key] = text
                } else if let number = value as? Int {
                    numeric[key] = number
                } else if let number = value as? NSNumber {
                    numeric[key] = number.intValue
                }
            }
        }
        let retryable = JSONWire.bool(object, "retryable") ?? spec.retryable
        return ProtocolError(
            code: code,
            httpStatus: spec.httpStatus,
            retryable: retryable,
            detail: detail,
            numericDetail: numeric
        )
    }
}
