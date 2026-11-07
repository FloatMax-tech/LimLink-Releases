using System.Text;
using System.Text.Json;
namespace LimLink;

public sealed record BindingOffer(string PairId, string Alias, string DeviceType);

/// <summary>Recipient-only binding consent and current-own-key authorization. All state and persistence are serialized.</summary>
public sealed class DeviceBindingService : IDisposable
{
    private readonly object _gate = new();
    private readonly IBindingStore _store;
    private readonly string _own, _alias, _type;
    private readonly TimeProvider _clock;
    private readonly Func<BindingOffer, CancellationToken, Task<bool>> _confirm;
    private readonly Queue<long> _arrivals = new();
    private List<DeviceBinding> _records = [];
    private Attempt? _attempt;
    private bool _stopped, _outgoing;
    private long _generation;
    public string? StorageError { get; private set; }
    public event Action? Changed;
    public DeviceBindingService(string own, string alias, string type, IBindingStore store, Func<BindingOffer, CancellationToken, Task<bool>>? confirm = null, TimeProvider? clock = null)
    {
        _own = own; _alias = alias; _type = type; _store = store; _confirm = confirm ?? ((_, _) => Task.FromResult(false)); _clock = clock ?? TimeProvider.System;
        try
        {
            var records = store.Read();
            if (records.Count > 1024 || records.Any(r => r is null || !ValidId(r.BindingId) || !CanonicalFingerprint(r.OwnFingerprint) || !CanonicalFingerprint(r.PeerFingerprint) || r.PeerFingerprint == own || !ValidAlias(r.Alias) || !ValidType(r.DeviceType)) || records.GroupBy(r => r.PeerFingerprint).Any(g => g.Count() > 1)) throw new IOException("Invalid binding records.");
            _records = records.Where(r => r.OwnFingerprint == own).ToList();
        }
        catch (Exception ex) when (StorageException(ex)) { StorageError = "Secure binding storage could not be read."; }
    }
    public IReadOnlyList<DeviceBinding> Bindings { get { lock (_gate) return _records.ToArray(); } }
    public string? BindingIdFor(string peer) { lock (_gate) return _stopped ? null : _records.FirstOrDefault(r => r.OwnFingerprint == _own && r.PeerFingerprint == peer)?.BindingId; }
    public bool Authorizes(string peer, string? id) => ValidId(id) && BindingIdFor(peer) == id;
    public long BeginOutgoing()
    {
        lock (_gate) { Expire(); if (_stopped || _outgoing || _attempt?.State is "pending" or "accepted") throw new TransferException("E_PAIR_BUSY", "Another binding is active."); _outgoing = true; return _generation; }
    }
    public void EndOutgoing() { lock (_gate) _outgoing = false; }
    public void SaveOutgoing(long generation, string peer, string id, string alias, string type, CancellationToken token)
    {
        lock (_gate)
        {
            token.ThrowIfCancellationRequested();
            if (_stopped || !_outgoing || generation != _generation || !ValidId(id) || !CanonicalFingerprint(peer) || !ValidAlias(alias) || !ValidType(type) || peer == _own)
                throw new TransferException("E_PAIR_EXPIRED", "Binding is no longer active.");
            Save(peer, id, alias, type);
            if (token.IsCancellationRequested || _stopped || !_outgoing || generation != _generation)
            {
                // A synchronous durable write can outlive cancellation. Never report or
                // retain that new permission; an unrelated or newer binding is untouched.
                Remove(peer, id);
                token.ThrowIfCancellationRequested();
                throw new TransferException("E_PAIR_EXPIRED", "Binding is no longer active.");
            }
        }
    }
    public DeviceBinding? Unbind(string peer)
    {
        lock (_gate)
        {
            _generation++; var found = _records.FirstOrDefault(r => r.PeerFingerprint == peer);
            if (_attempt?.Owner.Fingerprint == peer) { _attempt.State = "cancelled"; _attempt.Cancel.Cancel(); }
            if (found is not null) Remove(peer, found.BindingId);
            return found;
        }
    }
    public Task<TransferReply> HandleAsync(PeerConnection peer, string method, string path, IReadOnlyDictionary<string, string> headers, ReadOnlyMemory<byte> body)
    {
        lock (_gate)
        {
            try
            {
                Expire();
                if (_stopped || !CanonicalFingerprint(peer.Fingerprint) || peer.Fingerprint == _own || string.IsNullOrEmpty(peer.ConnectionId)) return Task.FromResult(TransferReply.Error(403, "E_PAIR_TOKEN_INVALID"));
                if (body.Length > 16_384) return Task.FromResult(TransferReply.Error(413, "E_BAD_REQUEST"));
                var parts = path.Split('/');
                if (path == "/limlink/v1/pair/start" && method == "POST")
                {
                    var json = TransferReceiver.Parse(body);
                    if (!json.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != 1) return Task.FromResult(TransferReply.Error(400, "E_PAIR_VERSION"));
                    var requestId = TransferReceiver.Text(json, "requestId"); var alias = TransferReceiver.Text(json, "alias"); var type = TransferReceiver.Text(json, "deviceType");
                    if (!ValidId(requestId) || !ValidAlias(alias) || !ValidType(type)) return Task.FromResult(TransferReply.Error(400, "E_BAD_REQUEST"));
                    if (_attempt is { } retry && retry.Owner == peer && retry.RequestId == requestId && retry.State is "pending" or "accepted") return Task.FromResult(StartReply(retry));
                    if (_outgoing || _attempt?.State is "pending" or "accepted") return Task.FromResult(TransferReply.Error(409, "E_PAIR_BUSY"));
                    var now = _clock.GetTimestamp();
                    while (_arrivals.TryPeek(out var at) && _clock.GetElapsedTime(at, now) >= TimeSpan.FromSeconds(60)) _arrivals.Dequeue();
                    if (_arrivals.Count >= 3) return Task.FromResult(TransferReply.Error(429, "E_PAIR_RATE_LIMITED"));
                    _arrivals.Enqueue(now); _attempt?.Cancel.Dispose();
                    var attempt = new Attempt(peer, requestId, alias, type, now); _attempt = attempt;
                    _ = Task.Run(() => ConfirmAsync(attempt));
                    return Task.FromResult(StartReply(attempt));
                }
                if (parts.Length is < 5 or > 6 || !ValidId(parts[4])) return Task.FromResult(TransferReply.Error(400, "E_BAD_REQUEST"));
                var id = parts[4]; var action = parts.Length == 6 ? parts[5] : "";
                if (action == "revoke" && method == "POST")
                {
                    TransferReceiver.Parse(body);
                    if (_attempt?.Id == id && _attempt.Owner.Fingerprint == peer.Fingerprint) { _attempt.State = "cancelled"; _attempt.Cancel.Cancel(); }
                    // Remote revocation is exact-ID and must not invalidate an
                    // unrelated locally initiated handshake.
                    Remove(peer.Fingerprint, id); return Task.FromResult(TransferReply.From(200, new { state = "revoked" }));
                }
                var a = _attempt;
                if (a is null || a.Id != id || a.State == "expired") return Task.FromResult(TransferReply.Error(410, "E_PAIR_EXPIRED"));
                if (a.Owner != peer || !headers.TryGetValue("X-LimLink-Pair-Token", out var token) || !SafeToken(a.Token, token)) return Task.FromResult(TransferReply.Error(403, "E_PAIR_TOKEN_INVALID"));
                if (method == "GET" && action == "") return Task.FromResult(StateReply(a));
                if (method != "POST") return Task.FromResult(TransferReply.Error(405, "E_BAD_REQUEST"));
                TransferReceiver.Parse(body);
                if (action == "cancel") { a.State = "cancelled"; a.Cancel.Cancel(); Remove(peer.Fingerprint, a.Id); return Task.FromResult(TransferReply.From(200, new { state = "cancelled" })); }
                if (action == "complete")
                {
                    if (a.State == "completed" && Authorizes(peer.Fingerprint, id)) return Task.FromResult(StateReply(a));
                    if (a.State != "accepted") return Task.FromResult(TransferReply.Error(409, "E_PAIR_NOT_ACCEPTED"));
                    try { Save(peer.Fingerprint, a.Id, a.Alias, a.Type); a.State = "completed"; a.Cancel.Cancel(); return Task.FromResult(StateReply(a)); }
                    catch (Exception ex) when (StorageException(ex)) { a.State = "failed"; a.Cancel.Cancel(); return Task.FromResult(TransferReply.Error(500, "E_PAIR_STORAGE_FAILED")); }
                }
                return Task.FromResult(TransferReply.Error(404, "E_BAD_REQUEST"));
            }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or ArgumentException) { return Task.FromResult(TransferReply.Error(400, "E_BAD_REQUEST")); }
            catch (Exception ex) when (StorageException(ex)) { return Task.FromResult(TransferReply.Error(500, "E_PAIR_STORAGE_FAILED")); }
        }
    }
    private async Task ConfirmAsync(Attempt a)
    {
        bool accepted;
        try { accepted = await _confirm(new(a.Id, a.Alias, a.Type), a.Cancel.Token).WaitAsync(a.Cancel.Token).ConfigureAwait(false); } catch { accepted = false; }
        lock (_gate) { Expire(); if (!_stopped && _attempt == a && a.State == "pending") a.State = accepted ? "accepted" : "rejected"; }
    }
    public void Disconnect(string connectionId)
    {
        lock (_gate) { if (_attempt is { } a && a.Owner.ConnectionId == connectionId && a.State is "pending" or "accepted") { a.State = "cancelled"; a.Cancel.Cancel(); } }
    }
    private void Expire() { if (_stopped) return; if (_attempt is { } a && a.State != "expired" && _clock.GetElapsedTime(a.Start) >= TimeSpan.FromSeconds(120)) { a.State = "expired"; a.Cancel.Cancel(); } }
    private TransferReply StartReply(Attempt a) => TransferReply.From(202, new { version = 1, pairId = a.Id, token = a.Token, state = "pending", expiresInSeconds = Seconds(a), alias = _alias, deviceType = _type });
    private int Seconds(Attempt a) => Math.Max(0, 120 - (int)_clock.GetElapsedTime(a.Start).TotalSeconds);
    private TransferReply StateReply(Attempt a) => TransferReply.From(200, new { version = 1, pairId = a.Id, state = a.State, expiresInSeconds = Seconds(a) });
    private void Save(string peer, string id, string alias, string type)
    {
        var next = _records.Where(r => r.PeerFingerprint != peer).Append(new DeviceBinding(_own, peer, id, alias, type, _clock.GetUtcNow())).ToList();
        try { _store.Write(next); _records = next; StorageError = null; Notify(); }
        catch (Exception ex) when (StorageException(ex)) { _records.Clear(); StorageError = "Secure binding storage could not be saved."; Notify(); throw; }
    }
    private void Remove(string peer, string id)
    {
        if (!_records.Any(r => r.PeerFingerprint == peer && r.BindingId == id)) return;
        _records = _records.Where(r => r.PeerFingerprint != peer || r.BindingId != id).ToList();
        try { _store.Write(_records); StorageError = null; }
        catch (Exception ex) when (StorageException(ex)) { StorageError = "Secure binding removal could not be saved."; throw; }
        finally { Notify(); }
    }
    private void Notify() { try { Changed?.Invoke(); } catch (Exception ex) when (ex is not OutOfMemoryException) { /* Notifications cannot undo durable state. */ } }
    internal static bool CanonicalFingerprint(string? value) => value is not null && value.Length == 43 && Fingerprint.TryDecode(value, out var bytes) && Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') == value;
    internal static bool ValidId(string? value) => Guid.TryParseExact(value, "D", out var guid) && guid.ToString("D") == value;
    internal static bool ValidAlias(string value) => !string.IsNullOrWhiteSpace(value) && value.IsNormalized() && Encoding.UTF8.GetByteCount(value) <= 63 && !value.Any(char.IsControl);
    internal static bool ValidType(string type) => type is "iphone" or "ipad" or "mac" or "windows" or "android";
    private static bool SafeToken(string a, string b) => a.Length == b.Length && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(a), Encoding.ASCII.GetBytes(b));
    private static bool StorageException(Exception ex) => ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException or PlatformNotSupportedException;
    public void Dispose() { lock (_gate) { _stopped = true; _generation++; _attempt?.Cancel.Cancel(); _attempt?.Cancel.Dispose(); _records.Clear(); } }
    private sealed class Attempt(PeerConnection owner, string requestId, string alias, string type, long start)
    {
        public readonly PeerConnection Owner = owner;
        public readonly string RequestId = requestId, Alias = alias, Type = type;
        public readonly string Id = Guid.NewGuid().ToString("D");
        public readonly string Token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        public readonly long Start = start;
        public string State = "pending";
        public readonly CancellationTokenSource Cancel = new(TimeSpan.FromSeconds(120));
    }
}
