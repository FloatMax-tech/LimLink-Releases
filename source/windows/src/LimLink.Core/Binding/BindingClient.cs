using System.Text.Json;
namespace LimLink;
public sealed partial class LimLinkClient
{
    /// <summary>Selection and Bind are the initiator's consent. Only the recipient is prompted.</summary>
    public async Task BindAsync(DiscoveryPeer peer, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (_policy.HostAppId != "limlink" || !_policy.Allows(peer.App) || peer.App != "limlink" || peer.Fingerprint == Fingerprint.Compute(_certificate)) throw new TransferException("E_APP_MISMATCH", "Invalid binding peer.");
        var binding = _options.Binding ?? throw new TransferException("E_PAIR_STORAGE_FAILED", "Secure storage is unavailable.");
        var generation = binding.BeginOutgoing();
        TransferHttp? connection = null; string? id = null, token = null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(120));
        try
        {
            connection = await TransferHttp.ConnectAsync(peer, _certificate, _policy.HostAppId, deadline.Token).ConfigureAwait(false);
            var start = TransferResponseValidator.Success(await connection.JsonAsync("POST", "/limlink/v1/pair/start", new { version = 1, requestId = Guid.NewGuid().ToString("D"), alias = _options.Alias, deviceType = _options.DevType }, deadline.Token).ConfigureAwait(false), 202);
            id = TransferReceiver.Text(start, "pairId"); token = TransferReceiver.Text(start, "token");
            var alias = TransferReceiver.Text(start, "alias"); var type = TransferReceiver.Text(start, "deviceType");
            if (!DeviceBindingService.ValidId(id) || !DeviceBindingService.CanonicalFingerprint(token) || TransferReceiver.Integer(start, "version") != 1 || TransferReceiver.Text(start, "state") != "pending" || !DeviceBindingService.ValidAlias(alias) || !DeviceBindingService.ValidType(type)) throw new TransferException("E_BAD_REQUEST", "Invalid binding response.");
            progress?.Report("pending");
            var headers = new Dictionary<string, string> { ["X-LimLink-Pair-Token"] = token, ["Content-Type"] = "application/json" };
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(1), deadline.Token).ConfigureAwait(false);
                var poll = TransferResponseValidator.Success(await connection.RequestAsync("GET", "/limlink/v1/pair/" + id, ReadOnlyMemory<byte>.Empty, headers, deadline.Token).ConfigureAwait(false), 200);
                ValidatePairState(poll, id);
                var state = TransferReceiver.Text(poll, "state");
                if (state == "pending") continue;
                if (state != "accepted") throw new TransferException("E_PAIR_NOT_ACCEPTED", "The recipient did not accept binding.");
                var completed = TransferResponseValidator.Success(await connection.RequestAsync("POST", "/limlink/v1/pair/" + id + "/complete", "{}"u8.ToArray(), headers, deadline.Token).ConfigureAwait(false), 200);
                ValidatePairState(completed, id);
                if (TransferReceiver.Text(completed, "state") != "completed") throw new TransferException("E_BAD_REQUEST", "Binding did not complete.");
                binding.SaveOutgoing(generation, peer.Fingerprint, id, alias, type, deadline.Token);
                progress?.Report("completed"); return;
            }
        }
        catch
        {
            if (connection is not null && DeviceBindingService.ValidId(id) && token is not null && DeviceBindingService.CanonicalFingerprint(token))
            {
                try { using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await connection.RequestAsync("POST", "/limlink/v1/pair/" + id + "/cancel", "{}"u8.ToArray(), new Dictionary<string, string> { ["X-LimLink-Pair-Token"] = token }, cleanup.Token).ConfigureAwait(false); } catch { /* Unilateral records do not authorize without a matching hello. */ }
            }
            throw;
        }
        finally { if (connection is not null) await connection.DisposeAsync().ConfigureAwait(false); binding.EndOutgoing(); }
    }
    public async Task<bool> UnbindAsync(string fingerprint, DiscoveryPeer? onlinePeer, CancellationToken cancellationToken = default)
    {
        var record = _options.Binding?.Unbind(fingerprint);
        if (record is null || onlinePeer is null) return false;
        try
        {
            await using var connection = await TransferHttp.ConnectAsync(onlinePeer, _certificate, _policy.HostAppId, cancellationToken).ConfigureAwait(false);
            TransferResponseValidator.Success(await connection.JsonAsync("POST", "/limlink/v1/pair/" + record.BindingId + "/revoke", new { }, cancellationToken).ConfigureAwait(false), 200);
            return true;
        }
        catch (Exception ex) when (ex is IOException or AuthenticationException or OperationCanceledException or TransferException or System.Net.Sockets.SocketException) { return false; }
    }
    private static void ValidatePairState(JsonElement json, string id)
    {
        if (TransferReceiver.Integer(json, "version") != 1 || TransferReceiver.Text(json, "pairId") != id) throw new TransferException("E_BAD_REQUEST", "Invalid binding state response.");
    }
}
