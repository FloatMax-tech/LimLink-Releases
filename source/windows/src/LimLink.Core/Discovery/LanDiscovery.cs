using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;

namespace LimLink;

public sealed record DiscoveryPeer(string Name, string Host, int Port, string Fingerprint, string DeviceType, string App)
{
    public IReadOnlyList<string> AddressCandidates { get; init; } = [Host];
    public override string ToString() => $"{Name} ({DeviceType})";
    public static DiscoveryPeer? FromTxt(string name, string host, int port, IReadOnlyDictionary<string, string> txt, string selfFingerprint, PeerAppPolicy policy)
    {
        // The Apple clients advertise `pv=1`; Windows and Android advertise `pv=1.0`. Both mean protocol 1.x.
        if (!txt.TryGetValue("pv", out var versions) || !versions.Split(',').Select(v => v.Trim()).Any(v => v is "1" or "1.0") || !txt.TryGetValue("fp", out var fp) || !global::LimLink.Fingerprint.TryDecode(fp, out _) || global::LimLink.Fingerprint.FixedEquals(fp, selfFingerprint) || port is < 1 or > 65535 || !IPAddress.TryParse(host, out var ip) || IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any)) return null;
        txt.TryGetValue("app", out var app);
        if (!policy.Allows(app)) return null;
        txt.TryGetValue("dt", out var type);
        return new(name, host, port, fp, type ?? "device", PeerAppPolicy.NormalizePeer(app));
    }
}

/// <summary>IPv4 multicast DNS-SD. No Bonjour installation, relay, or remote link is required.</summary>
public sealed class LanDiscovery : IAsyncDisposable
{
    private const string Service = "_limlink._tcp.local";
    private readonly IDiscoveryTransport _transport;
    private readonly DiscoveryInterfaces _interfaces;
    private readonly CancellationTokenSource _stop = new();
    private readonly string _instance, _host, _fingerprint;
    private readonly int _port;
    private readonly PeerAppPolicy _policy;
    private readonly DiscoveryRecordCache _records = new();
    private readonly Task _receive, _announce;
    private IReadOnlyList<DiscoveryPeer> _peers = [];
    private int _networkRefreshScheduled;
    public IReadOnlyList<DiscoveryPeer> Peers => Volatile.Read(ref _peers);
    public event Action<IReadOnlyList<DiscoveryPeer>>? PeersChanged;
    public event Action<Exception>? Error;

