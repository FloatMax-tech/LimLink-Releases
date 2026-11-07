using System.Text;

namespace LimLink.Files;

public enum PreviewKind { Unsupported, Image, Pdf, Video, Audio, Text }
public sealed record TextPreview(string Text, bool Truncated);

/// <summary>Offline preview allowlist. HTML, SVG, scripts, executables and shortcuts are never launched.</summary>
public static class FilePreviewPolicy
{
    public const int MaximumTextBytes = 1_048_576;
    public const int MaximumImageDimension = 2048;
    public static PreviewKind Classify(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".tif" or ".tiff" or ".webp" or ".heic" or ".heif" => PreviewKind.Image,
        ".pdf" => PreviewKind.Pdf,
        ".mp4" or ".m4v" or ".mov" or ".wmv" or ".avi" or ".mkv" => PreviewKind.Video,
        ".mp3" or ".m4a" or ".aac" or ".wav" or ".flac" or ".ogg" or ".wma" => PreviewKind.Audio,
        ".txt" or ".md" or ".csv" or ".tsv" or ".log" or ".json" or ".xml" or ".yaml" or ".yml" or ".toml" or ".ini" => PreviewKind.Text,
        _ => PreviewKind.Unsupported,
    };
    public static bool CanOpenExternally(string path) => Classify(path) != PreviewKind.Unsupported || Path.GetExtension(path).ToLowerInvariant() is
        ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx" or ".odt" or ".ods" or ".odp" or ".rtf";
    public static async Task<bool> HasNativeMediaHeaderAsync(string path, CancellationToken token = default)
    {
        if (Classify(path) is not (PreviewKind.Video or PreviewKind.Audio)) return false;
        await using var stream = File.OpenRead(path);
        var bytes = new byte[64]; var count = 0;
        while (count < bytes.Length)
        {
            var read = await stream.ReadAsync(bytes.AsMemory(count), token).ConfigureAwait(false);
            if (read == 0) break; count += read;
        }
        // Reject text/URL playlists even when they have a supported media extension.
        var header = Encoding.ASCII.GetString(bytes, 0, count);
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return extension switch
        {
            ".mp4" or ".m4v" or ".mov" or ".m4a" => count >= 12 && header.Substring(4, 4) is "ftyp" or "moov" or "mdat" or "wide",
            ".avi" => header.StartsWith("RIFF", StringComparison.Ordinal) && count >= 12 && header.Substring(8, 4) == "AVI ",
            ".wav" => header.StartsWith("RIFF", StringComparison.Ordinal) && count >= 12 && header.Substring(8, 4) == "WAVE",
            ".flac" => header.StartsWith("fLaC", StringComparison.Ordinal),
            ".ogg" => header.StartsWith("OggS", StringComparison.Ordinal),
            ".mkv" => count >= 4 && bytes[0] == 0x1a && bytes[1] == 0x45 && bytes[2] == 0xdf && bytes[3] == 0xa3,
            ".wmv" or ".wma" => count >= 16 && bytes.AsSpan(0, 16).SequenceEqual(new byte[] { 0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11, 0xa6, 0xd9, 0x00, 0xaa, 0x00, 0x62, 0xce, 0x6c }),
            ".mp3" => header.StartsWith("ID3", StringComparison.Ordinal) || count >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0,
            ".aac" => count >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0,
            _ => false,
        };
    }
    public static async Task<TextPreview> ReadTextAsync(string path, CancellationToken token = default)
    {
        if (Classify(path) != PreviewKind.Text) throw new NotSupportedException("This format has no text preview.");
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 16_384, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var buffer = new byte[MaximumTextBytes + 1]; var count = 0;
        while (count < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(count), token).ConfigureAwait(false);
            if (read == 0) break;
            count += read;
        }
        var truncated = count > MaximumTextBytes;
        using var reader = new StreamReader(new MemoryStream(buffer, 0, Math.Min(count, MaximumTextBytes)), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return new(await reader.ReadToEndAsync(token).ConfigureAwait(false), truncated);
    }
}
