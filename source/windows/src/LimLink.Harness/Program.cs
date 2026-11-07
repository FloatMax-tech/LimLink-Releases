using LimLink;
using System.Text.Json;

var arguments = args.ToList();
string? Value(string key) { var index = arguments.IndexOf(key); return index >= 0 && index + 1 < arguments.Count ? arguments[index + 1] : null; }
var mode = arguments.FirstOrDefault(a => !a.StartsWith('-')) ?? "serve";
var probe = arguments.Contains("--ephemeral-probe");
var acceptProbe = arguments.Contains("--accept-probe");
if (acceptProbe && !probe) throw new ArgumentException("--accept-probe requires --ephemeral-probe; normal receives require consent.");
if (!OperatingSystem.IsWindows() && !probe) throw new PlatformNotSupportedException("Production identity requires Windows DPAPI. Use --ephemeral-probe only for disposable protocol verification.");
var dataDirectory = Value("--data") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LimLink");
var receiveDirectory = Value("--receive") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "LimLink");
var alias = Value("--name") ?? Environment.MachineName;
using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; shutdown.Cancel(); };
var promptGate = new SemaphoreSlim(1);
await using var node = await LimLinkNode.StartAsync(new LimLinkNodeOptions
{
    DataDirectory = dataDirectory,
    ReceiveDirectory = receiveDirectory,
    DeviceAlias = alias,
    ExplicitPort = Value("--port") is { } portText ? int.Parse(portText, System.Globalization.CultureInfo.InvariantCulture) : null,
    IdentityStore = probe ? new EphemeralIdentityStore() : null,
    ConfirmReceive = async (offer, ct) =>
    {
        if (acceptProbe) { Console.WriteLine($"PROBE_ACCEPT {JsonSerializer.Serialize(offer)}"); return true; }
        await promptGate.WaitAsync(ct);
        try
        {
            Console.WriteLine($"Receive {offer.FileName} ({offer.Size:N0} bytes) from {offer.SenderName}? Type yes to accept:");
            return string.Equals(await Console.In.ReadLineAsync(ct), "yes", StringComparison.OrdinalIgnoreCase);
        }
        finally { promptGate.Release(); }
    }
});
node.Receiver.FileReceived += path => Console.WriteLine($"RECEIVED {path}");
Console.WriteLine("READY " + JsonSerializer.Serialize(new { port = node.Port, fingerprint = node.Fingerprint, alias, receiveDirectory, ephemeralProbe = probe }));
Console.WriteLine("Single-file limit: 5 GB (5,000,000,000 bytes). Ctrl+C cancels and stops.");
try
{
    if (mode == "send")
    {
        var file = Value("--file") ?? throw new ArgumentException("send requires --file PATH");
        DiscoveryPeer peer;
        if (probe && Value("--host") is { } host)
            peer = new DiscoveryPeer("Protocol probe", host, int.Parse(Value("--peer-port") ?? "52470", System.Globalization.CultureInfo.InvariantCulture), Value("--fingerprint") ?? throw new ArgumentException("Probe requires fingerprint"), "device", "limlink");
        else
        {
            await using var discovery = new LanDiscovery(alias, node.Fingerprint, node.Port, node.AppPolicy);
            Console.WriteLine("Discovering nearby devices for 5 seconds…");
            await Task.Delay(5000, shutdown.Token);
            var peers = discovery.Peers;
            for (var i = 0; i < peers.Count; i++) Console.WriteLine($"{i + 1}. {peers[i]}");
            Console.Write("Choose receiver number: ");
            var selected = int.Parse(await Console.In.ReadLineAsync(shutdown.Token) ?? "0", System.Globalization.CultureInfo.InvariantCulture) - 1;
            if (selected < 0 || selected >= peers.Count) throw new ArgumentException("Choose a discovered device.");
            peer = peers[selected];
        }
        using var client = node.CreateClient();
        var result = await client.SendFileAsync(peer, file, Path.Combine(dataDirectory, "send-staging"), new Progress<TransferProgress>(p => Console.WriteLine($"{p.State}: {p.BytesSent}/{p.TotalBytes}")), shutdown.Token);
        Console.WriteLine("SENT " + JsonSerializer.Serialize(result));
    }
    else if (probe) await Task.Delay(Timeout.Infinite, shutdown.Token);
    else
    {
        await using var discovery = new LanDiscovery(alias, node.Fingerprint, node.Port, node.AppPolicy);
        discovery.PeersChanged += peers => Console.WriteLine("Nearby: " + string.Join(", ", peers.Select(p => p.Name)));
        discovery.Error += ex => Console.Error.WriteLine("Discovery: " + ex.Message);
        await Task.Delay(Timeout.Infinite, shutdown.Token);
    }
}
catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { Console.WriteLine("Cancelled."); }

// Explicit probe mode only; never persists a PFX or substitutes for Windows DPAPI.
internal sealed class EphemeralIdentityStore : IDeviceIdentityStore
{
    private byte[]? _pfx;
    public Task<byte[]?> LoadProtectedPfxAsync(CancellationToken cancellationToken) => Task.FromResult(_pfx);
    public Task SaveProtectedPfxAsync(byte[] bytes, CancellationToken cancellationToken) { _pfx = bytes.ToArray(); return Task.CompletedTask; }
}
