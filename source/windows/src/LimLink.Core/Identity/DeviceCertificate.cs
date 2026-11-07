using System.Security.Cryptography.X509Certificates;

namespace LimLink;

public static class DeviceCertificate
{
    public static X509Certificate2 Create()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(LimLinkProtocol.CertificateSubject, key, HashAlgorithmName.SHA256);

        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, critical: true));
        request.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, critical: true));

        var eku = new OidCollection
        {
            new Oid("1.3.6.1.5.5.7.3.1"),
            new Oid("1.3.6.1.5.5.7.3.2"),
        };
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(eku, critical: false));

        // SAN is not identity. It keeps stacks that expect a SAN from rejecting the cert.
        // The name is the protocol code, not a person or device.
        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName(LimLinkProtocol.CodeName);
        request.CertificateExtensions.Add(san.Build());

        var notBefore = DateTimeOffset.UtcNow.AddMinutes(-5);
        var notAfter = notBefore.AddYears(10);
        var issued = request.CreateSelfSigned(notBefore, notAfter);
        var pfx = issued.Export(X509ContentType.Pfx);
        issued.Dispose();
        var loaded = LoadPfx(pfx);
        AssignFriendlyName(loaded);
        return loaded;
    }

    public static X509Certificate2 LoadPfx(byte[] pfx)
    {
        var flags = OperatingSystem.IsWindows()
            ? X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable | X509KeyStorageFlags.PersistKeySet
            : X509KeyStorageFlags.Exportable;
        var cert = X509CertificateLoader.LoadPkcs12(pfx, ReadOnlySpan<char>.Empty, flags);
        AssignFriendlyName(cert);
        return cert;
    }

    public static void EnsureUsable(X509Certificate2 certificate)
    {
        if (!string.Equals(certificate.Subject, LimLinkProtocol.CertificateSubject, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Device certificate subject must be {LimLinkProtocol.CertificateSubject}.");
        }

        if (!certificate.HasPrivateKey)
        {
            throw new InvalidOperationException("Device certificate is missing its private key.");
        }

        using var key = certificate.GetECDsaPrivateKey()
            ?? throw new InvalidOperationException("Device certificate key is not ECDSA P-256.");
        if (key.KeySize != 256)
        {
            throw new InvalidOperationException("Device certificate key is not ECDSA P-256.");
        }
    }

    private static void AssignFriendlyName(X509Certificate2 certificate)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            certificate.FriendlyName = LimLinkProtocol.TemporaryProductId;
        }
        catch (PlatformNotSupportedException)
        {
        }
        catch (CryptographicException)
        {
        }
    }
}
