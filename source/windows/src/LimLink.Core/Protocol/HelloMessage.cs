namespace LimLink;

public sealed class HelloMessage
{
    public string[]? Proto { get; set; }
    public string? Alias { get; set; }
    public string? DevType { get; set; }
    public string? Model { get; set; }
    public int? Port { get; set; }
    public string? App { get; set; }
    public string? BindingId { get; set; }
    public string[]? Caps { get; set; }
    public HelloLimits? Limits { get; set; }
    public bool? Trusted { get; set; }
    public bool? Busy { get; set; }
}

public sealed class HelloLimits
{
    public long? MaxFileBytes { get; set; } = 5_000_000_000L;
    public int MaxEntries { get; set; } = 1;
    public int MaxManifestBytes { get; set; } = 65_536;
    public int MaxConcurrentPuts { get; set; } = 4;
    public int AcceptPromptTimeoutSec { get; set; } = 120;
    public int MaxThumbBytes { get; set; } = 32_768;

    public static HelloLimits Default { get; } = new();
}

public sealed class HelloResult
{
    public required HelloMessage Peer { get; init; }

    /// <summary>
    /// False when the peer's <c>app</c> is outside the allowed set (protocol 1.2).
    /// Hello itself still returned 200; the initiator must not continue.
    /// </summary>
    public required bool AppCompatible { get; init; }
}
