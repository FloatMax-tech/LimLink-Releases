namespace LimLink.Desktop;

/// <summary>Small rolling log at %LOCALAPPDATA%\LimLink\activity.log for diagnosing real-device transfers.</summary>
internal static class ActivityLog
{
    private static readonly object Gate = new();
    private static string? _path;

    public static void Init(string dataDirectory)
    {
        _path = Path.Combine(dataDirectory, "activity.log");
        try
        {
            var info = new FileInfo(_path);
            if (info.Exists && info.Length > 512 * 1024) File.Move(_path, _path + ".old", overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
        Write("app", $"start {Environment.OSVersion.Version} pid={Environment.ProcessId}");
    }

    public static void Write(string area, string message)
    {
        if (_path is null) return;
        lock (Gate)
        {
            try { File.AppendAllText(_path, $"{DateTimeOffset.Now:HH:mm:ss.fff} [{area}] {message}{Environment.NewLine}"); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    public static string Short(string? value, int max = 60)
        => value is null ? "" : value.Length <= max ? value : value[..max] + "…";
}
