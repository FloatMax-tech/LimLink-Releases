using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LimLink;

internal sealed record DiscoveryInterface(IPAddress Address, int PrefixLength)
{
    public DiscoveryInterface(string address, int prefixLength) : this(IPAddress.Parse(address), prefixLength) { }
    public bool Contains(IPAddress address)
    {
        var a = Address.GetAddressBytes(); var b = address.GetAddressBytes();
        if (a.Length != b.Length) return false;
        var prefix = Math.Clamp(PrefixLength, 0, 32);
        for (var i = 0; i < a.Length; i++)
        {
            var bits = Math.Clamp(prefix - i * 8, 0, 8); var mask = 255 << (8 - bits);
            if ((a[i] & mask) != (b[i] & mask)) return false;
        }
        return true;
    }
}

internal interface IDiscoveryTransport : IDisposable
{
    DiscoveryInterface[] GetInterfaces();
    void SetMemberships(DiscoveryInterface[] interfaces);
    ValueTask SendAsync(byte[] packet, IPAddress address, CancellationToken token);
    ValueTask<byte[]> ReceiveAsync(CancellationToken token);
}

/// <summary>Serializes membership changes with sends, preserving healthy adapters after one adapter fails.</summary>
internal sealed class DiscoveryInterfaces(IDiscoveryTransport transport) : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1);
    private DiscoveryInterface[] _current = [];
    public DiscoveryInterface[] Current => Volatile.Read(ref _current);
    public event Action<Exception>? Error;
    public async Task RefreshAsync(CancellationToken token)
    {
        await _gate.WaitAsync(token).ConfigureAwait(false);
        try { Refresh(); }
        finally { _gate.Release(); }
    }
    private void Refresh()
    {
        var next = transport.GetInterfaces();
        transport.SetMemberships(next);
        Volatile.Write(ref _current, next);
    }
    public async Task SendAsync(Func<IPAddress, byte[]> packet, CancellationToken token)
    {
        await _gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Refresh();
            SocketException? failure = null;
            var sent = 0;
            foreach (var item in _current)
            {
                try { await transport.SendAsync(packet(item.Address), item.Address, token).ConfigureAwait(false); sent++; }
                catch (SocketException ex) { failure = ex; }
            }
            if (sent == 0 && failure is not null) Error?.Invoke(failure);
        }
        finally { _gate.Release(); }
    }
    public void Dispose() => _gate.Dispose();
}

internal sealed class UdpDiscoveryTransport : IDiscoveryTransport
{
    private readonly UdpClient _udp = new(AddressFamily.InterNetwork);
    private readonly HashSet<IPAddress> _joined = [];
    private static readonly IPEndPoint Multicast = new(IPAddress.Parse("224.0.0.251"), 5353);
    public int MulticastTimeToLive => (int)_udp.Client.GetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive)!;
    public UdpDiscoveryTransport()
    {
        try
        {
            _udp.ExclusiveAddressUse = false;
            _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
            _udp.Ttl = 255;
            _udp.MulticastLoopback = true;
        }
        catch { _udp.Dispose(); throw; }
    }
    public DiscoveryInterface[] GetInterfaces()
    {
        List<DiscoveryInterface> result = [];
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            try
            {
                if (network.OperationalStatus != OperationalStatus.Up || !network.SupportsMulticast || network.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                result.AddRange(network.GetIPProperties().UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address))
                    .Select(a => new DiscoveryInterface(a.Address, a.PrefixLength)));
            }
            catch (NetworkInformationException) { /* Continue with adapters whose properties remain available. */ }
        }
        return result.Distinct().ToArray();
    }
    public void SetMemberships(DiscoveryInterface[] interfaces)
    {
        var addresses = interfaces.Select(i => i.Address).ToHashSet();
        foreach (var old in _joined.Where(a => !addresses.Contains(a)).ToArray())
        {
            try { _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.DropMembership, new MulticastOption(Multicast.Address, old)); } catch (SocketException) { }
            _joined.Remove(old);
        }
        foreach (var address in addresses.Where(a => !_joined.Contains(a)))
        {
            try { _udp.JoinMulticastGroup(Multicast.Address, address); _joined.Add(address); }
            catch (SocketException) { /* A transient membership failure is retried on the next refresh. */ }
        }
    }
    public async ValueTask SendAsync(byte[] packet, IPAddress address, CancellationToken token)
    {
        _udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
        await _udp.SendAsync(packet, Multicast, token).ConfigureAwait(false);
    }
    public async ValueTask<byte[]> ReceiveAsync(CancellationToken token) => (await _udp.ReceiveAsync(token).ConfigureAwait(false)).Buffer;
    public void Dispose() => _udp.Dispose();
}

internal sealed class DiscoveryRecordCache
{
    private readonly Dictionary<string, DnsRecord> _records = new(StringComparer.OrdinalIgnoreCase);
    public IEnumerable<DnsRecord> Records => _records.Values;
    private static string Key(DnsRecord r) => r.Name + "/" + r.Type + (r.Type == 1 ? "/" + r.Address : r.Type == 12 ? "/" + r.Target : "");
    public void Update(IEnumerable<DnsRecord> records)
    {
        foreach (var record in records)
        {
            var key = Key(record);
            if (record.Ttl == 0) _records.Remove(key);
            else if (_records.Count < 512 || _records.ContainsKey(key)) _records[key] = record;
        }
        Expire();
    }
    public void Expire()
    {
        foreach (var key in _records.Where(p => p.Value.Expires <= DateTimeOffset.UtcNow).Select(p => p.Key).ToArray()) _records.Remove(key);
    }
    public DnsRecord? Find(string name, ushort type) => _records.Values.FirstOrDefault(r => r.Type == type && string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase));
    public string[] Addresses(string host, DiscoveryInterface[] interfaces) => _records.Values
        .Where(r => r.Type == 1 && r.Address is not null && string.Equals(r.Name, host, StringComparison.OrdinalIgnoreCase))
        .Select(r => r.Address!).Distinct().OrderByDescending(a => IPAddress.TryParse(a, out var ip) && interfaces.Any(i => i.Contains(ip))).ThenBy(a => a, StringComparer.Ordinal).ToArray();
}
