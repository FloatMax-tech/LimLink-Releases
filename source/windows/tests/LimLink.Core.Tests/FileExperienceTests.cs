using System.Text;
using LimLink.Files;

namespace LimLink.Core.Tests;

public sealed class FileExperienceTests
{
    [Theory]
    [InlineData("photo.JPG", PreviewKind.Image)]
    [InlineData("report.pdf", PreviewKind.Pdf)]
    [InlineData("movie.mp4", PreviewKind.Video)]
    [InlineData("voice.m4a", PreviewKind.Audio)]
    [InlineData("notes.md", PreviewKind.Text)]
    [InlineData("script.exe", PreviewKind.Unsupported)]
    [InlineData("remote.html", PreviewKind.Unsupported)]
    [InlineData("drawing.svg", PreviewKind.Unsupported)]
    public void Preview_classifies_only_offline_native_formats(string name, PreviewKind expected)
        => Assert.Equal(expected, FilePreviewPolicy.Classify(name));

    [Theory]
    [InlineData("invoice.docx", true)]
    [InlineData("table.xlsx", true)]
    [InlineData("run.exe", false)]
    [InlineData("run.cmd", false)]
    [InlineData("shortcut.lnk", false)]
    [InlineData("remote.url", false)]
    public void External_open_is_restricted_to_documents_and_media(string name, bool allowed)
        => Assert.Equal(allowed, FilePreviewPolicy.CanOpenExternally(name));

    [Fact]
    public async Task Media_preview_rejects_a_remote_playlist_disguised_as_a_movie()
    {
        using var files = new TestFiles();
        var playlist = files.Write("remote.mp4", Encoding.UTF8.GetBytes("<asx><entry><ref href=\"https://example.invalid/movie\" /></entry></asx>"));
        Assert.False(await FilePreviewPolicy.HasNativeMediaHeaderAsync(playlist));
        var local = files.Write("local.mp4", new byte[] { 0, 0, 0, 20, 102, 116, 121, 112, 105, 115, 111, 109 });
        Assert.True(await FilePreviewPolicy.HasNativeMediaHeaderAsync(local));
    }

    [Fact]
    public async Task Text_preview_reads_only_a_bounded_prefix()
    {
        using var files = new TestFiles();
        var path = files.Write("large.txt", Encoding.UTF8.GetBytes(new string('a', 1_048_596)));
        var preview = await FilePreviewPolicy.ReadTextAsync(path);
        Assert.True(preview.Truncated);
        Assert.Equal(1_048_576, Encoding.UTF8.GetByteCount(preview.Text));
    }

    [Fact]
    public async Task Missing_file_is_reported_without_launching_an_external_program()
    {
        await Assert.ThrowsAsync<FileNotFoundException>(() => FilePreviewPolicy.ReadTextAsync(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".txt")));
    }

    [Fact]
    public async Task Picture_export_is_idempotent_after_reopening_the_store()
    {
        using var files = new TestFiles();
        var original = files.Write("received.png", [137, 80, 78, 71, 1, 2, 3]);
        var ledger = Path.Combine(files.Root, "exports.json");
        var album = Path.Combine(files.Root, "Pictures");
        var first = await new PictureExportStore(ledger, album).ExportAsync("receipt-1", original);
        var repeated = await new PictureExportStore(ledger, album).ExportAsync("receipt-1", original);
        Assert.Equal(first.Path, repeated.Path);
        Assert.True(first.Success);
        Assert.Single(Directory.GetFiles(album));
        Assert.Equal(await File.ReadAllBytesAsync(original), await File.ReadAllBytesAsync(first.Path!));
    }

    [Fact]
    public async Task Picture_export_failure_preserves_the_verified_download_and_can_retry()
    {
        using var files = new TestFiles();
        var original = files.Write("received.jpg", [255, 216, 255, 1]);
        var obstruction = files.Write("Pictures", [1]);
        var store = new PictureExportStore(Path.Combine(files.Root, "exports.json"), obstruction);
        Assert.False((await store.ExportAsync("receipt", original)).Success);
        Assert.True(File.Exists(original));
        File.Delete(obstruction);
        Assert.True((await store.ExportAsync("receipt", original)).Success);
    }

    [Fact]
    public async Task Export_never_overwrites_an_existing_unrelated_picture()
    {
        using var files = new TestFiles();
        var original = files.Write("received.png", [1, 2, 3]);
        var store = new PictureExportStore(Path.Combine(files.Root, "exports.json"), Path.Combine(files.Root, "Pictures"));
        var first = await store.ExportAsync("receipt", original);
        await File.WriteAllBytesAsync(first.Path!, [9, 9, 9]);
        var repeated = await store.ExportAsync("receipt", original);
        Assert.False(repeated.Success);
        Assert.Equal(new byte[] { 9, 9, 9 }, await File.ReadAllBytesAsync(first.Path!));
        Assert.True(File.Exists(original));
    }

    private sealed class TestFiles : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "limlink-files-" + Guid.NewGuid());
        public TestFiles() => Directory.CreateDirectory(Root);
        public string Write(string name, byte[] bytes) { var path = Path.Combine(Root, name); File.WriteAllBytes(path, bytes); return path; }
        public void Dispose() => Directory.Delete(Root, true);
    }
}

public sealed class VerifiedReceiveCompletionTests
{
    [Fact]
    public void Full_byte_progress_and_failure_do_not_show_success()
    {
        var completions = new VerifiedReceiveCompletions();
        Assert.False(completions.TryAccept(new("session", "Phone", "file.txt", 100, 100, ReceiveState.Receiving)));
        Assert.False(completions.TryAccept(new("session", "Phone", "file.txt", 100, 100, ReceiveState.Failed)));
        Assert.True(completions.TryAccept(new("session", "Phone", "file.txt", 100, 100, ReceiveState.Completed, "/verified/file.txt")));
        Assert.False(completions.TryAccept(new("session", "Phone", "file.txt", 100, 100, ReceiveState.Completed, "/verified/file.txt")));
    }

    [Fact]
    public void Completion_requires_a_published_path_and_accepts_empty_files()
    {
        var completions = new VerifiedReceiveCompletions();
        Assert.False(completions.TryAccept(new("session", "Phone", "empty.txt", 0, 0, ReceiveState.Completed)));
        Assert.True(completions.TryAccept(new("session", "Phone", "empty.txt", 0, 0, ReceiveState.Completed, "/verified/empty.txt")));
    }
}

public sealed class PictureRecoveryTests
{
    [Fact]
    public void Restart_with_auto_save_enabled_resumes_only_explicitly_pending_receipts()
    {
        var entries = new[]
        {
            new RecentTransferRecord("disabled.jpg", "Phone", true, "/downloads/disabled.jpg", DateTimeOffset.UnixEpoch, "disabled"),
            new RecentTransferRecord("pending.jpg", "Phone", true, "/downloads/pending.jpg", DateTimeOffset.UnixEpoch, "pending", PhotoExportPending: true),
            new RecentTransferRecord("legacy.jpg", "Phone", true, "/downloads/legacy.jpg", DateTimeOffset.UnixEpoch),
        };
        var persisted = System.Text.Json.JsonSerializer.Serialize(entries);
        var restored = System.Text.Json.JsonSerializer.Deserialize<RecentTransferRecord[]>(persisted)!;
        Assert.Equal("pending", Assert.Single(PictureExportRecovery.Pending(restored, autoSaveEnabled: true)).ReceiptId);
        Assert.Empty(PictureExportRecovery.Pending(restored, autoSaveEnabled: false));
    }
}
