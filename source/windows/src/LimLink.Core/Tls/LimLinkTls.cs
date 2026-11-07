namespace LimLink;

/// <summary>
/// TLS posture for protocol 4.2. TLS 1.3 only. These flags are not optional.
/// </summary>
public static class LimLinkTls
{
    public static void ApplyServer(SslServerAuthenticationOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.EnabledSslProtocols = SslProtocols.Tls13;
        options.AllowRenegotiation = false;
        options.AllowTlsResume = false;
        options.CertificateRevocationCheckMode = X509RevocationMode.NoCheck;
        options.ClientCertificateRequired = true;
        options.ApplicationProtocols ??= [];
        options.ApplicationProtocols.Clear();
        options.ApplicationProtocols.Add(SslApplicationProtocol.Http11);
        // SslStream has no TLS 1.3 early-data API, so 0-RTT cannot be turned on.
    }

    public static SslClientAuthenticationOptions CreateClient(
        X509Certificate2 certificate,
        RemoteCertificateValidationCallback validate)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        ArgumentNullException.ThrowIfNull(validate);
        return new SslClientAuthenticationOptions
        {
            TargetHost = LimLinkProtocol.CodeName,
            EnabledSslProtocols = SslProtocols.Tls13,
            AllowRenegotiation = false,
            AllowTlsResume = false,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
            ApplicationProtocols = [SslApplicationProtocol.Http11],
            ClientCertificates = new X509CertificateCollection { certificate },
            LocalCertificateSelectionCallback = (_, _, _, _, _) => certificate,
            RemoteCertificateValidationCallback = validate,
        };
    }
}

public enum LimLinkConnectionFailure
{
    TlsHandshake,
    ProtocolVersion,
    FingerprintMismatch,
    Unreachable,
}

public sealed class LimLinkConnectionException : Exception
{
    public LimLinkConnectionException(LimLinkConnectionFailure failure, string message, Exception? inner = null)
        : base(message, inner)
    {
        Failure = failure;
    }

    public LimLinkConnectionFailure Failure { get; }
}

public sealed class LimLinkProtocolException : Exception
{
    public LimLinkProtocolException(int statusCode, ProtocolError error)
        : base($"{error.Code}: {error.Message}")
    {
        StatusCode = statusCode;
        Error = error;
    }

    public int StatusCode { get; }
    public ProtocolError Error { get; }
}

public sealed class TlsHandshakeInfo
{
    public required SslProtocols Protocol { get; init; }
    public required string ApplicationProtocol { get; init; }
    public required string RemoteSubject { get; init; }
    public required string RemoteFingerprint { get; init; }
    public required bool ClientCertificateSent { get; init; }
}

internal enum TlsRejectReason
{
    None,
    Version,
    Fingerprint,
}
