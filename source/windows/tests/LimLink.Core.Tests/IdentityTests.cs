using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LimLink;

namespace LimLink.Core.Tests;

public class IdentityTests
{
    [Fact]
    public void Certificate_subject_is_cn_limlink_and_key_is_p256()
    {
        using var certificate = DeviceCertificate.Create();
        Assert.Equal(LimLinkProtocol.CertificateSubject, certificate.Subject);
        Assert.Equal(LimLinkProtocol.CertificateSubject, certificate.Issuer);
        if (OperatingSystem.IsWindows())
        {
            Assert.Equal(LimLinkProtocol.TemporaryProductId, certificate.FriendlyName);
        }
        using var key = certificate.GetECDsaPublicKey();
        Assert.NotNull(key);
        Assert.Equal(256, key.KeySize);
        Assert.Equal("1.2.840.10045.3.1.7", key.ExportParameters(false).Curve.Oid.Value);
    }

    [Fact]
    public void Fingerprint_is_spki_sha256_base64url_not_the_whole_certificate()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var first = Sign(key, years: 1);
        using var second = Sign(key, years: 3);
        Assert.NotEqual(Convert.ToHexString(first.RawData), Convert.ToHexString(second.RawData));

        var fingerprint = Fingerprint.Compute(first);
        Assert.Equal(fingerprint, Fingerprint.Compute(second));
        Assert.Equal(43, fingerprint.Length);
        Assert.DoesNotContain('=', fingerprint);
        Assert.DoesNotContain('+', fingerprint);
        Assert.DoesNotContain('/', fingerprint);
        Assert.True(Fingerprint.TryDecode(fingerprint, out var hash));
        Assert.Equal(32, hash.Length);
        Assert.Equal("Ab3D-9xQk-Mn12-Pqrs", Fingerprint.ToDisplay("Ab3D9xQkMn12Pqrsextra"));
    }

    [Fact]
    public async Task Identity_is_reused_from_the_store()
    {
        var directory = Directory.CreateTempSubdirectory("limlink-id").FullName;
        try
        {
            var store = new FileDeviceIdentityStore(
                Path.Combine(directory, "device-identity.bin"),
                new PassthroughSecretProtector());
            using var created = await DeviceIdentity.LoadOrCreateAsync(store);
            var fingerprint = Fingerprint.Compute(created);
            created.Dispose();

            using var loaded = await DeviceIdentity.LoadOrCreateAsync(store);
            Assert.Equal(fingerprint, Fingerprint.Compute(loaded));
            Assert.True(loaded.HasPrivateKey);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Dpapi_round_trip_on_windows()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("DPAPI is only available on Windows.");
        }

        var protector = new DpapiSecretProtector();
        var plaintext = RandomNumberGenerator.GetBytes(48);
        var protectedBytes = protector.Protect(plaintext);
        Assert.NotEqual(plaintext, protectedBytes);
        Assert.Equal(plaintext, protector.Unprotect(protectedBytes));
    }

    [Fact]
    public async Task Dpapi_store_keeps_the_same_device_on_windows()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("DPAPI is only available on Windows.");
        }

        var directory = Directory.CreateTempSubdirectory("limlink-dpapi").FullName;
        try
        {
            var path = Path.Combine(directory, "device-identity.bin");
            var store = new FileDeviceIdentityStore(path, new DpapiSecretProtector());
            using var created = await DeviceIdentity.LoadOrCreateAsync(store);
            var fingerprint = Fingerprint.Compute(created);
            var atRest = await File.ReadAllBytesAsync(path);
            Assert.DoesNotContain(fingerprint, System.Text.Encoding.ASCII.GetString(atRest));
            created.Dispose();

            using var loaded = await DeviceIdentity.LoadOrCreateAsync(store);
            Assert.Equal(fingerprint, Fingerprint.Compute(loaded));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Peer_app_comparison_follows_section_1_2()
    {
        Assert.Equal("limlink", PeerAppPolicy.NormalizePeer(null));
        Assert.Equal("", PeerAppPolicy.NormalizePeer("  "));
        Assert.Equal("casecheck", PeerAppPolicy.NormalizePeer("CaseCheck"));

        var same = new PeerAppPolicy("LimLink", allowedPeerApps: null);
        Assert.Equal("limlink", same.HostAppId);
        Assert.True(same.Allows(null));
        Assert.True(same.Allows("LIMLINK"));
        Assert.True(same.Allows("casecheck"));

        var both = new PeerAppPolicy("limlink", ["limlink", "CaseCheck"]);
        Assert.True(both.Allows("casecheck"));
        Assert.Throws<ArgumentException>(() => new PeerAppPolicy("this-app-id-is-too-long", null));
    }

    [Fact]
    public void Port_candidates_follow_the_protocol()
    {
        var ports = PortSelector.Candidates(52470, allowSystemPortFallback: true);
        Assert.Equal(Enumerable.Range(52470, 10).Append(0), ports);
        Assert.Equal(Enumerable.Range(52470, 10), PortSelector.Candidates(52470, allowSystemPortFallback: false));
    }

    [Fact]
    public void Server_tls_options_are_tls13_only()
    {
        var options = new System.Net.Security.SslServerAuthenticationOptions();
        LimLinkTls.ApplyServer(options);
        Assert.Equal(System.Security.Authentication.SslProtocols.Tls13, options.EnabledSslProtocols);
        Assert.False(options.AllowRenegotiation);
        Assert.False(options.AllowTlsResume);
        Assert.True(options.ClientCertificateRequired);
        Assert.Equal("http/1.1", Assert.Single(options.ApplicationProtocols!).ToString());
    }

    private static X509Certificate2 Sign(ECDsa key, int years)
    {
        var request = new CertificateRequest(LimLinkProtocol.CertificateSubject, key, HashAlgorithmName.SHA256);
        var issued = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(years));
        var pfx = issued.Export(X509ContentType.Pfx);
        issued.Dispose();
        return X509CertificateLoader.LoadPkcs12(pfx, (string?)null, X509KeyStorageFlags.Exportable);
    }
}
