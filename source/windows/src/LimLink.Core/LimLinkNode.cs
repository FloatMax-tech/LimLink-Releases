namespace LimLink;

public sealed class LimLinkNodeOptions
{
    public required string DataDirectory { get; init; }
    public string HostAppId { get; init; } = LimLinkProtocol.DefaultHostAppId;
    public string DeviceAlias { get; init; } = "LimLink";
    public string DevType { get; init; } = LimLinkProtocol.DefaultDevType;
    public int PreferredPort { get; init; } = LimLinkProtocol.DefaultPort;
    public bool AllowSystemPortFallback { get; init; } = true;
    public int? ExplicitPort { get; init; }
    public IDeviceIdentityStore? IdentityStore { get; init; }
    public IReadOnlyCollection<string>? AllowedPeerApps { get; init; }
    public ILoggerFactory? LoggerFactory { get; init; }
    public IPAddress? ListenAddress { get; init; }
    public string? ReceiveDirectory { get; init; }
    public Func<IncomingOffer, CancellationToken, Task<bool>>? ConfirmReceive { get; init; }
    /// <summary>Optional host trace sink for Kestrel-level warnings and errors.</summary>
    public Action<string>? Trace { get; init; }
    public IBindingStore? BindingStore { get; init; }
    public Func<BindingOffer, CancellationToken, Task<bool>>? ConfirmBinding { get; init; }
}

/// <summary>
/// In-process device identity, TLS 1.3 listener and single-file receiver.
/// Hosts own discovery, explicit receive consent and progress UI.
/// </summary>
public sealed class LimLinkNode : IAsyncDisposable
{
    private readonly LimLinkServer _server;
    private TransferReceiver? _receiver;
    private readonly X509Certificate2 _certificate;
    private readonly string _alias;
    private readonly IReadOnlyCollection<string>? _allowedPeerApps;

    private LimLinkNode(
        LimLinkServer server,
        X509Certificate2 certificate,
        string fingerprint,
        string alias,
        IReadOnlyCollection<string>? allowedPeerApps,
        PeerAppPolicy policy)
    {
        _server = server;
        _certificate = certificate;
        _alias = alias;
        _allowedPeerApps = allowedPeerApps;
        Fingerprint = fingerprint;
        AppPolicy = policy;
    }

    public int Port => _server.Port;
    public string Fingerprint { get; }
    public string DisplayFingerprint => LimLink.Fingerprint.ToDisplay(Fingerprint);
    public X509Certificate2 Certificate => _certificate;
    public PeerAppPolicy AppPolicy { get; }
    public string HostAppId => AppPolicy.HostAppId;
    public LimLinkServer Server => _server;
    public TransferReceiver Receiver => _receiver!;
    public DeviceBindingService Binding { get; private set; } = null!;

    public static async Task<LimLinkNode> StartAsync(
        LimLinkNodeOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.DataDirectory);
        Directory.CreateDirectory(options.DataDirectory);

        var store = options.IdentityStore ?? CreateDefaultStore(options.DataDirectory);
        var certificate = await DeviceIdentity.LoadOrCreateAsync(store, cancellationToken).ConfigureAwait(false);
        var policy = new PeerAppPolicy(options.HostAppId, options.AllowedPeerApps);
        var binding = new DeviceBindingService(global::LimLink.Fingerprint.Compute(certificate), options.DeviceAlias, options.DevType,
            options.BindingStore ?? (OperatingSystem.IsWindows() ? new PrivateBindingStore(Path.Combine(options.DataDirectory, "device-bindings.bin"), new DpapiSecretProtector()) : new UnavailableBindingStore()), options.ConfirmBinding);
        var logger = options.LoggerFactory?.CreateLogger<LimLinkServer>() ?? NullLogger<LimLinkServer>.Instance;
        var receiver = new TransferReceiver(options.ReceiveDirectory ?? Path.Combine(options.DataDirectory, "Received"), options.DeviceAlias, policy,
            options.ConfirmReceive ?? ((_, _) => Task.FromResult(false)), logger: options.LoggerFactory?.CreateLogger<TransferReceiver>()) { DevType = options.DevType, Binding = binding };
        LimLinkServer server;
        try { server = await LimLinkServer.StartAsync(
            new LimLinkServerOptions
            {
                Certificate = certificate,
                AppPolicy = policy,
                Alias = options.DeviceAlias,
                DevType = options.DevType,
                PreferredPort = options.PreferredPort,
                AllowSystemPortFallback = options.AllowSystemPortFallback,
                ExplicitPort = options.ExplicitPort,
                ListenAddress = options.ListenAddress ?? IPAddress.Any,
                Logger = logger,
                Receiver = receiver,
                Binding = binding,
                Trace = options.Trace,
            },
            cancellationToken).ConfigureAwait(false); }
        catch { binding.Dispose(); receiver.Dispose(); certificate.Dispose(); throw; }

        return new LimLinkNode(
            server,
            certificate,
            global::LimLink.Fingerprint.Compute(certificate),
            options.DeviceAlias,
            options.AllowedPeerApps,
            policy) { _receiver = receiver, Binding = binding };
    }

    public LimLinkClient CreateClient()
    {
        return new LimLinkClient(new LimLinkClientOptions
        {
            Certificate = _certificate,
            HostAppId = HostAppId,
            Alias = _alias,
            LocalPort = Port,
            AllowedPeerApps = _allowedPeerApps,
            Binding = Binding,
        });
    }

    public async ValueTask DisposeAsync()
    {
        Binding.Dispose();
        await _server.DisposeAsync().ConfigureAwait(false);
        _receiver?.Dispose();
        _certificate.Dispose();
    }

    private static IDeviceIdentityStore CreateDefaultStore(string dataDirectory)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The default identity store uses DPAPI. Pass IdentityStore when not running on Windows.");
        }

        return new FileDeviceIdentityStore(
            Path.Combine(dataDirectory, "device-identity.bin"),
            new DpapiSecretProtector());
    }
}
