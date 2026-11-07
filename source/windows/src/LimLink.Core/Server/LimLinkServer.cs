using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Connections.Features;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Https;
using System.Collections.Concurrent;

namespace LimLink;

public sealed class LimLinkServerOptions
{
    public required X509Certificate2 Certificate { get; init; }
    public required PeerAppPolicy AppPolicy { get; init; }
    public required string Alias { get; init; }
    public string DevType { get; init; } = LimLinkProtocol.DefaultDevType;
    public int PreferredPort { get; init; } = LimLinkProtocol.DefaultPort;
    public bool AllowSystemPortFallback { get; init; } = true;

    /// <summary>
    /// Bind this port only. <c>0</c> asks the OS for a port and skips the 52470 scan.
    /// Production leaves this null.
    /// </summary>
    public int? ExplicitPort { get; init; }

    public IPAddress ListenAddress { get; init; } = IPAddress.Any;
    public ILogger? Logger { get; init; }
    /// <summary>Optional host trace sink for Kestrel-level warnings and errors.</summary>
    public Action<string>? Trace { get; init; }
    public TransferReceiver? Receiver { get; init; }
    public DeviceBindingService? Binding { get; init; }
}

public sealed class LimLinkServer : IAsyncDisposable
{
    private readonly WebApplication _app;
    private readonly ServerStats _stats;
    private readonly ServerTlsSnapshot _configuredTls;
    private ConcurrentDictionary<string, bool>? _connectionModes;
    private ConcurrentDictionary<string, bool> ConnectionModes => LazyInitializer.EnsureInitialized(ref _connectionModes)!;

    private LimLinkServer(WebApplication app, ServerStats stats, ServerTlsSnapshot configuredTls)
    {
        _app = app;
        _stats = stats;
        _configuredTls = configuredTls;
        _connectionModes = stats.ConnectionModes;
    }

    public int Port => _stats.Port;
    public ServerTlsSnapshot Tls => _stats.Tls ?? _configuredTls;
    public int InviteRequestsPastAppGate => _stats.InviteRequestsPastAppGate;
    public int HandshakesWithClientCertificate => _stats.HandshakesWithClientCertificate;