    public LanDiscovery(string alias, string fingerprint, int port, PeerAppPolicy policy)
    {
        if (!Fingerprint.TryDecode(fingerprint, out _)) throw new ArgumentException("A valid identity is required.");
        _fingerprint = fingerprint; _port = port; _policy = policy;
        var label = alias.Replace('.', '-');
        while (Encoding.UTF8.GetByteCount(label) > 50) label = label[..^1];
        if (string.IsNullOrWhiteSpace(label)) label = "Windows";
        _instance = label + "-" + fingerprint[..6] + "." + Service;
        _host = "limlink-" + fingerprint[..12].ToLowerInvariant() + ".local";
        _transport = new UdpDiscoveryTransport();
        _interfaces = new DiscoveryInterfaces(_transport);
        _interfaces.Error += ex => Error?.Invoke(ex);
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        _receive = ReceiveAsync();
        _announce = AnnounceAsync();
    }
    private async Task AnnounceAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                try
                {
                    await AdvertiseAsync(120).ConfigureAwait(false);
                    await MulticastAsync(DnsPacket.Query(Service)).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is SocketException or System.Net.NetworkInformation.NetworkInformationException) { Error?.Invoke(ex); }
                await Task.Delay(TimeSpan.FromSeconds(5), _stop.Token).ConfigureAwait(false);
                Refresh();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException) { if (!_stop.IsCancellationRequested) Error?.Invoke(ex); }
    }
    private Task MulticastAsync(byte[] packet) => _interfaces.SendAsync(_ => packet, _stop.Token);
    private Task AdvertiseAsync(uint ttl) => _interfaces.SendAsync(address => Advertisement(ttl, address), _stop.Token);
    private byte[] Advertisement(uint ttl, IPAddress address) => DnsPacket.Advertisement(Service, _instance, _host, _port,
        new Dictionary<string, string> { ["pv"] = "1.0", ["fp"] = _fingerprint, ["dt"] = "windows", ["caps"] = "binding-v1", ["app"] = _policy.HostAppId }, [address], ttl);
    private void OnNetworkAddressChanged(object? sender, EventArgs args)
    {
        if (_stop.IsCancellationRequested || Interlocked.Exchange(ref _networkRefreshScheduled, 1) != 0) return;
        _ = RefreshNetworkAsync();
    }
    private async Task RefreshNetworkAsync()
    {
        try { await AdvertiseAsync(120).ConfigureAwait(false); await MulticastAsync(DnsPacket.Query(Service)).ConfigureAwait(false); Refresh(); }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex) when (ex is SocketException or System.Net.NetworkInformation.NetworkInformationException) { if (!_stop.IsCancellationRequested) Error?.Invoke(ex); }
        finally { Interlocked.Exchange(ref _networkRefreshScheduled, 0); }
    }
    private async Task ReceiveAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                byte[] packet;
                try { packet = await _transport.ReceiveAsync(_stop.Token).ConfigureAwait(false); }
                catch (SocketException ex)
                {
                    if (_stop.IsCancellationRequested) return;
                    Error?.Invoke(ex); await Task.Delay(TimeSpan.FromSeconds(1), _stop.Token).ConfigureAwait(false); continue;
                }
                try
                {
                    var parsed = DnsPacket.Read(packet);
                    if (!parsed.Response && parsed.Questions.Any(q => string.Equals(q, Service, StringComparison.OrdinalIgnoreCase) || string.Equals(q, _instance, StringComparison.OrdinalIgnoreCase) || string.Equals(q, _host, StringComparison.OrdinalIgnoreCase)))
                        await AdvertiseAsync(120).ConfigureAwait(false);
                    if (parsed.Response)
                    {
                        foreach (var ptr in parsed.Records.Where(r => r.Type == 12 && r.Target is not null && string.Equals(r.Name, Service, StringComparison.OrdinalIgnoreCase)))
                        {
                            if (string.Equals(ptr.Target, _instance, StringComparison.OrdinalIgnoreCase) || !ptr.Target!.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase)) continue;
                            bool missing;
                            lock (_records) missing = _records.Find(ptr.Target!, 33) is null || _records.Find(ptr.Target!, 16) is null;
                            if (missing && (!parsed.Records.Any(r => r.Type == 33 && r.Name == ptr.Target) || !parsed.Records.Any(r => r.Type == 16 && r.Name == ptr.Target)))
                                await MulticastAsync(DnsPacket.Query(ptr.Target!, 255)).ConfigureAwait(false);
                        }
                        foreach (var srv in parsed.Records.Where(r => r.Type == 33 && r.Target is not null && r.Name.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase)))
                        {
                            bool missing;
                            lock (_records) missing = _records.Find(srv.Target!, 1) is null;
                            if (missing && !parsed.Records.Any(r => r.Type == 1 && r.Name == srv.Target)) await MulticastAsync(DnsPacket.Query(srv.Target!, 1)).ConfigureAwait(false);
                        }
                        lock (_records) _records.Update(parsed.Records);
                        Refresh();
                    }
                }
                catch (Exception ex) when (ex is SocketException or System.Net.NetworkInformation.NetworkInformationException) { Error?.Invoke(ex); }
                catch (Exception ex) when (ex is IOException or ArgumentException or IndexOutOfRangeException or OverflowException) { /* Ignore malformed multicast datagrams. */ }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException) { if (!_stop.IsCancellationRequested) Error?.Invoke(ex); }
    }
    private void Refresh()
    {
        List<DiscoveryPeer> peers = [];
        lock (_records)
        {
            _records.Expire();
            foreach (var srv in _records.Records.Where(r => r.Type == 33 && r.Name.EndsWith("." + Service, StringComparison.OrdinalIgnoreCase)))
            {
                var txt = _records.Find(srv.Name, 16);
                if (srv.Target is null || txt?.Txt is null) continue;
                var addresses = _records.Addresses(srv.Target, _interfaces.Current);
                if (addresses.Length == 0) continue;
                var name = srv.Name[..^(Service.Length + 1)];
                var peer = DiscoveryPeer.FromTxt(name, addresses[0], srv.Port, txt.Txt, _fingerprint, _policy);
                if (peer is not null) peer = peer with { AddressCandidates = addresses };
                if (peer is not null && !peers.Any(p => p.Fingerprint == peer.Fingerprint)) peers.Add(peer);
            }
        }
        var ordered = peers.OrderBy(p => p.Name, StringComparer.CurrentCulture).ToArray();
        if (!Peers.Select(PeerKey).SequenceEqual(ordered.Select(PeerKey))) { Volatile.Write(ref _peers, ordered); PeersChanged?.Invoke(ordered); }
    }
    private static string PeerKey(DiscoveryPeer peer) => $"{peer.Name}/{peer.Port}/{peer.Fingerprint}/{peer.DeviceType}/{peer.App}/{string.Join(",", peer.AddressCandidates)}";
    public async ValueTask DisposeAsync()
    {
        try { await AdvertiseAsync(0).ConfigureAwait(false); } catch (Exception ex) when (ex is SocketException or ObjectDisposedException or OperationCanceledException or System.Net.NetworkInformation.NetworkInformationException) { }
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        _stop.Cancel(); _transport.Dispose();
        await Task.WhenAll(_receive, _announce).ConfigureAwait(false);
        // Refresh callbacks use the cancelled token; keep synchronization objects alive until GC.

    }
}

