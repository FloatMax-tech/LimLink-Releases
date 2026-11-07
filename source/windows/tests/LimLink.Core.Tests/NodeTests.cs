using System.Net;
using System.Net.Security;
using System.Security.Authentication;
using LimLink;

namespace LimLink.Core.Tests;

public class NodeTests
{
    [Fact]
    public async Task Two_nodes_complete_mutual_hello()
    {
        await using var left = await TestNodes.StartAsync();
        await using var right = await TestNodes.StartAsync();
        using var leftClient = TestNodes.Client(left.Node);
        using var rightClient = TestNodes.Client(right.Node);

        var leftToRight = await leftClient.HelloAsync("127.0.0.1", right.Node.Port, right.Node.Fingerprint);
        var rightToLeft = await rightClient.HelloAsync("127.0.0.1", left.Node.Port, left.Node.Fingerprint);

        Assert.True(leftToRight.AppCompatible);
        Assert.True(rightToLeft.AppCompatible);
        Assert.Equal("limlink", leftToRight.Peer.App);
        Assert.Equal(right.Node.Port, leftToRight.Peer.Port);
        Assert.Equal("windows", leftToRight.Peer.DevType);
        Assert.Equal("unit-limlink", leftToRight.Peer.Alias);
        Assert.Contains("1.0", leftToRight.Peer.Proto!);
        Assert.False(leftToRight.Peer.Trusted);
        Assert.False(leftToRight.Peer.Busy);
        Assert.Equal(LimLinkProtocol.CertificateSubject, left.Node.Certificate.Subject);
        Assert.Equal(LimLinkProtocol.CertificateSubject, right.Node.Certificate.Issuer);
    }

    [Fact]
    public async Task Wrong_pinned_fingerprint_is_rejected()
    {
        await using var node = await TestNodes.StartAsync();
        using var other = DeviceCertificate.Create();
        var wrong = Fingerprint.Compute(other);
        using var client = TestNodes.Client(node.Node);

        var error = await Assert.ThrowsAsync<LimLinkConnectionException>(() =>
            client.HelloAsync("127.0.0.1", node.Node.Port, wrong));
        Assert.Equal(LimLinkConnectionFailure.FingerprintMismatch, error.Failure);
    }

    [Fact]
    public async Task App_mismatch_returns_403_and_does_not_pass_the_invite_gate()
    {
        await using var peer = await TestNodes.StartAsync(hostAppId: "casecheck", allowedPeerApps: ["casecheck"]);
        await using var self = await TestNodes.StartAsync(hostAppId: "limlink", allowedPeerApps: ["limlink"]);
        using var client = self.Node.CreateClient();

        var hello = await client.HelloAsync("127.0.0.1", peer.Node.Port, peer.Node.Fingerprint);
        Assert.False(hello.AppCompatible);
        Assert.Equal("casecheck", hello.Peer.App);
        Assert.Equal(0, peer.Node.Server.InviteRequestsPastAppGate);

        var mismatch = await client.PostExpectingErrorAsync(
            "127.0.0.1",
            peer.Node.Port,
            peer.Node.Fingerprint,
            "/limlink/v1/invite/hello");
        Assert.Equal(LimLinkProtocol.ErrorAppMismatch, mismatch.Code);
        Assert.False(mismatch.Retryable);
        Assert.Equal("casecheck", mismatch.DetailApp);
        Assert.Equal(0, peer.Node.Server.InviteRequestsPastAppGate);

        var sessions = await client.PostExpectingErrorAsync(
            "127.0.0.1",
            peer.Node.Port,
            peer.Node.Fingerprint,
            "/limlink/v1/sessions");
        Assert.Equal(LimLinkProtocol.ErrorAppMismatch, sessions.Code);
        Assert.False(sessions.Retryable);
    }

    [Fact]
    public async Task Default_registry_accepts_peer_hello_but_peer_can_restrict_requests()
    {
        await using var peer = await TestNodes.StartAsync(hostAppId: "casecheck", allowedPeerApps: ["casecheck"]);
        await using var self = await TestNodes.StartAsync();
        using var client = self.Node.CreateClient();

        var hello = await client.HelloAsync("127.0.0.1", peer.Node.Port, peer.Node.Fingerprint);
        Assert.True(hello.AppCompatible); // The client's default interop group contains both apps.
        Assert.Equal("casecheck", hello.Peer.App);

        // A successful hello does not bypass the receiver's narrower admission policy.
        var denied = await client.PostExpectingErrorAsync("127.0.0.1", peer.Node.Port,
            peer.Node.Fingerprint, "/limlink/v1/sessions");
        Assert.Equal(LimLinkProtocol.ErrorAppMismatch, denied.Code);
        Assert.False(denied.Retryable);
        Assert.Equal("casecheck", denied.DetailApp);
        Assert.Equal(0, peer.Node.Server.InviteRequestsPastAppGate);
    }

