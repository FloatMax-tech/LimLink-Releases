using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace LimLink;

public sealed class LimLinkClientOptions
{
    public required X509Certificate2 Certificate { get; init; }
    public string HostAppId { get; init; } = LimLinkProtocol.DefaultHostAppId;
    public string Alias { get; init; } = "LimLink";
    public string DevType { get; init; } = LimLinkProtocol.DefaultDevType;
    public int? LocalPort { get; init; }
    public IReadOnlyCollection<string>? AllowedPeerApps { get; init; }

    /// <summary>Protocol 1.2: hello may omit this header; every other request must send it.</summary>
    public bool SendAppHeader { get; init; } = true;
    public ILogger? Logger { get; init; }
    public DeviceBindingService? Binding { get; init; }
}

public sealed partial class LimLinkClient : IDisposable
{
    private readonly X509Certificate2 _certificate;
    private readonly PeerAppPolicy _policy;
    private readonly LimLinkClientOptions _options;
    private readonly ILogger _logger;

    public LimLinkClient(LimLinkClientOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _certificate = options.Certificate;
        _policy = new PeerAppPolicy(options.HostAppId, options.AllowedPeerApps);
        _logger = options.Logger ?? NullLogger.Instance;
        if (!_certificate.HasPrivateKey)
        {
            throw new ArgumentException("The client certificate must include its private key.", nameof(options));
        }
    }

    public string HostAppId => _policy.HostAppId;

    /// <summary>
    /// How long AuthenticateAsClientAsync may wait. A TLS 1.2-only peer does not
    /// always produce an alert when this client allows TLS 1.3 only.
    /// </summary>
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(10);

