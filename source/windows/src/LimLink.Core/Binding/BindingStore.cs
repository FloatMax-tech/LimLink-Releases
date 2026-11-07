using System.Text.Json;
namespace LimLink;

public sealed record DeviceBinding(string OwnFingerprint, string PeerFingerprint, string BindingId, string Alias, string DeviceType, DateTimeOffset BoundAt);
public interface IBindingStore
{
    IReadOnlyList<DeviceBinding> Read();
    void Write(IReadOnlyList<DeviceBinding> bindings);
}

/// <summary>Current-user DPAPI protection with durable same-directory atomic replacement. Errors propagate.</summary>
public sealed class PrivateBindingStore(string path, ISecretProtector protector) : IBindingStore
{
    private readonly object _gate = new();
    public IReadOnlyList<DeviceBinding> Read()
    {
        lock (_gate)
        {
            if (!File.Exists(path)) return [];
            if (new FileInfo(path).Length > 1_048_576) throw new IOException("Invalid binding store size.");
            return JsonSerializer.Deserialize<DeviceBinding[]>(protector.Unprotect(File.ReadAllBytes(path)), ProtocolJson.Options) ?? throw new IOException("Invalid binding store.");
        }
    }
    public void Write(IReadOnlyList<DeviceBinding> bindings)
    {
        lock (_gate)
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
            Directory.CreateDirectory(directory);
            var temporary = Path.Combine(directory, ".bindings-" + Guid.NewGuid().ToString("N"));
            try
            {
                var data = protector.Protect(JsonSerializer.SerializeToUtf8Bytes(bindings, ProtocolJson.Options));
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { stream.Write(data); stream.Flush(true); }
                File.Move(temporary, path, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
}
internal sealed class UnavailableBindingStore : IBindingStore
{
    public IReadOnlyList<DeviceBinding> Read() => [];
    public void Write(IReadOnlyList<DeviceBinding> bindings) => throw new IOException("Secure binding storage is unavailable.");
}
