using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace LimLink.Updates;
public sealed class NoReleaseException : Exception { }
public sealed record AvailableUpdate(string Version, Uri Url, string Notes);
public static class UpdateManifest {
    public const int MaxBytes = 131072;
    public static AvailableUpdate? Parse(string json, Version installed) {
        if (Encoding.UTF8.GetByteCount(json) > MaxBytes) throw new FormatException();
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        if (!doc.RootElement.TryGetProperty("windows",out var item) || item.ValueKind == JsonValueKind.Null) throw new NoReleaseException();
        var version = item.GetProperty("version").GetString() ?? "";
        if (!Regex.IsMatch(version,@"^[0-9]{1,5}\.[0-9]{1,5}(\.[0-9]{1,5})?$") || !Version.TryParse(version,out var parsed)) throw new FormatException();
        var next = new Version(parsed.Major,parsed.Minor,Math.Max(0,parsed.Build),0);
        if (item.GetProperty("url").GetString() != "/download/windows") throw new FormatException();
        if (!item.GetProperty("size").TryGetInt64(out var size) || size <= 0) throw new FormatException();
        if (!Regex.IsMatch(item.GetProperty("sha256").GetString() ?? "",@"^[0-9a-fA-F]{64}$")) throw new FormatException();
        var notes = item.TryGetProperty("notes",out var note) ? note.GetString() ?? "" : "";
        if (notes.Length > 8000) throw new FormatException();
        var current = new Version(installed.Major, installed.Minor, Math.Max(0, installed.Build), Math.Max(0, installed.Revision));
        return next > current ? new(version,new Uri("https://limlink.floatmax-tech.com/download/windows"),notes) : null;
    }
}