internal sealed record DnsRecord(string Name, ushort Type, uint Ttl, string? Target = null, int Port = 0, Dictionary<string, string>? Txt = null, string? Address = null)
{
    public DateTimeOffset Expires { get; } = DateTimeOffset.UtcNow.AddSeconds(Math.Min(Ttl, 120));
}
internal static class DnsPacket
{
    public static byte[] Query(string service, ushort type = 12)
    {
        using var bytes = new MemoryStream(); var writer = new BinaryWriter(bytes); Header(writer, 0, 1, 0); Name(writer, service); U16(writer, type); U16(writer, 1); return bytes.ToArray();
    }
    public static byte[] Advertisement(string service, string instance, string host, int port, Dictionary<string, string> txt, IPAddress[] addresses, uint ttl)
    {
        using var bytes = new MemoryStream(); var w = new BinaryWriter(bytes); Header(w, 0x8400, 0, 3 + addresses.Length);
        Record(w, service, 12, ttl, data => Name(data, instance));
        Record(w, instance, 33, ttl, data => { U16(data, 0); U16(data, 0); U16(data, (ushort)port); Name(data, host); });
        Record(w, instance, 16, ttl, data => { foreach (var item in txt) { var value = Encoding.UTF8.GetBytes(item.Key + "=" + item.Value); data.Write((byte)value.Length); data.Write(value); } });
        foreach (var address in addresses) Record(w, host, 1, ttl, data => data.Write(address.GetAddressBytes()));
        return bytes.ToArray();
    }
    private static void Header(BinaryWriter w, ushort flags, int questions, int answers) { U16(w, 0); U16(w, flags); U16(w, (ushort)questions); U16(w, (ushort)answers); U16(w, 0); U16(w, 0); }
    private static void U16(BinaryWriter w, ushort value) { w.Write((byte)(value >> 8)); w.Write((byte)value); }
    private static void Name(BinaryWriter w, string name) { foreach (var label in name.Split('.')) { var data = Encoding.UTF8.GetBytes(label); if (data.Length is 0 or > 63) throw new IOException("Invalid DNS label."); w.Write((byte)data.Length); w.Write(data); } w.Write((byte)0); }
    private static void Record(BinaryWriter w, string name, ushort type, uint ttl, Action<BinaryWriter> write)
    {
        Name(w, name); U16(w, type); U16(w, type == 12 ? (ushort)1 : (ushort)0x8001); w.Write((byte)(ttl >> 24)); w.Write((byte)(ttl >> 16)); w.Write((byte)(ttl >> 8)); w.Write((byte)ttl);
        using var content = new MemoryStream(); write(new BinaryWriter(content)); U16(w, checked((ushort)content.Length)); w.Write(content.ToArray());
    }
    internal static (bool Response, List<string> Questions, List<DnsRecord> Records) Read(byte[] data)
    {
        if (data.Length is < 12 or > 9000) throw new IOException("Invalid DNS packet.");
        var offset = 0; _ = Read16(data, ref offset); var flags = Read16(data, ref offset); var qd = Read16(data, ref offset); var count = Read16(data, ref offset) + Read16(data, ref offset) + Read16(data, ref offset);
        if (qd > 128 || count > 128) throw new IOException("Too many DNS records.");
        List<string> questions = []; List<DnsRecord> records = [];
        for (var i = 0; i < qd; i++) { questions.Add(ReadName(data, ref offset)); _ = Read16(data, ref offset); _ = Read16(data, ref offset); }
        for (var i = 0; i < count; i++)
        {
            var name = ReadName(data, ref offset); var type = Read16(data, ref offset); _ = Read16(data, ref offset);
            if (offset + 6 > data.Length) throw new IOException("Truncated DNS record.");
            var ttl = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset)); offset += 4;
            var length = Read16(data, ref offset); var end = checked(offset + length); if (end > data.Length) throw new IOException("Truncated DNS data.");
            if (type == 12) { var target = ReadName(data, ref offset); if (offset > end) throw new IOException("Invalid PTR."); records.Add(new(name, type, ttl, target)); }
            else if (type == 1 && length == 4) records.Add(new(name, type, ttl, Address: new IPAddress(data.AsSpan(offset, 4)).ToString()));
            else if (type == 33 && length >= 7) { offset += 4; var port = Read16(data, ref offset); var target = ReadName(data, ref offset); if (offset > end) throw new IOException("Invalid SRV."); records.Add(new(name, type, ttl, target, port)); }
            else if (type == 16)
            {
                Dictionary<string, string> txt = new(StringComparer.OrdinalIgnoreCase);
                while (offset < end) { var size = data[offset++]; if (offset + size > end) throw new IOException("Invalid TXT."); var value = Encoding.UTF8.GetString(data, offset, size); offset += size; var split = value.IndexOf('='); if (split > 0 && !txt.TryAdd(value[..split], value[(split + 1)..])) throw new IOException("Duplicate TXT key."); }
                records.Add(new(name, type, ttl, Txt: txt));
            }
            offset = end;
        }
        return ((flags & 0x8000) != 0, questions, records);
    }
    private static ushort Read16(byte[] data, ref int offset) { if (offset + 2 > data.Length) throw new IOException("Truncated DNS packet."); var value = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(offset)); offset += 2; return value; }
    private static string ReadName(byte[] data, ref int offset, int depth = 0)
    {
        if (depth > 16) throw new IOException("DNS compression loop.");
        List<string> labels = []; var length = 0;
        while (true)
        {
            if (offset >= data.Length) throw new IOException("Truncated DNS name.");
            var size = data[offset++]; if (size == 0) break;
            if ((size & 0xC0) == 0xC0) { if (offset >= data.Length) throw new IOException("Invalid DNS pointer."); var pointer = ((size & 63) << 8) | data[offset++]; labels.Add(ReadName(data, ref pointer, depth + 1)); break; }
            if (size > 63 || offset + size > data.Length || (length += size + 1) > 255) throw new IOException("Invalid DNS name.");
            labels.Add(Encoding.UTF8.GetString(data, offset, size)); offset += size;
        }
        var name = string.Join('.', labels); if (Encoding.UTF8.GetByteCount(name) > 255) throw new IOException("DNS name too long."); return name;
    }
}
