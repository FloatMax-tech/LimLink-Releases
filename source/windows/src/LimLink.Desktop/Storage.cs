using RecentEntry = LimLink.Files.RecentTransferRecord;
using System.Text.Json;

namespace LimLink.Desktop;

internal sealed class AppSettings
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    public string DeviceName { get; set; } = Environment.MachineName;
    public string ReceiveDirectory { get; set; } = DefaultReceiveDirectory;
    /// <summary>Empty follows the system language; otherwise an Android-style language tag.</summary>
    public string Language { get; set; } = "";
    public bool CloseToTray { get; set; } = true;
    public bool AutoSaveReceivedImages { get; set; } = true;
    public bool AutomaticUpdates { get; set; } = true;
    public DateOnly? LastUpdateAttempt { get; set; }
    public bool TrayNoticeShown { get; set; }

    public static string DefaultReceiveDirectory => Native.DownloadsPath();
    private static string LegacyDefaultReceiveDirectory => Path.Combine(Native.DownloadsPath(), "LimLink");

    public static AppSettings Load(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, "settings.json");
        AppSettings settings;
        try { settings = File.Exists(path) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { settings = new(); }
        if (!File.Exists(path))
        {
            // The first desktop build stored only the device name.
            try
            {
                var legacy = Path.Combine(dataDirectory, "device-name.txt");
                if (File.Exists(legacy) && File.ReadAllText(legacy).Trim() is { Length: > 0 } name) settings.DeviceName = name;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        if (ValidateName(settings.DeviceName) is not null) settings.DeviceName = Environment.MachineName;
        // Earlier builds defaulted to Downloads\LimLink; files now land directly in Downloads.
        if (string.IsNullOrWhiteSpace(settings.ReceiveDirectory) || SamePath(settings.ReceiveDirectory, LegacyDefaultReceiveDirectory)) settings.ReceiveDirectory = DefaultReceiveDirectory;
        return settings;
    }

    public void Save(string dataDirectory)
    {
        try
        {
            File.WriteAllText(Path.Combine(dataDirectory, "settings.json"), JsonSerializer.Serialize(this, Json));
            File.WriteAllText(Path.Combine(dataDirectory, "device-name.txt"), DeviceName);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private static bool SamePath(string a, string b)
    {
        try { return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return false; }
    }

    public static string? ValidateName(string? name)
        => string.IsNullOrWhiteSpace(name) || name.Trim().Length > 60 || name.Any(char.IsControl) ? Localization.Current.T("name_invalid") : null;
}


internal static class RecentStore
{
    public const int Limit = 20;

    public static List<RecentEntry> Load(string dataDirectory)
    {
        try
        {
            var path = Path.Combine(dataDirectory, "recent.json");
            return File.Exists(path) ? JsonSerializer.Deserialize<List<RecentEntry>>(File.ReadAllText(path))?.Take(Limit).ToList() ?? [] : [];
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return []; }
    }

    public static void Save(string dataDirectory, IEnumerable<RecentEntry> entries)
    {
        try { File.WriteAllText(Path.Combine(dataDirectory, "recent.json"), JsonSerializer.Serialize(entries.Take(Limit).ToList())); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
