import Foundation

/// Frozen protocol constants. A host configuration cannot rename these.
public enum LimLinkProtocol: Sendable {
    public static let serviceType = "_limlink._tcp"
    public static let urlScheme = "limlink"
    public static let pathPrefix = "/limlink/v1/"
    public static let headerPrefix = "X-LimLink-"
    /// Request header carrying the caller's host `app`. Absent or empty means `limlink`.
    public static let appHeader = "X-LimLink-App"
    public static let sasLabel = "limlink-sas-v1"
    public static let certificateCommonName = "limlink"
    public static let defaultApp = "limlink"
    public static let alpnHTTP11 = "http/1.1"
    public static let temporaryBundleIdentifier = "com.limlink.dev"
    public static let maxAppUTF8Bytes = 16
    public static let maxInstanceNameUTF8Bytes = 63
    public static let primaryPort: UInt16 = 52470
    public static let portFallbackCount = 9
    public static let browserShareFirstPort: UInt16 = 52480
    public static let browserShareLastPort: UInt16 = 52489
    /// TLS 1.3 on the wire (`tls_protocol_version_TLSv13`).
    public static let tls13WireVersion: UInt16 = 0x0304
    public static let certificateValidityYears = 10
    public static let certificateNotBeforeSkewSeconds: TimeInterval = 3600
}