    public static async Task<LimLinkServer> StartAsync(
        LimLinkServerOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var ports = options.ExplicitPort is int explicitPort
            ? new[] { explicitPort }
            : PortSelector.Candidates(options.PreferredPort, options.AllowSystemPortFallback);

        Exception? lastUnavailable = null;
        foreach (var port in ports)
        {
            try
            {
                return await StartOneAsync(options, port, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (options.ExplicitPort is null && PortSelector.IsAddressUnavailable(ex))
            {
                lastUnavailable = ex;
                options.Logger?.LogInformation("Port {Port} is unavailable; trying the next candidate.", port);
            }
        }

        throw new LimLinkPortException(
            LimLinkProtocol.PortUnavailable,
            "Could not bind the main port range or an OS-assigned port.",
            lastUnavailable);
    }

    public async ValueTask DisposeAsync()
    {
        await _app.StopAsync().ConfigureAwait(false);
        await _app.DisposeAsync().ConfigureAwait(false);
    }

    private static async Task<LimLinkServer> StartOneAsync(
        LimLinkServerOptions options,
        int port,
        CancellationToken cancellationToken)
    {
        var logger = options.Logger ?? NullLogger.Instance;
        var stats = new ServerStats { Port = port };
        var probe = new SslServerAuthenticationOptions();
        LimLinkTls.ApplyServer(probe);
        var snapshot = ServerTlsSnapshot.Capture(probe);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = [],
            ApplicationName = "LimLink.Core",
            // Kestrel logs are forwarded through options.Trace when a host asks for them.
        });
        builder.Configuration.Sources.Clear();
        builder.Logging.ClearProviders();
        // Debug so the host trace can show connection-level failures (the trace provider filters).
        builder.Logging.SetMinimumLevel(LogLevel.Debug);
        builder.Logging.AddProvider(new DelegateLoggerProvider(options.Trace));
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.AddServerHeader = false;
            kestrel.Limits.MaxConcurrentConnections = 4;
            kestrel.Limits.MaxRequestBodySize = TransferLimits.MaximumChunkBytes;
            kestrel.Limits.MaxRequestHeadersTotalSize = 16_384;
            kestrel.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(120);
            kestrel.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
            kestrel.Listen(options.ListenAddress, port, listen =>
            {
                listen.Protocols = HttpProtocols.Http1;
                listen.UseHttps(https =>
                {
                    https.ServerCertificate = options.Certificate;
                    https.ClientCertificateMode = ClientCertificateMode.RequireCertificate;
                    https.SslProtocols = SslProtocols.Tls13;
                    https.CheckCertificateRevocation = false;
                    https.ClientCertificateValidation = (cert, _, _) =>
                    {
                        if (cert is null)
                        {
                            return false;
                        }

                        // Count here. On Schannel, ITlsConnectionFeature.ClientCertificate
                        // stays empty for a handshake that never sends HTTP, even when
                        // the client certificate was presented and accepted.
                        Interlocked.Increment(ref stats.HandshakesWithClientCertificate);
                        return true;
                    };
                    https.OnAuthenticate = (_, ssl) =>
                    {
                        LimLinkTls.ApplyServer(ssl);
                        stats.Tls = ServerTlsSnapshot.Capture(ssl);
                    };
                });
                listen.Use(async (ConnectionContext context, ConnectionDelegate next) =>
                {
                    var feature = context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpConnectionFeature>();
                    var remote = feature is null ? context.ConnectionId : $"{feature.RemoteIpAddress}:{feature.RemotePort}";
                    logger.LogInformation("inbound connection from {Remote}", remote);
                    var handshake = context.Features.Get<ITlsHandshakeFeature>();
                    if (handshake is null || handshake.Protocol != SslProtocols.Tls13)
                    {
                        logger.LogWarning(
                            "Dropping connection because the negotiated TLS version is {Protocol}.",
                            handshake?.Protocol.ToString() ?? "none");
                        context.Abort();
                        return;
                    }

                    var tlsConnection = context.Features.Get<ITlsConnectionFeature>();
                    X509Certificate2? clientCertificate = tlsConnection?.ClientCertificate;
                    if (clientCertificate is null && tlsConnection is not null)
                    {
                        try
                        {
                            clientCertificate = await tlsConnection.GetClientCertificateAsync(CancellationToken.None)
                                .ConfigureAwait(false);
                        }
                        catch (InvalidOperationException)
                        {
                        }
                    }

                    if (clientCertificate is not null)
                    {
                        Interlocked.Increment(ref stats.HandshakesWithClientCertificate);
                    }
                    var peer = clientCertificate is null ? "none" : LimLink.Fingerprint.Compute(clientCertificate);
                    logger.LogInformation("TLS {Protocol} established, client certificate {Present} fp={Peer}", handshake.Protocol, clientCertificate is not null, peer);
                    context.ConnectionClosed.Register(() => options.Trace?.Invoke($"connection {context.ConnectionId} closed"));

                    try { await next(context).ConfigureAwait(false); }
                    finally { stats.ConnectionModes.TryRemove(context.ConnectionId, out _); options.Binding?.Disconnect(context.ConnectionId); if (options.Receiver is not null) await options.Receiver.DisconnectAsync(context.ConnectionId).ConfigureAwait(false); }
                });
            });
        });

        var app = builder.Build();
        var server = new LimLinkServer(app, stats, snapshot);
        app.Run(context => server.HandleAsync(context, options));

        try
        {
            await app.StartAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            await app.DisposeAsync().ConfigureAwait(false);
            throw;
        }

        var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>();
        var actual = addresses?.Addresses
            .Select(static address => new Uri(address).Port)
            .FirstOrDefault(static bound => bound > 0) ?? port;
        stats.Port = actual;
        if (options.Receiver is not null) options.Receiver.Port = actual;
        return server;
    }

    private async Task HandleAsync(HttpContext context, LimLinkServerOptions options)
    {
        var path = context.Request.Path.Value ?? string.Empty;
        if (!path.StartsWith("/limlink/v1", StringComparison.OrdinalIgnoreCase))
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status404NotFound,
                LimLinkProtocol.ErrorBadRequest,
                "Unknown path.",
                retryable: false).ConfigureAwait(false);
            return;
        }

        var isHello = path.Equals(LimLinkProtocol.HelloPath, StringComparison.OrdinalIgnoreCase);
        var peerApp = context.Request.Headers[LimLinkProtocol.HeaderApp].ToString();
        if (!isHello && !options.AppPolicy.Allows(peerApp))
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status403Forbidden,
                LimLinkProtocol.ErrorAppMismatch,
                "The peer is a different host app.",
                retryable: false,
                new { app = options.AppPolicy.HostAppId }).ConfigureAwait(false);
            return;
        }

        var isPair = IsUnder(path, "/limlink/v1/pair/");
        var isFile = isHello || path == "/limlink/v1/sessions" || path.StartsWith("/limlink/v1/sessions/", StringComparison.Ordinal);
        if ((isPair || isFile) && ConnectionModes.GetOrAdd(context.Connection.Id, isPair) != isPair)
        {
            await WriteReplyAsync(context, TransferReply.Error(409, "E_INVALID_STATE")).ConfigureAwait(false);
            return;
        }

        if (options.Receiver is not null && isFile)
        {
            await HandleTransferAsync(context, options.Receiver).ConfigureAwait(false);
            return;
        }

        if (isHello)
        {
            if (!HttpMethods.IsPost(context.Request.Method))
            {
                context.Response.Headers.Allow = "POST";
                await WriteErrorAsync(
                    context,
                    StatusCodes.Status405MethodNotAllowed,
                    LimLinkProtocol.ErrorBadRequest,
                    "hello is POST.",
                    retryable: false).ConfigureAwait(false);
                return;
            }

            await HandleHelloAsync(context, options).ConfigureAwait(false);
            return;
        }

        if (IsUnder(path, "/limlink/v1/invite/"))
        {
            Interlocked.Increment(ref _stats.InviteRequestsPastAppGate);
            await WriteErrorAsync(
                context,
                StatusCodes.Status501NotImplemented,
                LimLinkProtocol.ErrorNotImplemented,
                "Invite is not implemented in this build.",
                retryable: false).ConfigureAwait(false);
            return;
        }

        if (IsUnder(path, "/limlink/v1/pair/"))
        {
            if (options.AppPolicy.HostAppId != "limlink" || peerApp != "limlink") { await WriteReplyAsync(context, TransferReply.Error(403, "E_APP_MISMATCH")).ConfigureAwait(false); return; }
            if (options.Binding is null) { await WriteReplyAsync(context, TransferReply.Error(503, "E_PAIR_STORAGE_FAILED")).ConfigureAwait(false); return; }
            await HandlePairAsync(context, options.Binding).ConfigureAwait(false);
            return;
        }

        if (IsUnder(path, "/limlink/v1/link/"))
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status501NotImplemented,
                LimLinkProtocol.ErrorNotImplemented,
                "Remote link is not implemented.",
                retryable: false).ConfigureAwait(false);
            return;
        }

        await WriteErrorAsync(
            context,
            StatusCodes.Status401Unauthorized,
            LimLinkProtocol.ErrorNotPaired,
            "This device is not paired.",
            retryable: false).ConfigureAwait(false);
    }

    private async Task HandleHelloAsync(HttpContext context, LimLinkServerOptions options)
    {
        HelloMessage? request;
        try
        {
            request = await context.Request.ReadFromJsonAsync<HelloMessage>(
                ProtocolJson.Options,
                context.RequestAborted).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is Microsoft.AspNetCore.Http.BadHttpRequestException or IOException or System.Text.Json.JsonException)
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status400BadRequest,
                LimLinkProtocol.ErrorBadRequest,
                "Request body could not be read.",
                retryable: false).ConfigureAwait(false);
            return;
        }

        if (request?.Proto is null || request.Proto.Length == 0)
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status400BadRequest,
                LimLinkProtocol.ErrorBadRequest,
                "proto is required.",
                retryable: false).ConfigureAwait(false);
            return;
        }

        var supported = request.Proto.Any(static version =>
            string.Equals(version?.Trim(), LimLinkProtocol.SupportedProto, StringComparison.Ordinal));
        if (!supported)
        {
            await WriteErrorAsync(
                context,
                StatusCodes.Status400BadRequest,
                LimLinkProtocol.ErrorUnsupportedVersion,
                "No common protocol version.",
                retryable: false,
                new { supported = new[] { LimLinkProtocol.SupportedProto } }).ConfigureAwait(false);
            return;
        }

        var response = new HelloMessage
        {
            Proto = [LimLinkProtocol.SupportedProto],
            Alias = options.Alias,
            DevType = options.DevType,
            Port = _stats.Port,
            App = options.AppPolicy.HostAppId,
            Limits = HelloLimits.Default,
            Trusted = false,
            Busy = false,
        };
        context.Response.StatusCode = StatusCodes.Status200OK;
        await WriteReplyAsync(context, TransferReply.From(200, response)).ConfigureAwait(false);
    }

    private static async Task HandlePairAsync(HttpContext context, DeviceBindingService binding)
    {
        if (context.Request.ContentLength is null or < 0 or > 16_384 || context.Request.Headers.ContainsKey("Transfer-Encoding"))
        { context.Response.Headers.Connection = "close"; await WriteReplyAsync(context, TransferReply.Error(400, "E_BAD_REQUEST")).ConfigureAwait(false); return; }
        var cert = await context.Connection.GetClientCertificateAsync(context.RequestAborted).ConfigureAwait(false);
        if (cert is null) { await WriteReplyAsync(context, TransferReply.Error(403, "E_PAIR_TOKEN_INVALID")).ConfigureAwait(false); return; }
        try
        {
            var bytes = new byte[(int)context.Request.ContentLength.Value];
            await context.Request.Body.ReadExactlyAsync(bytes, context.RequestAborted).ConfigureAwait(false);
            var headers = context.Request.Headers.ToDictionary(h => h.Key, h => h.Value.ToString(), StringComparer.OrdinalIgnoreCase);
            var result = await binding.HandleAsync(new(context.Connection.Id, Fingerprint.Compute(cert)), context.Request.Method, context.Request.Path.Value!, headers, bytes).ConfigureAwait(false);
            await WriteReplyAsync(context, result).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException) { binding.Disconnect(context.Connection.Id); context.Abort(); }
    }

    private static async Task HandleTransferAsync(HttpContext context, TransferReceiver receiver)
    {
        var maximum = HttpMethods.IsPut(context.Request.Method) ? TransferLimits.MaximumChunkBytes : TransferLimits.MaximumJsonBytes;
        if (context.Request.ContentLength > maximum)
        {
            context.Response.Headers.Connection = "close";
            await WriteReplyAsync(context, TransferReply.Error(413, "E_FILE_TOO_LARGE")).ConfigureAwait(false);
            return;
        }
        if (context.Request.Headers.ContainsKey("Transfer-Encoding") || context.Request.ContentLength is null || context.Request.ContentLength < 0)
        {
            context.Response.Headers.Connection = "close";
            await WriteReplyAsync(context, TransferReply.Error(400, "E_BAD_REQUEST", "A bounded Content-Length is required.")).ConfigureAwait(false);
            return;
        }
        var certificate = await context.Connection.GetClientCertificateAsync(context.RequestAborted).ConfigureAwait(false);
        if (certificate is null) { await WriteReplyAsync(context, TransferReply.Error(401, "E_NOT_PAIRED")).ConfigureAwait(false); return; }
        try
        {
            var bytes = new byte[(int)context.Request.ContentLength.Value];
            await context.Request.Body.ReadExactlyAsync(bytes, context.RequestAborted).ConfigureAwait(false);
            var headers = context.Request.Headers.ToDictionary(h => h.Key, h => h.Value.ToString(), StringComparer.OrdinalIgnoreCase);
            var peer = new PeerConnection(context.Connection.Id, Fingerprint.Compute(certificate));
            var reply = await receiver.HandleAsync(peer, context.Request.Method, context.Request.Path + context.Request.QueryString, headers, bytes, context.RequestAborted).ConfigureAwait(false);
            if (reply.Status == 202 && HttpMethods.IsGet(context.Request.Method)) await Task.Delay(200, context.RequestAborted).ConfigureAwait(false);
            await WriteReplyAsync(context, reply).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or Microsoft.AspNetCore.Http.BadHttpRequestException or OperationCanceledException)
        {
            await receiver.DisconnectAsync(context.Connection.Id).ConfigureAwait(false);
            context.Abort();
        }
    }

    private static async Task WriteReplyAsync(HttpContext context, TransferReply reply)
    {
        context.Response.StatusCode = reply.Status;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength = reply.Body.Length;
        await context.Response.Body.WriteAsync(reply.Body, context.RequestAborted).ConfigureAwait(false);
    }

    private static bool IsUnder(string path, string prefix) =>
        path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);

    private static async Task WriteErrorAsync(
        HttpContext context,
        int status,
        string code,
        string message,
        bool retryable,
        object? detail = null)
    {
        context.Response.StatusCode = status;
        await WriteReplyAsync(context, TransferReply.From(status, ProtocolJson.Error(code, message, retryable, detail))).ConfigureAwait(false);
    }

    private sealed class ServerStats
    {
        public readonly ConcurrentDictionary<string, bool> ConnectionModes = new(StringComparer.Ordinal);
        public int Port;
        public int InviteRequestsPastAppGate;
        public int HandshakesWithClientCertificate;
        public ServerTlsSnapshot? Tls;
    }
}

public readonly record struct ServerTlsSnapshot(
    SslProtocols Protocols,
    bool AllowRenegotiation,
    bool AllowTlsResume,
    bool ClientCertificateRequired,
    string ApplicationProtocols)
{
    public static ServerTlsSnapshot Capture(SslServerAuthenticationOptions options)
    {
        var alpns = options.ApplicationProtocols is null
            ? string.Empty
            : string.Join(',', options.ApplicationProtocols.Select(static protocol => protocol.ToString()));
        return new ServerTlsSnapshot(
            options.EnabledSslProtocols,
            options.AllowRenegotiation,
            options.AllowTlsResume,
            options.ClientCertificateRequired,
            alpns);
    }
}
