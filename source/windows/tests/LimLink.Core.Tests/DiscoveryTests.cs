using LimLink;
namespace LimLink.Core.Tests;
public sealed class DiscoveryTests
{
    private static readonly string Pin = Convert.ToBase64String(new byte[32]).TrimEnd('=');
    [Fact]
    public void Discovery_uses_Swift_TXT_and_filters_self_and_invalid_fingerprints()
    {
        var txt = new Dictionary<string, string> { ["pv"] = "1.0", ["fp"] = Pin, ["dt"] = "iphone", ["app"] = "limlink" };
        Assert.Null(DiscoveryPeer.FromTxt("Phone", "192.168.1.2", 52470, txt, Pin, new PeerAppPolicy("limlink")));
        Assert.NotNull(DiscoveryPeer.FromTxt("Phone", "192.168.1.2", 52470, txt, "other", new PeerAppPolicy("limlink")));
        txt["fp"] = "invalid";
        Assert.Null(DiscoveryPeer.FromTxt("Phone", "192.168.1.2", 52470, txt, "other", new PeerAppPolicy("limlink")));
    }
    [Theory]
    [InlineData(" LimLink")]
    [InlineData("limlink ")]
    [InlineData("lİmlink")]
    [InlineData("\t")]
    public void Peer_app_rejects_non_ASCII_and_whitespace(string value) => Assert.False(new PeerAppPolicy("limlink").Allows(value));
    [Fact]
    public void Registered_apps_interoperate_but_allowlist_may_narrow()
    {
        Assert.True(new PeerAppPolicy("limlink").Allows("CaseCheck"));
        Assert.True(new PeerAppPolicy("casecheck").Allows(null));
        Assert.False(new PeerAppPolicy("limlink", ["limlink"]).Allows("casecheck"));
    }
}

public sealed class DiscoveryResilienceTests
{
    [Fact]
    public async Task A_failed_interface_does_not_suppress_a_healthy_interface()
    {
        var transport = new TestDiscoveryTransport([new("10.0.0.1", 24), new("192.168.1.10", 24)]) { FailedAddress = "10.0.0.1" };
        using var interfaces = new DiscoveryInterfaces(transport);
        List<Exception> errors = [];
        interfaces.Error += errors.Add;
        await interfaces.SendAsync(address => System.Text.Encoding.ASCII.GetBytes(address.ToString()), default);
        Assert.Empty(errors); // A working discovery path must not report a global interruption.
        Assert.Single(transport.Delivered);
        Assert.Equal("192.168.1.10", System.Text.Encoding.ASCII.GetString(transport.Delivered[0]));
    }

    [Fact]
    public async Task Address_refresh_replaces_removed_interfaces_before_sending()
    {
        var transport = new TestDiscoveryTransport([new("192.168.1.10", 24)]);
        using var interfaces = new DiscoveryInterfaces(transport);
        await interfaces.RefreshAsync(default);
        transport.Current = [new("192.168.2.20", 24)];
        await interfaces.SendAsync(address => System.Text.Encoding.ASCII.GetBytes(address.ToString()), default);
        Assert.Equal("192.168.2.20", System.Text.Encoding.ASCII.GetString(Assert.Single(transport.Delivered)));
        Assert.Equal("192.168.2.20", Assert.Single(transport.Joined).Address.ToString());
    }

    [Fact]
    public void Multiple_address_records_keep_the_same_lan_candidate()
    {
        var cache = new DiscoveryRecordCache();
        cache.Update([new("phone.local", 1, 120, Address: "192.168.1.3"), new("phone.local", 1, 120, Address: "10.8.0.2")]);
        var candidates = cache.Addresses("phone.local", [new("192.168.1.10", 24)]);
        Assert.Equal(new[] { "192.168.1.3", "10.8.0.2" }, candidates);
    }

    [Fact]
    public void Socket_sends_multicast_with_the_required_ip_ttl()
    {
        using var transport = new UdpDiscoveryTransport();
        Assert.Equal(255, transport.MulticastTimeToLive);
    }

    private sealed class TestDiscoveryTransport(DiscoveryInterface[] initial) : IDiscoveryTransport
    {
        public DiscoveryInterface[] Current { get; set; } = initial;
        public string? FailedAddress { get; init; }
        public List<byte[]> Delivered { get; } = [];
        public DiscoveryInterface[] Joined { get; private set; } = [];
        public DiscoveryInterface[] GetInterfaces() => Current;
        public void SetMemberships(DiscoveryInterface[] interfaces) => Joined = interfaces;
        public ValueTask SendAsync(byte[] packet, System.Net.IPAddress address, CancellationToken token)
        {
            if (address.ToString() == FailedAddress) throw new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.NetworkUnreachable);
            Delivered.Add(packet); return ValueTask.CompletedTask;
        }
        public ValueTask<byte[]> ReceiveAsync(CancellationToken token) => throw new NotSupportedException();
        public void Dispose() { }
    }
}
