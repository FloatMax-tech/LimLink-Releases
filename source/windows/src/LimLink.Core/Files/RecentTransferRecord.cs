namespace LimLink.Files;

/// <summary>Local transfer history. Pending is explicit so enabling auto-save never imports historical receipts.</summary>
public sealed record RecentTransferRecord(string FileName, string PeerName, bool Received, string? Path, DateTimeOffset Time,
    string? ReceiptId = null, string? PhotoPath = null, string? PhotoError = null, bool PhotoExportPending = false);

public static class PictureExportRecovery
{
    public static IEnumerable<RecentTransferRecord> Pending(IEnumerable<RecentTransferRecord> entries, bool autoSaveEnabled) =>
        autoSaveEnabled ? entries.Where(e => e.Received && e.PhotoExportPending && e.ReceiptId is not null && e.PhotoPath is null &&
            e.PhotoError is null && e.Path is { } path && FilePreviewPolicy.Classify(path) == PreviewKind.Image) : Enumerable.Empty<RecentTransferRecord>();
}
