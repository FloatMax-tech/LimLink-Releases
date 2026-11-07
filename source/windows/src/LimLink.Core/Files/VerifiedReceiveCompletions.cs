namespace LimLink.Files;

/// <summary>The transport's published-file event is the success boundary, never a byte percentage.</summary>
public sealed class VerifiedReceiveCompletions
{
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);
    public bool TryAccept(ReceiveProgress progress)
    {
        if (progress.State != ReceiveState.Completed || string.IsNullOrWhiteSpace(progress.SavedPath)) return false;
        lock (_seen) return _seen.Add(progress.SessionId);
    }
}
