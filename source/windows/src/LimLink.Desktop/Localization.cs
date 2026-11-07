using System.ComponentModel;
using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Windows.Data;
using System.Windows.Markup;

namespace LimLink.Desktop;

public sealed record LanguageOption(string Tag, string Label);

/// <summary>
/// JSON-backed UI strings. An empty tag follows the system language; unsupported locales fall
/// back to English. Missing keys fall back through English and then Simplified Chinese.
/// </summary>
public sealed class Localization : INotifyPropertyChanged
{
    private static readonly string[] Supported = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it"];
    private readonly Dictionary<string, Dictionary<string, string>> _cache = [];
    private Dictionary<string, string> _strings = new();

    public static Localization Current { get; } = new();

    private Localization() => SetLanguage("");

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? LanguageChanged;

    /// <summary>Stored preference: empty means follow the system language.</summary>
    public string RequestedTag { get; private set; } = "";
    /// <summary>Language actually used after resolving an empty or unsupported preference.</summary>
    public string LanguageTag { get; private set; } = "zh-Hans";

    public string this[string key]
    {
        get
        {
            if (_strings.TryGetValue(key, out var text)) return text;
            if (Load("en").TryGetValue(key, out text)) return text;
            if (Load("zh-Hans").TryGetValue(key, out text)) return text;
            return key;
        }
    }

    public string T(string key, params object?[] args)
    {
        var format = this[key];
        return args.Length == 0 ? format : string.Format(CultureInfo.CurrentCulture, format, args);
    }

    public IReadOnlyList<LanguageOption> Options =>
    [
        new("", T("language_system")),
        new("zh-Hans", "简体中文"),
        new("zh-Hant", "繁體中文"),
        new("en", "English"),
        new("ja", "日本語"),
        new("ko", "한국어"),
        new("fr", "Français"),
        new("de", "Deutsch"),
        new("es", "Español"),
        new("it", "Italiano"),
    ];

    public void SetLanguage(string tag)
    {
        RequestedTag = tag ?? "";
        LanguageTag = Resolve(RequestedTag);
        _strings = Merge(LanguageTag);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Options)));
        LanguageChanged?.Invoke();
    }

    private static string Resolve(string tag)
    {
        if (Supported.Contains(tag)) return tag;
        if (!string.IsNullOrWhiteSpace(tag))
        {
            var exact = Supported.FirstOrDefault(s => string.Equals(s, tag, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;
            // Android stores zh-CN / zh-TW; accept those tags if a setting is copied between clients.
            if (tag.Equals("zh-CN", StringComparison.OrdinalIgnoreCase) || tag.Equals("zh-SG", StringComparison.OrdinalIgnoreCase)) return "zh-Hans";
            if (tag.Equals("zh-TW", StringComparison.OrdinalIgnoreCase) || tag.Equals("zh-HK", StringComparison.OrdinalIgnoreCase) || tag.Equals("zh-MO", StringComparison.OrdinalIgnoreCase)) return "zh-Hant";
        }
        var culture = CultureInfo.CurrentUICulture;
        if (culture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase))
        {
            return culture.Name.Contains("Hant", StringComparison.OrdinalIgnoreCase) ||
                   culture.Name.EndsWith("-TW", StringComparison.OrdinalIgnoreCase) ||
                   culture.Name.EndsWith("-HK", StringComparison.OrdinalIgnoreCase) ||
                   culture.Name.EndsWith("-MO", StringComparison.OrdinalIgnoreCase)
                ? "zh-Hant"
                : "zh-Hans";
        }
        var language = culture.TwoLetterISOLanguageName;
        return Supported.Contains(language) ? language : "en";
    }

    private Dictionary<string, string> Merge(string tag)
    {
        var merged = new Dictionary<string, string>(Load("en"), StringComparer.Ordinal);
        foreach (var pair in Load(tag)) merged[pair.Key] = pair.Value;
        // The source language wins for any key the English table has not caught up with.
        foreach (var pair in Load("zh-Hans")) merged.TryAdd(pair.Key, pair.Value);
        return merged;
    }

    private Dictionary<string, string> Load(string tag)
    {
        if (_cache.TryGetValue(tag, out var cached)) return cached;
        var assembly = Assembly.GetExecutingAssembly();
        var name = $"LimLink.Desktop.Strings.{tag}.json";
        using var stream = assembly.GetManifestResourceStream(name);
        var table = stream is null
            ? new Dictionary<string, string>()
            : JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? new Dictionary<string, string>();
        _cache[tag] = table;
        return table;
    }
}

/// <summary>XAML helper: <c>Text="{loc:Loc nearby_transfer}"</c> updates when the language changes.</summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class LocExtension : MarkupExtension
{
    public LocExtension() { }
    public LocExtension(string key) => Key = key;

    public string Key { get; set; } = "";

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        var binding = new Binding($"[{Key}]")
        {
            Source = Localization.Current,
            Mode = BindingMode.OneWay,
        };
        return binding.ProvideValue(serviceProvider);
    }
}
