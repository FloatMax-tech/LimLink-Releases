using System.Text;
using System.Text.Json;

namespace LimLink.Files;

public sealed record PictureExportResult(bool Success, string? Path, string? Error);
public sealed record PictureExportRecord(string ReceiptId, string Source, string Destination, string State);

/// <summary>Copies verified downloads to Pictures without moving them. A durable receipt prevents repeat exports.</summary>
public sealed class PictureExportStore(string ledgerPath, string picturesDirectory)
{
    private readonly SemaphoreSlim _gate = new(1);
    public async Task<PictureExportResult> ExportAsync(string receiptId, string source, CancellationToken token = default)
    {
        await _gate.WaitAsync(token).ConfigureAwait(false);
        string? temporary = null;
        try
        {
            if (FilePreviewPolicy.Classify(source) != PreviewKind.Image) return new(false, null, "Unsupported image format.");
            if (!File.Exists(source)) return new(false, null, "The verified download is unavailable.");
            var records = await LoadAsync(token).ConfigureAwait(false);
            var id = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(receiptId))).ToLowerInvariant();
            var basename = Path.GetFileNameWithoutExtension(source);
            if (basename.Length > 80) basename = basename[..80];
            var destination = records.TryGetValue(receiptId, out var existing) ? existing.Destination : Path.Combine(picturesDirectory, basename + "-limlink-" + id[..16] + Path.GetExtension(source).ToLowerInvariant());
            // Ledger destinations are constrained to the configured album before any file is touched.
            if (!string.Equals(Path.GetDirectoryName(Path.GetFullPath(destination)), Path.GetFullPath(picturesDirectory), StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid album destination.");
            Directory.CreateDirectory(picturesDirectory);
            records[receiptId] = new(receiptId, source, destination, "pending");
            await SaveAsync(records, token).ConfigureAwait(false);
            if (File.Exists(destination))
            {
                if (!await SameContentAsync(source, destination, token).ConfigureAwait(false)) throw new IOException("An existing gallery file is different; it was preserved.");
            }
            else if (!string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
            {
                temporary = Path.Combine(picturesDirectory, ".limlink-" + id + ".partial");
                // A process crash can leave only our deterministic temporary copy, which is safe to replace.
                await using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65_536, FileOptions.Asynchronous | FileOptions.SequentialScan))
                await using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 65_536, FileOptions.Asynchronous))
                {
                    await input.CopyToAsync(output, token).ConfigureAwait(false);
                    await output.FlushAsync(token).ConfigureAwait(false);
                    output.Flush(flushToDisk: true);
                }
                File.Move(temporary, destination, overwrite: false); temporary = null;
            }
            records[receiptId] = new(receiptId, source, destination, "completed");
            await SaveAsync(records, token).ConfigureAwait(false);
            return new(true, destination, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
        { return new(false, null, ex.Message); }
        finally
        {
            if (temporary is not null) { try { File.Delete(temporary); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } }
            _gate.Release();
        }
    }
    private async Task<Dictionary<string, PictureExportRecord>> LoadAsync(CancellationToken token)
    {
        if (!File.Exists(ledgerPath)) return new(StringComparer.Ordinal);
        await using var stream = File.OpenRead(ledgerPath);
        if (stream.Length > 8 * 1024 * 1024) throw new IOException("The photo export history is too large.");
        return await JsonSerializer.DeserializeAsync<Dictionary<string, PictureExportRecord>>(stream, cancellationToken: token).ConfigureAwait(false) ?? new(StringComparer.Ordinal);
    }
    private async Task SaveAsync(Dictionary<string, PictureExportRecord> records, CancellationToken token)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(ledgerPath))!);
        var temporary = ledgerPath + ".tmp";
        await using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 16_384, FileOptions.Asynchronous))
        {
            await JsonSerializer.SerializeAsync(stream, records, cancellationToken: token).ConfigureAwait(false);
            await stream.FlushAsync(token).ConfigureAwait(false); stream.Flush(true);
        }
        File.Move(temporary, ledgerPath, overwrite: true);
    }
    private static async Task<bool> SameContentAsync(string source, string destination, CancellationToken token)
    {
        if (new FileInfo(source).Length != new FileInfo(destination).Length) return false;
        await using var left = File.OpenRead(source); await using var right = File.OpenRead(destination);
        var a = await SHA256.HashDataAsync(left, token).ConfigureAwait(false); var b = await SHA256.HashDataAsync(right, token).ConfigureAwait(false);
        return CryptographicOperations.FixedTimeEquals(a, b);
    }
}
