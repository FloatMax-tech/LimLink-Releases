using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace LimLink;

public sealed record TransferProgress(long BytesSent, long TotalBytes, string State);
public sealed record TransferResult(string FinalName, long Size, string Sha256);

public sealed partial class LimLinkClient
{
    /// <summary>All HTTP exchanges use this one pinned mTLS connection. No reconnect or redirect is permitted.</summary>
    public async Task<TransferResult> SendFileAsync(DiscoveryPeer peer, string sourcePath, string scratchDirectory, IProgress<TransferProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        if (!_policy.Allows(peer.App)) throw new TransferException("E_APP_MISMATCH", "The selected peer is not compatible.");
        progress?.Report(new(0, 0, "Preparing file"));
        await using var source = await FileSnapshot.CreateAsync(sourcePath, scratchDirectory, cancellationToken).ConfigureAwait(false);
        progress?.Report(new(0, source.Size, "Connecting"));
        await using var connection = await TransferHttp.ConnectAsync(peer, _certificate, _policy.HostAppId, cancellationToken).ConfigureAwait(false);
        var bindingApp = _policy.HostAppId == "limlink" && PeerAppPolicy.NormalizePeer(peer.App) == "limlink";
        var hello = await connection.JsonAsync("POST", LimLinkProtocol.HelloPath, new HelloMessage { Proto = ["1.0"], Alias = _options.Alias, App = _policy.HostAppId, DevType = _options.DevType, Port = _options.LocalPort, Limits = HelloLimits.Default, Caps = _policy.HostAppId == "limlink" ? ["binding-v1"] : [], BindingId = bindingApp ? _options.Binding?.BindingIdFor(peer.Fingerprint) : null }, cancellationToken).ConfigureAwait(false);
        var helloJson = TransferResponseValidator.Success(hello, 200);
        var helloApp = helloJson.TryGetProperty("app", out var app) ? app.GetString() : null;
        if (!_policy.Allows(helloApp) || PeerAppPolicy.NormalizePeer(helloApp) != PeerAppPolicy.NormalizePeer(peer.App)) throw new TransferException("E_APP_MISMATCH", "The selected device changed its app identity.");
        if (!helloJson.TryGetProperty("proto", out var versions) || !versions.EnumerateArray().Any(v => v.GetString() == "1.0")) throw new TransferException("E_UNSUPPORTED_VERSION", "No common protocol version.");
        const string fileId = "file";
        var create = await connection.JsonAsync("POST", "/limlink/v1/sessions", new { clientSessionKey = Guid.NewGuid().ToString("N"), transport = "lan", totalEntries = 1, totalBytes = source.Size,
            entries = new[] { new { id = fileId, kind = "file", relativePath = source.Name, size = source.Size } } }, cancellationToken).ConfigureAwait(false);
        var sid = TransferReceiver.Text(TransferResponseValidator.Success(create, 202), "sessionId");
        if (!System.Text.RegularExpressions.Regex.IsMatch(sid, "^[A-Za-z0-9_-]{1,128}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant)) throw new TransferException("E_BAD_REQUEST", "Invalid session ID.");
        var root = "/limlink/v1/sessions/" + sid;
        progress?.Report(new(0, source.Size, "Waiting for receiver approval"));
        string token;
        using (var approval = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            approval.CancelAfter(TimeSpan.FromSeconds(120));
            while (true)
            {
                var poll = await connection.RequestAsync("GET", root + "?wait=25", ReadOnlyMemory<byte>.Empty, null, approval.Token).ConfigureAwait(false);
                if (poll.Status == 202) { await Task.Delay(150, approval.Token).ConfigureAwait(false); continue; }
                var status = TransferResponseValidator.Success(poll, 200);
                if (TransferReceiver.Text(status, "state") != "accepted") throw new TransferException("E_INVALID_STATE", "The receiver did not accept the file.");
                var file = status.GetProperty("files").GetProperty(fileId);
                token = TransferResponseValidator.AcceptedFile(file);
                break;
            }
        }
        string finalName;
        for (var attempt = 0; ; attempt++)
        {
            long offset = 0;
            do
            {
                var chunk = await source.ReadChunkAsync(offset, cancellationToken).ConfigureAwait(false);
                var headers = new Dictionary<string, string> { ["Content-Type"] = "application/octet-stream", [LimLinkProtocol.HeaderToken] = token, [LimLinkProtocol.HeaderOffset] = offset.ToString(CultureInfo.InvariantCulture) };
                var put = await connection.RequestAsync("PUT", root + "/files/" + fileId, chunk, headers, cancellationToken).ConfigureAwait(false);
                TransferResponseValidator.Ack(TransferResponseValidator.Success(put, 200), offset + chunk.Length);
                offset += chunk.Length;
                progress?.Report(new(offset, source.Size, "Sending"));
            } while (offset < source.Size);
            var complete = await connection.JsonAsync("POST", root + "/files/" + fileId + "/complete", new { sha256 = source.Sha256 }, cancellationToken).ConfigureAwait(false);
            if (complete.Status == 422 && attempt == 0 && complete.Json.TryGetProperty("code", out var code) && code.GetString() == "E_CHECKSUM_MISMATCH") continue;
            finalName = TransferResponseValidator.Complete(TransferResponseValidator.Success(complete, 200));
            break;
        }
        var finish = await connection.JsonAsync("POST", root + "/finish", new { sessionId = sid }, cancellationToken).ConfigureAwait(false);
        TransferResponseValidator.Finish(TransferResponseValidator.Success(finish, 200), sid, fileId, source.Size, finalName);
        progress?.Report(new(source.Size, source.Size, "Completed"));
        return new(finalName, source.Size, source.Sha256);
    }
}

internal static class TransferResponseValidator
{
    public static JsonElement Success(TransferReply reply, int expected)
    {
        if (reply.Status != expected)
        {
            string code = "E_BAD_REQUEST", message = "Unexpected peer response.";
            try { var e = reply.Json; if (e.TryGetProperty("code", out var c)) code = c.GetString() ?? code; if (e.TryGetProperty("message", out var m)) message = m.GetString() ?? message; } catch (JsonException) { }
            throw new TransferException(code, message);
        }
        try { return TransferReceiver.Parse(reply.Body); } catch (Exception ex) when (ex is JsonException or InvalidOperationException) { throw new TransferException("E_BAD_REQUEST", "Invalid JSON response."); }
    }
    public static string AcceptedFile(JsonElement file)
    {
        try
        {
            var token = TransferReceiver.Text(file, "token");
            if (file.GetProperty("accept").ValueKind == JsonValueKind.True && token.Length is > 0 and <= 512 && token.All(c => c is >= (char)33 and <= (char)126) && TransferReceiver.Integer(file, "offset") == 0) return token;
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { }
        throw new TransferException("E_BAD_REQUEST", "The receiver did not explicitly accept the file with a valid token and starting offset.");
    }

    public static void Ack(JsonElement json, long expected)
    {
        try { if (TransferReceiver.Integer(json, "committedBytes") == expected) return; } catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { }
        throw new TransferException("E_BAD_REQUEST", "Peer acknowledged an unexpected byte offset.");
    }
    public static string Complete(JsonElement json)
    {
        try { var name = TransferReceiver.Text(json, "finalName"); if (json.GetProperty("verified").ValueKind == JsonValueKind.True && TransferNames.LandingName(name) == name) return name; } catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException) { }
        throw new TransferException("E_BAD_REQUEST", "Peer did not confirm a verified file.");
    }
    public static void Finish(JsonElement json, string sid, string fileId, long size, string name)
    {
        try
        {
            var files = json.GetProperty("files");
            if (TransferReceiver.Text(json, "sessionId") == sid && TransferReceiver.Text(json, "state") == "finished" && files.ValueKind == JsonValueKind.Array && files.GetArrayLength() == 1)
            {
                var f = files[0];
                if (TransferReceiver.Text(f, "id") == fileId && TransferReceiver.Text(f, "state") == "completed" && TransferReceiver.Text(f, "finalName") == name && TransferReceiver.Integer(f, "size") == size && TransferReceiver.Integer(f, "bytesReceived") == size && f.GetProperty("sha256Match").ValueKind == JsonValueKind.True) return;
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException) { }
        throw new TransferException("E_BAD_REQUEST", "The final report does not match the file sent.");
    }
}

internal sealed class TransferHttp(TcpClient tcp, SslStream stream, string host, int port, string app) : IAsyncDisposable
{
    public static async Task<TransferHttp> ConnectAsync(DiscoveryPeer peer, X509Certificate2 certificate, string app, CancellationToken cancellationToken)
    {
        Exception? last = null;
        foreach (var address in peer.AddressCandidates.Prepend(peer.Host).Distinct().Take(8))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try { return await ConnectAsync(address, peer.Port, peer.Fingerprint, certificate, app, cancellationToken).ConfigureAwait(false); }
            catch (Exception ex) when (ex is SocketException or IOException or AuthenticationException || ex is OperationCanceledException && !cancellationToken.IsCancellationRequested) { last = ex; }
        }
        throw last ?? new IOException("No peer address is available.");
    }
    public static async Task<TransferHttp> ConnectAsync(string host, int port, string fingerprint, X509Certificate2 certificate, string app, CancellationToken cancellationToken)
    {
        if (host.Any(c => c < 33 || c > 126) || port is < 1 or > 65535 || !Fingerprint.TryDecode(fingerprint, out _)) throw new ArgumentException("Invalid selected peer.");
        var tcp = new TcpClient();
        SslStream? ssl = null;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); timeout.CancelAfter(TimeSpan.FromSeconds(10));
            await tcp.ConnectAsync(host, port, timeout.Token).ConfigureAwait(false);
            ssl = new SslStream(tcp.GetStream(), false);
            var options = LimLinkTls.CreateClient(certificate, (_, peer, _, _) =>
            {
                if (peer is null) return false;
                using var parsed = X509CertificateLoader.LoadCertificate(peer.Export(X509ContentType.Cert));
                return Fingerprint.FixedEquals(Fingerprint.Compute(parsed), fingerprint);
            });
            await ssl.AuthenticateAsClientAsync(options, timeout.Token).ConfigureAwait(false);
            if (ssl.SslProtocol != SslProtocols.Tls13 || ssl.NegotiatedApplicationProtocol != SslApplicationProtocol.Http11 || ssl.LocalCertificate is null) throw new AuthenticationException("TLS 1.3 mutual authentication with HTTP/1.1 is required.");
            return new TransferHttp(tcp, ssl, host, port, app);
        }
        catch { ssl?.Dispose(); tcp.Dispose(); throw; }
    }
    public Task<TransferReply> JsonAsync(string method, string path, object body, CancellationToken cancellationToken) => RequestAsync(method, path, JsonSerializer.SerializeToUtf8Bytes(body, ProtocolJson.Options), new Dictionary<string, string> { ["Content-Type"] = "application/json" }, cancellationToken);
    internal static TimeSpan ResponseTimeout(string method, string path)
    {
        var parts = path.Split('?')[0].Split('/');
        return method == "POST" && parts.Length == 8 && parts[0] == "" && parts[1] == "limlink" && parts[2] == "v1" &&
            parts[3] == "sessions" && parts[4].Length > 0 && parts[5] == "files" && parts[6].Length > 0 && parts[7] == "complete"
            ? TimeSpan.FromMinutes(30) : TimeSpan.FromSeconds(120);
    }
    internal static CancellationTokenSource CreateRequestTimeout(string method, string path, CancellationToken cancellationToken)
    {
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ResponseTimeout(method, path));
        return timeout;
    }
    public async Task<TransferReply> RequestAsync(string method, string path, ReadOnlyMemory<byte> body, IReadOnlyDictionary<string, string>? headers, CancellationToken cancellationToken)
    {
        using var timeout = CreateRequestTimeout(method, path, cancellationToken);
        var authority = host.Contains(':') ? $"[{host}]" : host;
        var text = new StringBuilder($"{method} {path} HTTP/1.1\r\nHost: {authority}:{port}\r\nX-LimLink-App: {app}\r\nContent-Length: {body.Length}\r\nConnection: keep-alive\r\n");
        if (headers is not null) foreach (var header in headers) text.Append(header.Key).Append(": ").Append(header.Value).Append("\r\n");
        text.Append("\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(text.ToString()), timeout.Token).ConfigureAwait(false);
        await stream.WriteAsync(body, timeout.Token).ConfigureAwait(false);
        await stream.FlushAsync(timeout.Token).ConfigureAwait(false);
        var maximumBodyBytes = path.StartsWith("/limlink/v1/pair/", StringComparison.Ordinal) ? 16_384 : TransferLimits.MaximumJsonBytes;
        return await ReadResponseAsync(stream, timeout.Token, maximumBodyBytes).ConfigureAwait(false);
    }
    internal static async Task<TransferReply> ReadResponseAsync(Stream stream, CancellationToken cancellationToken, int maximumBodyBytes = TransferLimits.MaximumJsonBytes)
    {
        var header = new byte[16_384]; var count = 0;
        while (true)
        {
            if (count == header.Length) throw new IOException("Response headers are too large.");
            await stream.ReadExactlyAsync(header.AsMemory(count, 1), cancellationToken).ConfigureAwait(false); count++;
            if (count >= 4 && header[count - 4] == 13 && header[count - 3] == 10 && header[count - 2] == 13 && header[count - 1] == 10) break;
        }
        var lines = Encoding.ASCII.GetString(header, 0, count - 4).Split("\r\n");
        var start = lines[0].Split(' ');
        if (start.Length < 2 || start[0] != "HTTP/1.1" || !int.TryParse(start[1], NumberStyles.None, CultureInfo.InvariantCulture, out var status) || status is < 200 or > 599) throw new IOException("Invalid HTTP status.");
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0 || line[0] is ' ' or '\t' || !fields.TryAdd(line[..colon], line[(colon + 1)..].Trim())) throw new IOException("Ambiguous HTTP response headers.");
        }
        if (fields.ContainsKey("Transfer-Encoding") || !fields.TryGetValue("Content-Length", out var lengthText) || !int.TryParse(lengthText, NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length > maximumBodyBytes) throw new IOException("A bounded Content-Length is required.");
        var body = new byte[length]; await stream.ReadExactlyAsync(body, cancellationToken).ConfigureAwait(false);
        return new TransferReply(status, body);
    }
    public async ValueTask DisposeAsync() { await stream.DisposeAsync().ConfigureAwait(false); tcp.Dispose(); }
}
