using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace LimLink;

public sealed record PeerConnection(string ConnectionId, string Fingerprint);
public sealed record IncomingOffer(string SessionId, string SenderName, string SenderFingerprint, string FileName, long Size);
public enum ReceiveState { Receiving, Completed, Failed }
public sealed record ReceiveProgress(string SessionId, string SenderName, string FileName, long ReceivedBytes, long TotalBytes, ReceiveState State, string? SavedPath = null);
public sealed record TransferReply(int Status, byte[] Body)
{
    public JsonElement Json => JsonSerializer.Deserialize<JsonElement>(Body);
    public static TransferReply From(int status, object body) => new(status, JsonSerializer.SerializeToUtf8Bytes(body, ProtocolJson.Options));
    public static TransferReply Error(int status, string code, string message = "Request rejected.", object? detail = null) => From(status, ProtocolJson.Error(code, message, false, detail));
}

/// <summary>One-file LAN receiver. Ownership includes certificate AND connection, and consent is per file.</summary>
public sealed class TransferReceiver : IDisposable
{
    private readonly string _destination;
    private readonly string _staging;
    private readonly string _alias;
    private readonly PeerAppPolicy _policy;
    private readonly Func<IncomingOffer, CancellationToken, Task<bool>> _confirm;
    private readonly Dictionary<string, (PeerConnection Peer, string Alias, string App, string? BindingId)> _hellos = [];
    private readonly Dictionary<string, Session> _sessions = [];
    private readonly SemaphoreSlim _gate = new(1);
    private readonly CancellationTokenSource _lifetime = new();
    private readonly FileStream _directoryLock;
    private readonly TimeProvider _clock;
    private readonly ILogger? _logger;
    private readonly ITimer _timer;
    private bool _disposed;
    private bool _offersSuspended;
    public int Port { get; set; }
    public DeviceBindingService? Binding { get; init; }
    public string DevType { get; init; } = "windows";
    public event Action<string>? FileReceived;
    /// <summary>Raised under the receiver lock after acceptance, each committed chunk, and the terminal state. Handlers must not block.</summary>
    public event Action<ReceiveProgress>? ReceiveProgressChanged;

