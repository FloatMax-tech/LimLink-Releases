namespace LimLink;

/// <summary>Swift v1 interop registry. Missing/empty app means limlink; whitespace is invalid.</summary>
public sealed class PeerAppPolicy
{
    private static readonly HashSet<string> Registry = new(StringComparer.Ordinal) { "limlink", "casecheck" };
    private readonly HashSet<string> _allowed;
    public PeerAppPolicy(string hostAppId, IEnumerable<string>? allowedPeerApps = null)
    {
        HostAppId = NormalizeRequired(hostAppId);
        if (!Registry.Contains(HostAppId)) throw new ArgumentException("Host app is not in the v1 interop registry.", nameof(hostAppId));
        _allowed = allowedPeerApps is null ? new(Registry, StringComparer.Ordinal) : new(allowedPeerApps.Select(NormalizeRequired).Where(Registry.Contains), StringComparer.Ordinal);
        if (!_allowed.Contains(HostAppId)) throw new ArgumentException("The allowlist must include the host app.", nameof(allowedPeerApps));
    }
    public string HostAppId { get; }
    public static string NormalizePeer(string? app)
    {
        if (string.IsNullOrEmpty(app)) return "limlink";
        var folded = string.Concat(app.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c));
        return folded.Length is > 0 and <= 16 && folded.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-') ? folded : "";
    }
    public bool Allows(string? peerApp) => _allowed.Contains(NormalizePeer(peerApp));
    private static string NormalizeRequired(string app)
    {
        var normalized = NormalizePeer(app);
        if (string.IsNullOrEmpty(app) || normalized.Length == 0) throw new ArgumentException("App IDs use 1–16 ASCII letters, digits or hyphens.", nameof(app));
        return normalized;
    }
}
