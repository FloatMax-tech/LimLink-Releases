using System.Buffers.Text;
using System.Security.Cryptography.X509Certificates;

namespace LimLink;

/// <summary>
/// Protocol 4.1: SHA-256 of the certificate SubjectPublicKeyInfo (DER),
/// base64url without padding (43 characters). This is not a hash of the
/// whole certificate, so a later change of validity does not change identity.
/// </summary>
public static class Fingerprint
{
    public static string Compute(X509Certificate2 certificate)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        var spki = certificate.PublicKey.ExportSubjectPublicKeyInfo();
        var hash = SHA256.HashData(spki);
        return Base64Url.EncodeToString(hash);
    }

    public static bool TryDecode(string fingerprint, out byte[] hash)
    {
        hash = [];
        if (string.IsNullOrEmpty(fingerprint))
        {
            return false;
        }

        try
        {
            hash = Base64Url.DecodeFromChars(fingerprint);
        }
        catch (FormatException)
        {
            return false;
        }

        return hash.Length == 32;
    }

    public static bool FixedEquals(string actual, string expected)
    {
        if (!TryDecode(actual, out var actualBytes) || !TryDecode(expected, out var expectedBytes))
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(actualBytes, expectedBytes);
    }

    /// <summary>First 16 characters, grouped by 4 (protocol 4.1).</summary>
    public static string ToDisplay(string fingerprint)
    {
        ArgumentException.ThrowIfNullOrEmpty(fingerprint);
        var head = fingerprint.Length >= 16 ? fingerprint[..16] : fingerprint;
        var groups = head.Length / 4;
        if (groups == 0)
        {
            return head;
        }

        var parts = new string[groups];
        for (var i = 0; i < groups; i++)
        {
            parts[i] = head.Substring(i * 4, 4);
        }

        return string.Join('-', parts);
    }
}
