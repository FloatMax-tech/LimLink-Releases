namespace LimLink;

/// <summary>
/// Frozen protocol identifiers (protocol 1.1). Do not fork these per host app.
/// </summary>
public static class LimLinkProtocol
{
    public const string CodeName = "limlink";
    public const string PathPrefix = "/limlink/v1/";
    public const string HelloPath = "/limlink/v1/hello";
    public const string ServiceType = "_limlink._tcp";
    public const string QrScheme = "limlink://";
    public const string SasLabel = "limlink-sas-v1";

    public const string HeaderApp = "X-LimLink-App";
    public const string HeaderToken = "X-LimLink-Token";
    public const string HeaderOffset = "X-LimLink-Offset";

    /// <summary>Protocol <c>app</c> value for the LimLink host. Not the reverse-DNS product id.</summary>
    public const string DefaultHostAppId = "limlink";

    public const string DefaultDevType = "windows";
    public const string SupportedProto = "1.0";

    public const int DefaultPort = 52470;
    public const int PortAttemptCount = 10;
    public const int AppIdMaxBytes = 16;

    public const string CertificateSubject = "CN=limlink";

    /// <summary>
    /// Reverse-DNS placeholder until the product domain is chosen (plan 08).
    /// Used for the certificate friendly name and DPAPI entropy. The protocol
    /// <c>app</c> field stays <see cref="DefaultHostAppId"/>.
    /// </summary>
    public const string TemporaryProductId = "com.limlink.dev";

    public const string PortUnavailable = "L_PORT_UNAVAILABLE";

    public const string ErrorBadRequest = "E_BAD_REQUEST";
    public const string ErrorUnsupportedVersion = "E_UNSUPPORTED_VERSION";
    public const string ErrorNotPaired = "E_NOT_PAIRED";
    public const string ErrorNotImplemented = "E_NOT_IMPLEMENTED";
    public const string ErrorAppMismatch = "E_APP_MISMATCH";
}
