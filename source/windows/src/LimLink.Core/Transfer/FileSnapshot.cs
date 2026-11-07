namespace LimLink;

public static class TransferLimits
{
    public const long MaximumFileBytes = 5_000_000_000L;
    public const int MaximumChunkBytes = 1_048_576;
    public const int MaximumJsonBytes = 65_536;
}

public sealed class TransferException(string code, string message) : IOException(message)
{
    public string Code { get; } = code;
}

/// <summary>Private disk snapshot. Source mutations cannot change the offered bytes or digest.</summary>
public sealed class FileSnapshot : IAsyncDisposable
{
    private readonly FileStream _stream;
    public string Name { get; }
    public long Size { get; }
    public string Sha256 { get; }
    private FileSnapshot(FileStream stream, string name, long size, string sha256) => (_stream, Name, Size, Sha256) = (stream, name, size, sha256);

    public static async Task<FileSnapshot> CreateAsync(string sourcePath, string scratchDirectory, CancellationToken cancellationToken = default)
    {
        await using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (source.Length > TransferLimits.MaximumFileBytes) throw new TransferException("E_FILE_TOO_LARGE", "Single files must be at most 5 GB.");
        var name = TransferNames.LandingName(Path.GetFileName(sourcePath));
        Directory.CreateDirectory(scratchDirectory);
        var path = Path.Combine(scratchDirectory, "send-" + Guid.NewGuid().ToString("N") + ".part");
        var output = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.Asynchronous | FileOptions.DeleteOnClose);
        try
        {
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[TransferLimits.MaximumChunkBytes];
            long size = 0;
            int count;
            while ((count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
            {
                size = checked(size + count);
                if (size > TransferLimits.MaximumFileBytes) throw new TransferException("E_FILE_TOO_LARGE", "Single files must be at most 5 GB.");
                hash.AppendData(buffer, 0, count);
                await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
            }
            output.Flush(flushToDisk: true);
            return new FileSnapshot(output, name, size, Convert.ToHexStringLower(hash.GetHashAndReset()));
        }
        catch { await output.DisposeAsync().ConfigureAwait(false); throw; }
    }

    public Task<byte[]> ReadChunkAsync(long offset, CancellationToken cancellationToken = default)
    {
        if (offset < 0 || offset > Size) throw new ArgumentOutOfRangeException(nameof(offset));
        return ReadAsync(offset, cancellationToken);
    }
    private async Task<byte[]> ReadAsync(long offset, CancellationToken cancellationToken)
    {
        var buffer = new byte[(int)Math.Min(TransferLimits.MaximumChunkBytes, Size - offset)];
        _stream.Position = offset;
        await _stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
        return buffer;
    }
    public ValueTask DisposeAsync() => _stream.DisposeAsync();
}

internal static class TransferNames
{
    public static string LandingName(string name)
    {
        if (name.Length is 0 or > 240 || name is "." or ".." || name.Any(c => c is '/' or '\\' || c < 32 || c == 127))
            throw new TransferException("E_PATH_INVALID", "A safe single filename is required.");
        name = string.Concat(name.Select(c => "<>:\"|?*".Contains(c) ? '_' : c)).TrimEnd('.', ' ');
        if (name.Length == 0) throw new TransferException("E_PATH_INVALID", "A safe filename is required.");
        var stem = Path.GetFileNameWithoutExtension(name);
        var upper = stem.ToUpperInvariant();
        if (upper is "CON" or "PRN" or "AUX" or "NUL" || (upper.Length == 4 && (upper.StartsWith("COM", StringComparison.Ordinal) || upper.StartsWith("LPT", StringComparison.Ordinal)) && upper[3] is >= '1' and <= '9'))
            name = stem + "_" + Path.GetExtension(name);
        return name;
    }
}