    public async Task<TlsHandshakeInfo> HandshakeAsync(
        string host,
        int port,
        string expectedFingerprint,
        CancellationToken cancellationToken = default)
    {
        ValidateEndpoint(host, port, expectedFingerprint);
        using var tcp = new TcpClient();
        try
        {
            await tcp.ConnectAsync(host, port, cancellationToken).ConfigureAwait(false);
        }
        catch (SocketException ex)
        {
            throw new LimLinkConnectionException(LimLinkConnectionFailure.Unreachable, "Could not connect.", ex);
        }

        var decision = new TlsDecision();
        var transport = new CountingStream(tcp.GetStream());
        // The validation callback lives only on SslClientAuthenticationOptions.
        // Setting it on the SslStream constructor as well throws on .NET 10.
        using var ssl = new SslStream(transport, leaveInnerStreamOpen: false);
        var sslOptions = LimLinkTls.CreateClient(
            _certificate,
            (sender, certificate, _, _) => ValidatePeer(certificate, expectedFingerprint, decision, checkVersion: true, sender));
        using var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // Schannel, with TLS 1.3 only, waits in ReceiveHandshakeFrameAsync when the
        // peer is TLS 1.2-only instead of raising an alert. Bound the wait and fail.
        // SslProtocols stays Tls13.
        handshake.CancelAfter(HandshakeTimeout);
        try
        {
            await ssl.AuthenticateAsClientAsync(sslOptions, handshake.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException ex)
        {
            throw new LimLinkConnectionException(
                LimLinkConnectionFailure.TlsHandshake,
                $"The TLS handshake did not finish. bytesSent={transport.WrittenBytes} bytesReceived={transport.ReadBytes}.",
                ex);
        }
        catch (Exception ex) when (ex is AuthenticationException or IOException or InvalidOperationException)
        {
            throw MapTlsFailure(decision.Reason, ex);
        }

        if (ssl.SslProtocol != SslProtocols.Tls13)
        {
            throw new LimLinkConnectionException(
                LimLinkConnectionFailure.ProtocolVersion,
                "The peer did not negotiate TLS 1.3.");
        }

        var remote = ssl.RemoteCertificate
            ?? throw new LimLinkConnectionException(
                LimLinkConnectionFailure.TlsHandshake,
                "The peer did not present a certificate.");
        var remoteDer = remote.Export(X509ContentType.Cert);
        using var remoteCert = X509CertificateLoader.LoadCertificate(remoteDer);
        return new TlsHandshakeInfo
        {
            Protocol = ssl.SslProtocol,
            ApplicationProtocol = ssl.NegotiatedApplicationProtocol.ToString(),
            RemoteSubject = remoteCert.Subject,
            RemoteFingerprint = Fingerprint.Compute(remoteCert),
            ClientCertificateSent = ssl.LocalCertificate is not null,
        };
    }

    public Task<HelloResult> HelloAsync(
        string host,
        int port,
        string expectedFingerprint,
        CancellationToken cancellationToken = default)
        => HelloAsync(host, port, expectedFingerprint, request: null, cancellationToken);

    public async Task<HelloResult> HelloAsync(
        string host,
        int port,
        string expectedFingerprint,
        HelloMessage? request,
        CancellationToken cancellationToken = default)
    {
        var body = request ?? new HelloMessage
        {
            Proto = [LimLinkProtocol.SupportedProto],
            Alias = _options.Alias,
            DevType = _options.DevType,
            Port = _options.LocalPort,
            App = _policy.HostAppId,
            Limits = HelloLimits.Default,
            Caps = ["binding-v1"], BindingId = _options.Binding?.BindingIdFor(expectedFingerprint),
        };
        var json = JsonSerializer.Serialize(body, ProtocolJson.Options);
        var response = await SendAsync(
            host,
            port,
            expectedFingerprint,
            HttpMethod.Post,
            LimLinkProtocol.HelloPath,
            json,
            cancellationToken).ConfigureAwait(false);
        if (response.Status != 200)
        {
            throw ReadProtocolError(response);
        }

        var peer = ReadJson<HelloMessage>(response)
            ?? throw new LimLinkProtocolException(
                response.Status,
                ProtocolJson.Error(LimLinkProtocol.ErrorBadRequest, "Empty hello response.", false));
        var compatible = _policy.Allows(peer.App);
        if (!compatible)
        {
            _logger.LogInformation(
                "Hello succeeded and the peer app is not in the allowed set. Stopping.");
        }

        return new HelloResult { Peer = peer, AppCompatible = compatible };
    }

    public async Task<ProtocolError> PostExpectingErrorAsync(
        string host,
        int port,
        string expectedFingerprint,
        string path,
        CancellationToken cancellationToken = default)
    {
        var response = await SendAsync(
            host,
            port,
            expectedFingerprint,
            HttpMethod.Post,
            path,
            "{}",
            cancellationToken).ConfigureAwait(false);
        if (response.Status is >= 200 and < 300)
        {
            throw new InvalidOperationException($"Expected an error from {path} but the status was {response.Status}.");
        }

        return ReadProtocolError(response).Error;
    }

    public void Dispose()
    {
    }

    private async Task<RawHttpResponse> SendAsync(
        string host,
        int port,
        string expectedFingerprint,
        HttpMethod method,
        string path,
        string? json,
        CancellationToken cancellationToken)
    {
        ValidateEndpoint(host, port, expectedFingerprint);
        var decision = new TlsDecision();
        using var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.None,
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            SslOptions = LimLinkTls.CreateClient(
                _certificate,
                (sender, certificate, _, _) => ValidatePeer(certificate, expectedFingerprint, decision, checkVersion: true, sender)),
        };
        using var http = new HttpClient(handler)
        {
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact,
            Timeout = TimeSpan.FromSeconds(20),
        };
        var uri = new Uri($"https://{host}:{port}{path}");
        using var request = new HttpRequestMessage(method, uri)
        {
            Version = HttpVersion.Version11,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
        };
        if (_options.SendAppHeader)
        {
            request.Headers.TryAddWithoutValidation(LimLinkProtocol.HeaderApp, _policy.HostAppId);
        }
        if (json is not null)
        {
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        }

        try
        {
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var body = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            return new RawHttpResponse((int)response.StatusCode, body);
        }
        catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException or IOException)
        {
            throw MapTlsFailure(decision.Reason, ex);
        }
        catch (HttpRequestException ex)
        {
            throw new LimLinkConnectionException(LimLinkConnectionFailure.Unreachable, "Could not connect.", ex);
        }
        catch (AuthenticationException ex)
        {
            throw MapTlsFailure(decision.Reason, ex);
        }
    }

    private static bool ValidatePeer(
        X509Certificate? certificate,
        string expectedFingerprint,
        TlsDecision decision,
        bool checkVersion,
        object? sender = null)
    {
        if (checkVersion
            && sender is SslStream stream
            && stream.SslProtocol is not SslProtocols.None and not SslProtocols.Tls13)
        {
            decision.Reason = TlsRejectReason.Version;
            return false;
        }

        if (certificate is null)
        {
            decision.Reason = TlsRejectReason.Fingerprint;
            return false;
        }

        byte[] der;
        try
        {
            der = certificate.Export(X509ContentType.Cert);
        }
        catch (CryptographicException)
        {
            decision.Reason = TlsRejectReason.Fingerprint;
            return false;
        }

        using var parsed = X509CertificateLoader.LoadCertificate(der);
        var actual = Fingerprint.Compute(parsed);
        if (!Fingerprint.FixedEquals(actual, expectedFingerprint))
        {
            decision.Reason = TlsRejectReason.Fingerprint;
            return false;
        }

        return true;
    }

    private static LimLinkConnectionException MapTlsFailure(TlsRejectReason reason, Exception exception)
    {
        return reason switch
        {
            TlsRejectReason.Fingerprint => new LimLinkConnectionException(
                LimLinkConnectionFailure.FingerprintMismatch,
                "The peer certificate fingerprint does not match the expected pin.",
                exception),
            TlsRejectReason.Version => new LimLinkConnectionException(
                LimLinkConnectionFailure.ProtocolVersion,
                "The peer did not negotiate TLS 1.3.",
                exception),
            _ => new LimLinkConnectionException(
                LimLinkConnectionFailure.TlsHandshake,
                "The TLS handshake failed.",
                exception),
        };
    }

    private static void ValidateEndpoint(string host, int port, string expectedFingerprint)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(host);
        if (port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port));
        }

        if (!Fingerprint.TryDecode(expectedFingerprint, out _))
        {
            throw new ArgumentException("Expected fingerprint is not a 32-byte base64url SHA-256.", nameof(expectedFingerprint));
        }
    }

    private static LimLinkProtocolException ReadProtocolError(RawHttpResponse response)
    {
        var error = ReadJson<ProtocolError>(response);
        if (error is null || string.IsNullOrEmpty(error.Code))
        {
            error = ProtocolJson.Error(
                LimLinkProtocol.ErrorBadRequest,
                "The peer response was not a LimLink error.",
                false);
        }

        return new LimLinkProtocolException(response.Status, error);
    }

    private static T? ReadJson<T>(RawHttpResponse response)
    {
        if (response.Body.Length == 0)
        {
            return default;
        }

        try
        {
            return JsonSerializer.Deserialize<T>(response.Body, ProtocolJson.Options);
        }
        catch (JsonException)
        {
            return default;
        }
    }

    private readonly record struct RawHttpResponse(int Status, byte[] Body);

    private sealed class TlsDecision
    {
        public TlsRejectReason Reason;
    }

    private sealed class CountingStream : Stream
    {
        private readonly Stream _inner;
        private long _read;
        private long _written;

        public CountingStream(Stream inner) => _inner = inner;

        public long ReadBytes => Interlocked.Read(ref _read);
        public long WrittenBytes => Interlocked.Read(ref _written);

        public override bool CanRead => _inner.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => _inner.CanWrite;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() => _inner.Flush();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = _inner.Read(buffer, offset, count);
            Interlocked.Add(ref _read, read);
            return read;
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            _inner.Write(buffer, offset, count);
            Interlocked.Add(ref _written, count);
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = await _inner.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            Interlocked.Add(ref _read, read);
            return read;
        }

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await _inner.WriteAsync(buffer, cancellationToken).ConfigureAwait(false);
            Interlocked.Add(ref _written, buffer.Length);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
            }

            base.Dispose(disposing);
        }
    }
}
