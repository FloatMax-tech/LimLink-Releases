using System.Security.Cryptography;

namespace LimLink;

public interface ISecretProtector
{
    byte[] Protect(ReadOnlySpan<byte> plaintext);
    byte[] Unprotect(ReadOnlySpan<byte> protectedBytes);
}

/// <summary>DPAPI CurrentUser. The optional entropy is the temporary product id.</summary>
public sealed class DpapiSecretProtector : ISecretProtector
{
    private static ReadOnlySpan<byte> Entropy => "com.limlink.dev"u8;

    public byte[] Protect(ReadOnlySpan<byte> plaintext)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("DPAPI is only available on Windows.");
        }

        return ProtectedData.Protect(plaintext.ToArray(), Entropy.ToArray(), DataProtectionScope.CurrentUser);
    }

    public byte[] Unprotect(ReadOnlySpan<byte> protectedBytes)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("DPAPI is only available on Windows.");
        }

        return ProtectedData.Unprotect(protectedBytes.ToArray(), Entropy.ToArray(), DataProtectionScope.CurrentUser);
    }
}

public interface IDeviceIdentityStore
{
    Task<byte[]?> LoadProtectedPfxAsync(CancellationToken cancellationToken);
    Task SaveProtectedPfxAsync(byte[] protectedPfx, CancellationToken cancellationToken);
}

public sealed class FileDeviceIdentityStore : IDeviceIdentityStore
{
    private readonly string _path;
    private readonly ISecretProtector _protector;

    public FileDeviceIdentityStore(string path, ISecretProtector protector)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _path = path;
        _protector = protector;
    }

    public string Path => _path;

    public async Task<byte[]?> LoadProtectedPfxAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_path))
        {
            return null;
        }

        var protectedBytes = await File.ReadAllBytesAsync(_path, cancellationToken).ConfigureAwait(false);
        if (protectedBytes.Length == 0)
        {
            return null;
        }

        return _protector.Unprotect(protectedBytes);
    }

    public async Task SaveProtectedPfxAsync(byte[] pfx, CancellationToken cancellationToken)
    {
        var directory = System.IO.Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var protectedBytes = _protector.Protect(pfx);
        var temporary = _path + ".tmp";
        await File.WriteAllBytesAsync(temporary, protectedBytes, cancellationToken).ConfigureAwait(false);
        File.Move(temporary, _path, overwrite: true);
    }
}

public static class DeviceIdentity
{
    public static async Task<X509Certificate2> LoadOrCreateAsync(
        IDeviceIdentityStore store,
        CancellationToken cancellationToken = default)
    {
        var existing = await store.LoadProtectedPfxAsync(cancellationToken).ConfigureAwait(false);
        if (existing is { Length: > 0 })
        {
            var loaded = DeviceCertificate.LoadPfx(existing);
            DeviceCertificate.EnsureUsable(loaded);
            return loaded;
        }

        using var created = DeviceCertificate.Create();
        var pfx = created.Export(X509ContentType.Pfx);
        await store.SaveProtectedPfxAsync(pfx, cancellationToken).ConfigureAwait(false);
        var reloaded = DeviceCertificate.LoadPfx(pfx);
        DeviceCertificate.EnsureUsable(reloaded);
        return reloaded;
    }
}