    [Fact]
    public async Task Missing_app_header_is_limlink_and_matching_invite_is_not_counted_as_mismatch()
    {
        await using var peer = await TestNodes.StartAsync(hostAppId: "casecheck", allowedPeerApps: ["casecheck"]);
        await using var self = await TestNodes.StartAsync();
        using var silent = TestNodes.Client(self.Node, sendAppHeader: false);

        var error = await silent.PostExpectingErrorAsync(
            "127.0.0.1",
            peer.Node.Port,
            peer.Node.Fingerprint,
            "/limlink/v1/pair/init");
        Assert.Equal(LimLinkProtocol.ErrorAppMismatch, error.Code);
        Assert.Equal(0, peer.Node.Server.InviteRequestsPastAppGate);

        using var same = TestNodes.Client(peer.Node, hostAppId: "CaseCheck");
        var stub = await same.PostExpectingErrorAsync(
            "127.0.0.1",
            peer.Node.Port,
            peer.Node.Fingerprint,
            "/limlink/v1/invite/pake");
        Assert.Equal(LimLinkProtocol.ErrorNotImplemented, stub.Code);
        Assert.Equal(1, peer.Node.Server.InviteRequestsPastAppGate);

        var unpaired = await same.PostExpectingErrorAsync(
            "127.0.0.1",
            peer.Node.Port,
            peer.Node.Fingerprint,
            "/limlink/v1/sessions");
        Assert.Equal(LimLinkProtocol.ErrorNotPaired, unpaired.Code);
        Assert.False(unpaired.Retryable);
        Assert.Equal(1, peer.Node.Server.InviteRequestsPastAppGate);
    }

    [Fact]
    public async Task Unknown_peer_stubs_use_the_protocol_error_shape()
    {
        await using var node = await TestNodes.StartAsync();
        using var client = TestNodes.Client(node.Node);

        var notPaired = await client.PostExpectingErrorAsync(
            "127.0.0.1", node.Node.Port, node.Node.Fingerprint, "/limlink/v1/sessions");
        Assert.Equal("E_NOT_PAIRED", notPaired.Code);
        Assert.False(string.IsNullOrWhiteSpace(notPaired.Message));
        Assert.False(notPaired.Retryable);

        var link = await client.PostExpectingErrorAsync(
            "127.0.0.1", node.Node.Port, node.Node.Fingerprint, "/limlink/v1/link/invite");
        Assert.Equal("E_NOT_IMPLEMENTED", link.Code);
        Assert.False(link.Retryable);
    }

    [Fact]
    public async Task Unsupported_version_is_400()
    {
        await using var node = await TestNodes.StartAsync();
        using var client = TestNodes.Client(node.Node);
        var error = await Assert.ThrowsAsync<LimLinkProtocolException>(() => client.HelloAsync(
            "127.0.0.1",
            node.Node.Port,
            node.Node.Fingerprint,
            new HelloMessage { Proto = ["9.0"] }));
        Assert.Equal(400, error.StatusCode);
        Assert.Equal(LimLinkProtocol.ErrorUnsupportedVersion, error.Error.Code);
        Assert.False(error.Error.Retryable);
    }

    [Fact]
    public async Task Port_falls_back_when_52470_is_taken()
    {
        await FixedPortGate.Instance.WaitAsync();
        try
        {
            var blocker = new System.Net.Sockets.TcpListener(IPAddress.Any, LimLinkProtocol.DefaultPort);
            try { blocker.Start(); }
            catch (System.Net.Sockets.SocketException ex) when (ex.SocketErrorCode == System.Net.Sockets.SocketError.AddressAlreadyInUse)
            {
                // Another local LimLink host already satisfies this test's occupied-port precondition.
            }
            try
            {
                await using var node = await TestNodes.StartAsync(explicitPort: null);
                Assert.NotEqual(LimLinkProtocol.DefaultPort, node.Node.Port);
                Assert.InRange(node.Node.Port, 52471, 65535);
                using var client = TestNodes.Client(node.Node);
                var hello = await client.HelloAsync("127.0.0.1", node.Node.Port, node.Node.Fingerprint);
                Assert.Equal(node.Node.Port, hello.Peer.Port);
                Assert.True(hello.AppCompatible);
            }
            finally
            {
                blocker.Stop();
            }
        }
        finally
        {
            FixedPortGate.Instance.Release();
        }
    }

    [Fact]
    public async Task Port_unavailable_when_the_range_is_taken_and_fallback_is_off()
    {
        await FixedPortGate.Instance.WaitAsync();
        List<System.Net.Sockets.TcpListener>? held = null;
        try
        {
            held = await TestNodes.OccupyAsync(52470, 52479);
            var error = await Assert.ThrowsAsync<LimLinkPortException>(() =>
                TestNodes.StartAsync(explicitPort: null, allowSystemPortFallback: false));
            Assert.Equal(LimLinkProtocol.PortUnavailable, error.Code);
        }
        finally
        {
            if (held is not null)
            {
                foreach (var listener in held)
                {
                    listener.Stop();
                }
            }

            FixedPortGate.Instance.Release();
        }
    }

    [Fact]
    public async Task Handshake_reports_subject_alpn_and_tls13()
    {
        await using var node = await TestNodes.StartAsync();
        using var client = TestNodes.Client(node.Node);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var first = await client.HandshakeAsync("127.0.0.1", node.Node.Port, node.Node.Fingerprint, timeout.Token);
        var second = await client.HandshakeAsync("127.0.0.1", node.Node.Port, node.Node.Fingerprint, timeout.Token);

        Assert.Equal(SslProtocols.Tls13, first.Protocol);
        Assert.Equal(SslProtocols.Tls13, second.Protocol);
        Assert.Equal("http/1.1", first.ApplicationProtocol);
        Assert.Equal(LimLinkProtocol.CertificateSubject, first.RemoteSubject);
        Assert.Equal(node.Node.Fingerprint, first.RemoteFingerprint);
        Assert.True(first.ClientCertificateSent);
        Assert.True(node.Node.Server.HandshakesWithClientCertificate >= 2);
        Assert.Equal(SslProtocols.Tls13, node.Node.Server.Tls.Protocols);
        Assert.False(node.Node.Server.Tls.AllowTlsResume);
        Assert.False(node.Node.Server.Tls.AllowRenegotiation);
        Assert.Contains("http/1.1", node.Node.Server.Tls.ApplicationProtocols, StringComparison.Ordinal);
    }
}