    public TransferReceiver(string destination, string alias, PeerAppPolicy policy, Func<IncomingOffer, CancellationToken, Task<bool>> confirm, TimeProvider? clock = null, ILogger? logger = null)
    {
        _logger = logger;
        _destination = Path.GetFullPath(destination); _alias = alias; _policy = policy; _confirm = confirm; _clock = clock ?? TimeProvider.System;
        Directory.CreateDirectory(_destination);
        _staging = Path.Combine(_destination, ".limlink-staging");
        Directory.CreateDirectory(_staging);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(_staging, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        else File.SetAttributes(_staging, File.GetAttributes(_staging) | FileAttributes.Hidden);
        _directoryLock = new FileStream(Path.Combine(_staging, "lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        foreach (var file in Directory.EnumerateFiles(_staging, "*.part")) File.Delete(file);
        _timer = _clock.CreateTimer(_ => _ = SweepAsync(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    public async Task<TransferReply> HandleAsync(PeerConnection peer, string method, string target, IReadOnlyDictionary<string, string> headers, ReadOnlyMemory<byte> body, CancellationToken cancellationToken = default)
    {
        var reply = await HandleCoreAsync(peer, method, target, headers, body, cancellationToken).ConfigureAwait(false);
        _logger?.LogInformation("inbound {Method} {Path} -> {Status} from {Peer}", method, target, reply.Status, peer.Fingerprint[..Math.Min(8, peer.Fingerprint.Length)]);
        return reply;
    }

    private async Task<TransferReply> HandleCoreAsync(PeerConnection peer, string method, string target, IReadOnlyDictionary<string, string> headers, ReadOnlyMemory<byte> body, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        Session? current = null;
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            Expire();
            if (!Fingerprint.TryDecode(peer.Fingerprint, out _) || string.IsNullOrEmpty(peer.ConnectionId)) return TransferReply.Error(401, "E_NOT_PAIRED");
            if (body.Length > (method == "PUT" ? TransferLimits.MaximumChunkBytes : TransferLimits.MaximumJsonBytes)) return TransferReply.Error(413, "E_FILE_TOO_LARGE");
            var path = target.Split('?')[0];
            if (path == LimLinkProtocol.HelloPath && method == "POST")
            {
                var json = Parse(body);
                if (!json.TryGetProperty("proto", out var versions) || versions.ValueKind != JsonValueKind.Array || !versions.EnumerateArray().Any(v => v.ValueKind == JsonValueKind.String && v.GetString() == "1.0")) return TransferReply.Error(400, "E_UNSUPPORTED_VERSION");
                if (_sessions.Values.Any(s => s.Owner.ConnectionId == peer.ConnectionId)) return TransferReply.Error(409, "E_INVALID_STATE");
                var alias = Text(json, "alias");
                if (alias.Length is 0 or > 128 || alias.Any(char.IsControl)) return TransferReply.Error(400, "E_BAD_REQUEST", "A device name is required.");
                var app = json.TryGetProperty("app", out var a) ? a.GetString() : null;
                if (!_hellos.ContainsKey(peer.ConnectionId) && _hellos.Count >= 4) return TransferReply.Error(409, "E_BUSY");
                var bindingId = json.TryGetProperty("bindingId", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString() : null;
                _hellos[peer.ConnectionId] = (peer, alias, PeerAppPolicy.NormalizePeer(app), bindingId);
                var bindingApp = _policy.HostAppId == "limlink" && PeerAppPolicy.NormalizePeer(app) == "limlink";
                return TransferReply.From(200, new HelloMessage { Proto = ["1.0"], Alias = _alias, App = _policy.HostAppId, DevType = DevType, Port = Port, Limits = HelloLimits.Default, Trusted = false, Caps = _policy.HostAppId == "limlink" ? ["binding-v1"] : [], BindingId = bindingApp ? Binding?.BindingIdFor(peer.Fingerprint) : null, Busy = _sessions.Count >= 4 });
            }
            headers.TryGetValue(LimLinkProtocol.HeaderApp, out var headerApp);
            if (!_policy.Allows(headerApp)) return TransferReply.Error(403, "E_APP_MISMATCH", detail: new { app = _policy.HostAppId });
            if (path == "/limlink/v1/sessions" && method == "POST")
            {
                if (_offersSuspended) return TransferReply.Error(409, "E_BUSY");
                if (!_hellos.TryGetValue(peer.ConnectionId, out var hello) || hello.Peer != peer) return TransferReply.Error(401, "E_NOT_PAIRED");
                if (!_policy.Allows(hello.App) || hello.App != PeerAppPolicy.NormalizePeer(headerApp)) return TransferReply.Error(403, "E_APP_MISMATCH");
                var json = Parse(body);
                var key = Text(json, "clientSessionKey");
                if (key.Length is 0 or > 128) return TransferReply.Error(400, "E_BAD_REQUEST");
                var transport = Text(json, "transport");
                if (transport == "remote-link" || json.TryGetProperty("inviteTicket", out _) || json.TryGetProperty("inviteSessionId", out _)) return TransferReply.Error(501, "E_NOT_IMPLEMENTED");
                if (transport != "lan") return TransferReply.Error(400, "E_BAD_REQUEST");
                var entries = json.GetProperty("entries");
                if (entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() != 1) return TransferReply.Error(400, "E_BAD_REQUEST");
                var entry = entries[0];
                var size = Integer(entry, "size");
                if (size < 0) return TransferReply.Error(400, "E_BAD_REQUEST");
                if (size > TransferLimits.MaximumFileBytes) return TransferReply.Error(413, "E_FILE_TOO_LARGE");
                if (Integer(json, "totalBytes") != size || Integer(json, "totalEntries") != 1 || Text(entry, "kind") != "file") return TransferReply.Error(400, "E_BAD_REQUEST");
                var id = Text(entry, "id");
                if (!Regex.IsMatch(id, "^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant)) return TransferReply.Error(400, "E_BAD_REQUEST");
                var original = Text(entry, "relativePath");
                var name = TransferNames.LandingName(original);
                var existing = _sessions.Values.FirstOrDefault(s => s.Owner == peer && s.ClientKey == key);
                if (existing is not null) return existing.Size == size && existing.FileId == id && existing.OriginalName == original ? TransferReply.From(202, new { sessionId = existing.Id, state = "pending" }) : TransferReply.Error(409, "E_INVALID_STATE");
                if (_sessions.Count >= 4 || _sessions.Values.Any(s => s.Owner == peer)) return TransferReply.Error(409, "E_BUSY");
                var sid = Guid.NewGuid().ToString("N");
                var session = new Session(sid, peer, key, id, original, name, size, Path.Combine(_staging, sid + ".part"), _clock.GetUtcNow()) { SenderName = hello.Alias };
                _sessions.Add(sid, session);
                _ = DecideAsync(session, new IncomingOffer(sid, hello.Alias, peer.Fingerprint, name, size),
                    _policy.HostAppId == "limlink" && hello.App == "limlink" && Binding?.Authorizes(peer.Fingerprint, hello.BindingId) == true);
                return TransferReply.From(202, new { sessionId = sid, state = "pending" });
            }
            var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 4 || parts[0] != "limlink" || parts[1] != "v1" || parts[2] != "sessions") return TransferReply.Error(404, "E_BAD_REQUEST");
            if (!_sessions.TryGetValue(parts[3], out current) || current.Owner != peer) return TransferReply.Error(404, "E_SESSION_NOT_FOUND");
            current.LastActivity = _clock.GetUtcNow();
            if (current.State == "decision_timeout") return TransferReply.Error(408, "E_DECISION_TIMEOUT");
            if (current.State == "expired") return TransferReply.Error(410, "E_SESSION_EXPIRED");
            if (parts.Length == 4 && method == "GET") return Poll(current);
            if (parts.Length == 5 && parts[4] == "cancel" && method == "POST")
            {
                var control = Parse(body);
                if (Text(control, "sessionId") != current.Id || string.IsNullOrEmpty(Text(control, "reason")) || current.State is "completed" or "cancelled") return TransferReply.Error(409, "E_INVALID_STATE");
                Fail(current); current.Cleanup(); current.State = "cancelled";
                return TransferReply.From(200, new { state = "cancelled", files = new Dictionary<string, object> { [current.FileId] = new { state = "cancelled", committedBytes = 0 } } });
            }
            // Sender holds: the Apple client pauses when the app goes to the background and resumes on return.
            if (parts.Length == 5 && parts[4] is "pause" or "resume" && method == "POST")
            {
                var control = Parse(body);
                if (Text(control, "sessionId") != current.Id) return TransferReply.Error(409, "E_INVALID_STATE");
                var reason = control.TryGetProperty("reason", out var reasonValue) ? reasonValue.GetString() : null;
                if (parts[4] == "pause")
                {
                    if (string.IsNullOrEmpty(reason)) return TransferReply.Error(400, "E_BAD_REQUEST");
                    if (current.State is not ("accepted" or "paused")) return TransferReply.Error(409, "E_INVALID_STATE");
                    current.SenderPaused = true;
                    current.State = "paused";
                    current.LastActivity = _clock.GetUtcNow();
                }
                else
                {
                    if (current.State == "expired") return TransferReply.Error(410, "E_SESSION_EXPIRED");
                    if (current.State is not ("accepted" or "paused")) return TransferReply.Error(409, "E_INVALID_STATE");
                    current.SenderPaused = false;
                    current.State = "accepted";
                    current.LastActivity = _clock.GetUtcNow();
                }
                return ControlReply(current);
            }
            if (parts.Length == 5 && parts[4] == "finish" && method == "POST")
            {
                if (current.State != "completed") return TransferReply.Error(409, "E_INVALID_STATE");
                return TransferReply.From(200, new { sessionId = current.Id, state = "finished", startedAt = current.Created, finishedAt = _clock.GetUtcNow(), durationMs = (long)(_clock.GetUtcNow() - current.Created).TotalMilliseconds,
                    totals = new { files = 1, completed = 1, failed = 0, verifyFailed = 0, rejected = 0, cancelled = 0, bytesPlanned = current.Size, bytesReceived = current.Committed },
                    files = new[] { new { id = current.FileId, relativePath = current.OriginalName, finalName = current.Name, renamed = current.Name != current.OriginalName, state = "completed", size = current.Size, bytesReceived = current.Committed, sha256Match = true } } });
            }
            if (parts.Length < 6 || parts[4] != "files" || parts[5] != current.FileId) return TransferReply.Error(404, "E_SESSION_NOT_FOUND");
            if (current.State == "paused") return TransferReply.Error(409, "E_SESSION_PAUSED");
            if (current.State != "accepted") return TransferReply.Error(409, "E_INVALID_STATE");
            if (parts.Length == 6 && method == "PUT")
            {
                if (!headers.TryGetValue(LimLinkProtocol.HeaderToken, out var token) || token != current.Token) return TransferReply.Error(403, "E_TOKEN_INVALID");
                if (!headers.TryGetValue("Content-Type", out var contentType) || contentType != "application/octet-stream" || (headers.TryGetValue("Content-Encoding", out var encoding) && encoding != "identity")) return TransferReply.Error(400, "E_BAD_REQUEST");
                if (!headers.TryGetValue(LimLinkProtocol.HeaderOffset, out var offsetText) || !long.TryParse(offsetText, NumberStyles.None, CultureInfo.InvariantCulture, out var offset) || offset != current.Committed) return TransferReply.Error(409, "E_OFFSET_MISMATCH", detail: new { committedBytes = current.Committed });
                if (body.Length > current.Size - offset || (body.Length == 0 && offset < current.Size)) return TransferReply.Error(400, "E_BAD_REQUEST");
                await current.Stream!.WriteAsync(body, cancellationToken).ConfigureAwait(false);
                current.Stream.Flush(flushToDisk: true);
                current.Hash.AppendData(body.Span);
                current.Committed += body.Length;
                Report(current, ReceiveState.Receiving);
                return TransferReply.From(200, new { committedBytes = current.Committed });
            }
            if (parts.Length == 7 && parts[6] == "complete" && method == "POST")
            {
                var expected = Text(Parse(body), "sha256");
                if (!Regex.IsMatch(expected, "^[0-9a-fA-F]{64}$", RegexOptions.CultureInvariant)) return TransferReply.Error(400, "E_BAD_REQUEST");
                var actual = Convert.ToHexStringLower(current.Hash.GetCurrentHash());
                if (current.Committed != current.Size || !string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                {
                    current.Mismatches++;
                    if (current.Mismatches >= 2) { Fail(current); current.Cleanup(); current.State = "verify_failed"; }
                    else { current.Stream!.SetLength(0); current.Stream.Position = 0; current.Committed = 0; current.Hash.GetHashAndReset(); }
                    return TransferReply.Error(422, "E_CHECKSUM_MISMATCH");
                }
                current.Stream!.Flush(flushToDisk: true);
                current.Stream.Dispose(); current.Stream = null;
                current.Name = Publish(current.Path, current.Name);
                current.State = "completed";
                var saved = Path.Combine(_destination, current.Name);
                Report(current, ReceiveState.Completed, saved);
                _ = Task.Run(() => { try { FileReceived?.Invoke(saved); } catch { /* Host notifications cannot invalidate a durable save. */ } });
                return TransferReply.From(200, new { verified = true, finalName = current.Name });
            }
            return TransferReply.Error(400, "E_BAD_REQUEST");
        }
        catch (TransferException ex) { return TransferReply.Error(400, ex.Code, ex.Message); }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException or ArgumentException) { return TransferReply.Error(400, "E_BAD_REQUEST"); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { if (current is not null) { Fail(current); current.Cleanup(); current.State = "cancelled"; } return TransferReply.Error(500, "E_WRITE_FAILED"); }
        catch (OperationCanceledException) { if (current is not null) { Fail(current); current.Cleanup(); current.State = "cancelled"; } throw; }
        finally { _gate.Release(); }
    }

    private string Publish(string source, string name)
    {
        for (var i = 0; i < 10000; i++)
        {
            var candidate = i == 0 ? name : Path.GetFileNameWithoutExtension(name) + $" ({i})" + Path.GetExtension(name);
            var destination = Path.Combine(_destination, candidate);
            try { File.Move(source, destination, overwrite: false); return candidate; }
            catch (IOException) when (File.Exists(destination) || Directory.Exists(destination)) { }
        }
        throw new IOException("No available destination filename.");
    }
    private static TransferReply ControlReply(Session session) => TransferReply.From(200, new
    {
        sessionId = session.Id,
        state = session.State == "paused" ? "paused" : "accepted",
        holds = session.SenderPaused ? new[] { new { by = "sender", reason = "app_background", since = session.Created.ToUnixTimeSeconds() } } : [],
        files = new Dictionary<string, object> { [session.FileId] = new { token = session.Token, offset = session.Committed, committedBytes = session.Committed, state = session.State } },
    });

    private static TransferReply Poll(Session session) => session.State switch
    {
        "paused" => ControlReply(session),
        "pending" => TransferReply.From(202, new { sessionId = session.Id, state = "pending" }),
        "rejected" => TransferReply.Error(403, "E_REJECTED"),
        "cancelled" => TransferReply.Error(410, "E_SESSION_CANCELLED"),
        "verify_failed" => TransferReply.Error(422, "E_CHECKSUM_MISMATCH"),
        _ => TransferReply.From(200, new { state = "accepted", files = new Dictionary<string, object> { [session.FileId] = new { accept = true, token = session.Token, offset = session.Committed, finalName = session.Name, state = session.State } } })
    };
    private async Task DecideAsync(Session session, IncomingOffer offer, bool automatic)
    {
        bool accept;
        var timedOut = false;
        using var token = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token, session.Cancel.Token);
        token.CancelAfter(TimeSpan.FromSeconds(120));
        try { accept = automatic || await Task.Run(() => _confirm(offer, token.Token), token.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!_lifetime.IsCancellationRequested && !session.Cancel.IsCancellationRequested) { accept = false; timedOut = true; }
        catch { accept = false; }
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed || !_sessions.ContainsKey(session.Id) || session.State != "pending") return;
            // An unanswered prompt is a decision timeout, not a rejection, even if this wakes before the sweep.
            if (!accept) { session.State = timedOut ? "decision_timeout" : "rejected"; session.Cleanup(); return; }
            try { session.Stream = new FileStream(session.Path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous); session.State = "accepted"; session.LastActivity = _clock.GetUtcNow(); Report(session, ReceiveState.Receiving); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { session.State = "cancelled"; session.Cleanup(); }
        }
        finally { _gate.Release(); }
    }
    /// <summary>Atomically blocks new offers only when no consent or receive is active.</summary>
    public async Task<bool> TrySuspendOffersAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_sessions.Values.Any(s => s.State is "pending" or "accepted")) return false;
            _offersSuspended = true;
            return true;
        }
        finally { _gate.Release(); }
    }
    public void ResumeOffers()
    {
        _gate.Wait();
        try { _offersSuspended = false; } finally { _gate.Release(); }
    }

    public async Task DisconnectAsync(string connectionId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { _hellos.Remove(connectionId); foreach (var sid in _sessions.Where(p => p.Value.Owner.ConnectionId == connectionId).Select(p => p.Key).ToArray()) { Fail(_sessions[sid]); _sessions[sid].Dispose(); _sessions.Remove(sid); } }
        finally { _gate.Release(); }
    }
    private async Task SweepAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { if (!_disposed) Expire(); } finally { _gate.Release(); }
    }
    private void Expire()
    {
        var now = _clock.GetUtcNow();
        foreach (var s in _sessions.Values)
        {
            if (s.State == "pending" && now - s.Created >= TimeSpan.FromSeconds(120)) { s.Cleanup(); s.State = "decision_timeout"; }
            // A paused sender stays resumable for up to 30 minutes, matching the completion grace period.
            else if (s.State is not "pending" and not "decision_timeout" and not "expired" && now - s.LastActivity >= (s.State == "paused" ? TimeSpan.FromMinutes(30) : TimeSpan.FromSeconds(120))) { Fail(s); s.Cleanup(); s.State = "expired"; }
        }
    }
    private void Fail(Session session) { if (session.State == "accepted") Report(session, ReceiveState.Failed); }
    private void Report(Session session, ReceiveState state, string? savedPath = null)
    {
        try { ReceiveProgressChanged?.Invoke(new(session.Id, session.SenderName, session.Name, session.Committed, session.Size, state, savedPath)); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { /* Host progress cannot affect the transfer. */ }
    }
    internal static JsonElement Parse(ReadOnlyMemory<byte> body)
    {
        var json = JsonSerializer.Deserialize<JsonElement>(body.Span);
        if (json.ValueKind != JsonValueKind.Object) throw new JsonException();
        ValidateUniqueKeys(json);
        return json;
    }
    private static void ValidateUniqueKeys(JsonElement node)
    {
        if (node.ValueKind == JsonValueKind.Object) { var names = new HashSet<string>(StringComparer.Ordinal); foreach (var property in node.EnumerateObject()) { if (!names.Add(property.Name)) throw new JsonException(); ValidateUniqueKeys(property.Value); } }
        else if (node.ValueKind == JsonValueKind.Array) foreach (var item in node.EnumerateArray()) ValidateUniqueKeys(item);
    }
    internal static string Text(JsonElement json, string key) => json.GetProperty(key).GetString() ?? throw new JsonException();
    internal static long Integer(JsonElement json, string key)
    {
        var value = json.GetProperty(key);
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var integer)) throw new JsonException();
        return integer;
    }
    public void Dispose()
    {
        _gate.Wait();
        try { if (_disposed) return; _disposed = true; _timer.Dispose(); _lifetime.Cancel(); foreach (var session in _sessions.Values) session.Dispose(); _sessions.Clear(); _hellos.Clear(); _directoryLock.Dispose(); }
        finally { _gate.Release(); }
    }
    private sealed class Session(string id, PeerConnection owner, string clientKey, string fileId, string originalName, string name, long size, string path, DateTimeOffset created) : IDisposable
    {
        public string Id = id, ClientKey = clientKey, FileId = fileId, OriginalName = originalName, Name = name, Path = path, State = "pending", SenderName = "";
        public bool SenderPaused;
        public readonly PeerConnection Owner = owner;
        public readonly string Token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        public long Size = size, Committed;
        public int Mismatches;
        public DateTimeOffset Created = created, LastActivity = created;
        public FileStream? Stream;
        public readonly IncrementalHash Hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public readonly CancellationTokenSource Cancel = new();
        public void Cleanup() { Cancel.Cancel(); Stream?.Dispose(); Stream = null; try { File.Delete(Path); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } }
        public void Dispose() { Cleanup(); Hash.Dispose(); }
    }
}
