using System.Text;
using System.Text.Json;
using LimLink;

namespace LimLink.Core.Tests;

public sealed class TransferTests
{
    [Fact]
    public void Hello_advertises_single_file_limit() => Assert.Equal(5_000_000_000L, HelloLimits.Default.MaxFileBytes);

    [Fact]
    public async Task Snapshot_is_immutable_and_hashes_without_reading_entire_file()
    {
        using var temp = new TempDirectory();
        var source = Path.Combine(temp.Path, "source.txt");
        await File.WriteAllTextAsync(source, "abc");
        await using var snapshot = await FileSnapshot.CreateAsync(source, temp.Path);
        await File.WriteAllTextAsync(source, "changed");
        Assert.Equal(3, snapshot.Size);
        Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", snapshot.Sha256);
        Assert.Equal("abc", Encoding.UTF8.GetString(await snapshot.ReadChunkAsync(0)));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => snapshot.ReadChunkAsync(-1));
    }

    [Fact]
    public async Task Snapshot_rejects_5GB_plus_one_before_copying()
    {
        using var temp = new TempDirectory();
        var source = Path.Combine(temp.Path, "large.bin");
        using (var file = File.Create(source)) file.SetLength(5_000_000_001L);
        await Assert.ThrowsAsync<TransferException>(() => FileSnapshot.CreateAsync(source, temp.Path));
        Assert.Single(Directory.GetFiles(temp.Path));
    }

    [Fact]
    public async Task Pending_consent_exposes_no_token_and_rejects_PUT()
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello();
        var created = await fixture.Create();
        Assert.Equal(202, created.Status);
        var sid = created.Json.GetProperty("sessionId").GetString()!;
        var poll = await fixture.Call("GET", $"/sessions/{sid}");
        Assert.Equal(202, poll.Status);
        Assert.False(poll.Json.TryGetProperty("files", out _));
        var put = await fixture.Put(sid, "bad", 0, "abc"u8.ToArray());
        Assert.Equal(409, put.Status);
        Assert.Empty(Directory.GetFiles(fixture.Output));
    }

    [Fact]
    public async Task Consent_uses_same_connection_hello_name_and_cannot_change_mid_session()
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello("Alice’s iPhone");
        var created = await fixture.Create();
        var offer = await fixture.Offer.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal("Alice’s iPhone", offer.SenderName);
        Assert.Equal(fixture.Peer.Fingerprint, offer.SenderFingerprint);
        Assert.Equal(3, offer.Size);
        Assert.Equal(409, (await fixture.Hello("Mallory")).Status);
        fixture.Decision.SetResult(false);
        var sid = created.Json.GetProperty("sessionId").GetString()!;
        Assert.Equal(403, (await fixture.AwaitDecision(sid)).Status);
    }

    [Fact]
    public async Task Same_certificate_on_a_new_connection_cannot_take_session()
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello();
        var created = await fixture.Create();
        var sid = created.Json.GetProperty("sessionId").GetString()!;
        var thief = fixture.Peer with { ConnectionId = "new-connection" };
        var reply = await fixture.Receiver.HandleAsync(thief, "GET", $"/limlink/v1/sessions/{sid}", fixture.Headers, ReadOnlyMemory<byte>.Empty, default);
        Assert.Equal(404, reply.Status);
    }

    [Theory]
    [InlineData("5000000001", "ok.txt", 413)]
    [InlineData("-1", "ok.txt", 400)]
    [InlineData("3.0", "ok.txt", 400)]
    [InlineData("\"3\"", "ok.txt", 400)]
    [InlineData("true", "ok.txt", 400)]
    [InlineData("3", "../evil.txt", 400)]
    [InlineData("3", "a/b.txt", 400)]
    public async Task Manifest_rejects_unsafe_names_and_non_integer_sizes(string size, string name, int status)
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello();
        var json = $$"""{"clientSessionKey":"key","transport":"lan","totalEntries":1,"totalBytes":{{size}},"entries":[{"id":"file","kind":"file","relativePath":"{{name}}","size":{{size}}}]}""";
        var reply = await fixture.Call("POST", "/sessions", Encoding.UTF8.GetBytes(json));
        Assert.Equal(status, reply.Status);
        Assert.Empty(Directory.GetFiles(fixture.Output));
    }

    [Fact]
    public async Task FiveGB_metadata_is_accepted_without_allocating_file_size()
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello();
        Assert.Equal(202, (await fixture.Create(5_000_000_000L)).Status);
        Assert.All(Directory.GetFiles(fixture.Output, "*", SearchOption.AllDirectories).Where(p => p.EndsWith(".part")), p => Assert.Equal(0, new FileInfo(p).Length));
    }

    [Fact]
    public async Task Sender_pause_holds_the_session_until_resume()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept();
        var pause = await fixture.Call("POST", $"/sessions/{sid}/pause", ReceiverFixture.Json(new { sessionId = sid, reason = "app_background" }));
        Assert.Equal(200, pause.Status);
        Assert.Equal("paused", pause.Json.GetProperty("state").GetString());
        Assert.Equal(0, pause.Json.GetProperty("files").GetProperty("file").GetProperty("committedBytes").GetInt64());
        Assert.Equal(409, (await fixture.Put(sid, token, 0, "abc"u8.ToArray())).Status);
        var poll = await fixture.Call("GET", $"/sessions/{sid}");
        Assert.Equal(200, poll.Status);
        Assert.Equal("paused", poll.Json.GetProperty("state").GetString());
        var resume = await fixture.Call("POST", $"/sessions/{sid}/resume", ReceiverFixture.Json(new { sessionId = sid }));
        Assert.Equal(200, resume.Status);
        Assert.Equal("accepted", resume.Json.GetProperty("state").GetString());
        Assert.Equal(200, (await fixture.Put(sid, token, 0, "abc"u8.ToArray())).Status);
        Assert.Equal(400, (await fixture.Call("POST", $"/sessions/{sid}/pause", ReceiverFixture.Json(new { sessionId = sid }))).Status);
    }

    [Fact]
    public async Task Receive_progress_reports_acceptance_chunks_completion_and_cancellation()
    {
        using var fixture = new ReceiverFixture();
        var events = new List<ReceiveProgress>();
        fixture.Receiver.ReceiveProgressChanged += p => { lock (events) events.Add(p); };
        var (sid, token) = await fixture.Accept();
        Assert.Equal(200, (await fixture.Put(sid, token, 0, "abc"u8.ToArray())).Status);
        Assert.Equal(200, (await fixture.Call("POST", $"/sessions/{sid}/files/file/complete", ReceiverFixture.Json(new { sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }))).Status);
        lock (events)
        {
            Assert.Equal([ReceiveState.Receiving, ReceiveState.Receiving, ReceiveState.Completed], events.Select(e => e.State));
            Assert.All(events, e => { Assert.Equal(sid, e.SessionId); Assert.Equal("Alice", e.SenderName); Assert.Equal("hello.txt", e.FileName); Assert.Equal(3, e.TotalBytes); });
            Assert.Equal([0L, 3L, 3L], events.Select(e => e.ReceivedBytes));
            Assert.Equal(Path.Combine(fixture.Output, "hello.txt"), events[^1].SavedPath);
        }

        using var cancelled = new ReceiverFixture();
        var states = new List<ReceiveState>();
        cancelled.Receiver.ReceiveProgressChanged += p => { lock (states) states.Add(p.State); };
        var (other, _) = await cancelled.Accept();
        Assert.Equal(200, (await cancelled.Call("POST", $"/sessions/{other}/cancel", ReceiverFixture.Json(new { sessionId = other, reason = "user" }))).Status);
        lock (states) Assert.Equal([ReceiveState.Receiving, ReceiveState.Failed], states);
    }

    [Fact]
    public async Task Complete_verifies_and_publishes_without_overwriting_then_reports_exact_bytes()
    {
        using var fixture = new ReceiverFixture();
        await File.WriteAllTextAsync(Path.Combine(fixture.Output, "hello.txt"), "original");
        var (sid, token) = await fixture.Accept();
        Assert.Equal(403, (await fixture.Put(sid, "wrong", 0, "abc"u8.ToArray())).Status);
        Assert.Equal(409, (await fixture.Put(sid, token, 1, "abc"u8.ToArray())).Status);
        var ack = await fixture.Put(sid, token, 0, "abc"u8.ToArray());
        Assert.Equal(3, ack.Json.GetProperty("committedBytes").GetInt64());
        var complete = await fixture.Call("POST", $"/sessions/{sid}/files/file/complete", ReceiverFixture.Json(new { sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }));
        Assert.Equal(200, complete.Status);
        Assert.True(complete.Json.GetProperty("verified").GetBoolean());
        var saved = complete.Json.GetProperty("finalName").GetString()!;
        Assert.NotEqual("hello.txt", saved);
        Assert.Equal("abc", await File.ReadAllTextAsync(Path.Combine(fixture.Output, saved)));
        Assert.Equal("original", await File.ReadAllTextAsync(Path.Combine(fixture.Output, "hello.txt")));
        var finish = await fixture.Call("POST", $"/sessions/{sid}/finish", ReceiverFixture.Json(new { sessionId = sid }));
        Assert.Equal("finished", finish.Json.GetProperty("state").GetString());
        Assert.Equal(3, finish.Json.GetProperty("files")[0].GetProperty("bytesReceived").GetInt64());
    }

    [Fact]
    public async Task Wrong_hash_resets_once_then_removes_staging_without_publication()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept();
        for (var attempt = 0; attempt < 2; attempt++)
        {
            Assert.Equal(200, (await fixture.Put(sid, token, 0, "abc"u8.ToArray())).Status);
            Assert.Equal(422, (await fixture.Call("POST", $"/sessions/{sid}/files/file/complete", ReceiverFixture.Json(new { sha256 = new string('0', 64) }))).Status);
        }
        Assert.Empty(Directory.GetFiles(fixture.Output));
        Assert.Empty(Directory.GetFiles(fixture.Output, "*.part", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Cancel_and_disconnect_delete_staging()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept();
        await fixture.Put(sid, token, 0, "a"u8.ToArray());
        Assert.Equal(200, (await fixture.Call("POST", $"/sessions/{sid}/cancel", ReceiverFixture.Json(new { sessionId = sid, reason = "user" }))).Status);
        await fixture.Receiver.DisconnectAsync(fixture.Peer.ConnectionId);
        Assert.Empty(Directory.GetFiles(fixture.Output, "*.part", SearchOption.AllDirectories));
        Assert.Equal(404, (await fixture.Call("GET", $"/sessions/{sid}")).Status);
    }

    [Fact]
    public async Task Chunk_limit_and_file_remaining_limit_are_enforced_before_write()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept();
        Assert.Equal(413, (await fixture.Put(sid, token, 0, new byte[1_048_577])).Status);
        Assert.Equal(400, (await fixture.Put(sid, token, 0, new byte[4])).Status);
        Assert.Equal(400, (await fixture.Put(sid, token, 0, [])).Status);
    }

    [Fact]
    public async Task Idle_transfer_expires_and_removes_private_partial_file()
    {
        var clock = new MutableClock();
        using var fixture = new ReceiverFixture(clock);
        var (sid, token) = await fixture.Accept();
        await fixture.Put(sid, token, 0, "a"u8.ToArray());
        clock.Now += TimeSpan.FromSeconds(121);
        Assert.Equal(410, (await fixture.Call("GET", $"/sessions/{sid}")).Status);
        Assert.Empty(Directory.GetFiles(fixture.Output, "*.part", SearchOption.AllDirectories));
        Assert.Empty(Directory.GetFiles(fixture.Output));
    }

    [Fact]
    public async Task Pending_decision_has_absolute_120_second_deadline()
    {
        var clock = new MutableClock();
        using var fixture = new ReceiverFixture(clock);
        await fixture.Hello();
        var created = await fixture.Create();
        var sid = created.Json.GetProperty("sessionId").GetString()!;
        clock.Now += TimeSpan.FromSeconds(119);
        Assert.Equal(202, (await fixture.Call("GET", $"/sessions/{sid}")).Status);
        clock.Now += TimeSpan.FromSeconds(2);
        Assert.Equal(408, (await fixture.Call("GET", $"/sessions/{sid}")).Status);
        fixture.Decision.TrySetResult(true);
        Assert.Empty(Directory.GetFiles(fixture.Output, "*.part", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Disconnect_of_accepted_transfer_removes_partial_file()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept();
        await fixture.Put(sid, token, 0, "a"u8.ToArray());
        await fixture.Receiver.DisconnectAsync(fixture.Peer.ConnectionId);
        Assert.Empty(Directory.GetFiles(fixture.Output, "*.part", SearchOption.AllDirectories));
        Assert.Equal(404, (await fixture.Call("GET", $"/sessions/{sid}")).Status);
    }

    [Fact]
    public async Task Different_certificate_cannot_use_same_connection_identifier()
    {
        using var fixture = new ReceiverFixture();
        var (sid, _) = await fixture.Accept();
        using var cert = DeviceCertificate.Create();
        var peer = fixture.Peer with { Fingerprint = Fingerprint.Compute(cert) };
        var reply = await fixture.Receiver.HandleAsync(peer, "GET", $"/limlink/v1/sessions/{sid}", fixture.Headers, ReadOnlyMemory<byte>.Empty);
        Assert.Equal(404, reply.Status);
    }

    [Fact]
    public async Task Device_rename_cannot_interrupt_pending_or_accepted_receive()
    {
        using var fixture = new ReceiverFixture();
        Assert.True(await fixture.Receiver.TrySuspendOffersAsync());
        await fixture.Hello();
        Assert.Equal(409, (await fixture.Create()).Status);
        fixture.Receiver.ResumeOffers();
        Assert.Equal(202, (await fixture.Create()).Status);
        Assert.False(await fixture.Receiver.TrySuspendOffersAsync());
        await fixture.Receiver.DisconnectAsync(fixture.Peer.ConnectionId);
        Assert.True(await fixture.Receiver.TrySuspendOffersAsync());
    }

    [Fact]
    public async Task Duplicate_manifest_keys_are_rejected()
    {
        using var fixture = new ReceiverFixture();
        await fixture.Hello();
        var json = """{"clientSessionKey":"key","transport":"lan","totalEntries":1,"totalBytes":3,"entries":[{"id":"file","kind":"file","relativePath":"a","size":3,"size":4}]}""";
        Assert.Equal(400, (await fixture.Call("POST", "/sessions", Encoding.UTF8.GetBytes(json))).Status);
    }

    [Fact]
    public async Task Empty_file_is_verified_and_saved()
    {
        using var fixture = new ReceiverFixture();
        var (sid, token) = await fixture.Accept(0);
        Assert.Equal(200, (await fixture.Put(sid, token, 0, [])).Status);
        var complete = await fixture.Call("POST", $"/sessions/{sid}/files/file/complete", ReceiverFixture.Json(new { sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }));
        Assert.Equal(200, complete.Status);
        Assert.Equal(0, new FileInfo(Path.Combine(fixture.Output, complete.Json.GetProperty("finalName").GetString()!)).Length);
    }
}

internal sealed class TempDirectory : IDisposable
{
    public string Path { get; } = Directory.CreateTempSubdirectory("limlink-transfer-").FullName;
    public void Dispose() => Directory.Delete(Path, true);
}

internal sealed class ReceiverFixture : IDisposable
{
    private readonly TempDirectory _temp = new();
    public string Output { get; }
    public TransferReceiver Receiver { get; }
    public PeerConnection Peer { get; } = new("connection", Convert.ToBase64String(new byte[32]).TrimEnd('=').Replace('+', '-').Replace('/', '_'));
    public Dictionary<string, string> Headers { get; } = new(StringComparer.OrdinalIgnoreCase) { ["X-LimLink-App"] = "limlink" };
    public TaskCompletionSource<bool> Decision { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource<IncomingOffer> Offer { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public ReceiverFixture(TimeProvider? clock = null)
    {
        Output = Path.Combine(_temp.Path, "received");
        Directory.CreateDirectory(Output);
        Receiver = new TransferReceiver(Output, "Windows", new PeerAppPolicy("limlink"), async (offer, ct) =>
        { Offer.TrySetResult(offer); return await Decision.Task.WaitAsync(ct); }, clock);
    }
    public static byte[] Json(object value) => JsonSerializer.SerializeToUtf8Bytes(value, ProtocolJson.Options);
    public Task<TransferReply> Call(string method, string path, byte[]? body = null) => Receiver.HandleAsync(Peer, method, "/limlink/v1" + path, Headers, body ?? [], default);
    public Task<TransferReply> Hello(string alias = "Alice") => Call("POST", "/hello", Json(new { proto = new[] { "1.0" }, alias, app = "limlink" }));
    public Task<TransferReply> Create(long size = 3) => Call("POST", "/sessions", Json(new { clientSessionKey = "key", transport = "lan", totalEntries = 1, totalBytes = size, entries = new[] { new { id = "file", kind = "file", relativePath = "hello.txt", size } } }));
    public async Task<TransferReply> AwaitDecision(string sid)
    {
        for (var i = 0; i < 100; i++) { var reply = await Call("GET", $"/sessions/{sid}"); if (reply.Status != 202) return reply; await Task.Delay(10); }
        throw new TimeoutException();
    }
    public async Task<(string Sid, string Token)> Accept(long size = 3)
    {
        await Hello();
        var created = await Create(size);
        var sid = created.Json.GetProperty("sessionId").GetString()!;
        Decision.SetResult(true);
        var poll = await AwaitDecision(sid);
        return (sid, poll.Json.GetProperty("files").GetProperty("file").GetProperty("token").GetString()!);
    }
    public Task<TransferReply> Put(string sid, string token, long offset, byte[] bytes)
    {
        var headers = new Dictionary<string, string>(Headers, StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/octet-stream", ["X-LimLink-Token"] = token, ["X-LimLink-Offset"] = offset.ToString(System.Globalization.CultureInfo.InvariantCulture) };
        return Receiver.HandleAsync(Peer, "PUT", $"/limlink/v1/sessions/{sid}/files/file", headers, bytes, default);
    }
    public void Dispose() { Receiver.Dispose(); _temp.Dispose(); }
}

internal sealed class MutableClock : TimeProvider
{
    public DateTimeOffset Now = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
}
