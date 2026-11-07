using System.Diagnostics.Tracing;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LimLink;

namespace LimLink.Core.Tests;

public class OpenSslTlsTests
{
    [Fact]
    public async Task X15_tls12_client_is_rejected_and_tls13_connects()
    {
        await using var node = await TestNodes.StartAsync();
        var directory = Directory.CreateTempSubdirectory("limlink-x15").FullName;
        try
        {
            using var clientCert = DeviceCertificate.Create();
            var (certificatePath, keyPath) = WritePem(clientCert, directory);
            var common = new[]
            {
                "-connect", $"127.0.0.1:{node.Node.Port}",
                "-cert", certificatePath,
                "-key", keyPath,
                "-alpn", "http/1.1",
                "-servername", "limlink",
            };

            var tls12 = await OpenSslTool.RunAsync(
                ["s_client", "-tls1_2", .. common],
                TimeSpan.FromSeconds(15));
            Assert.False(tls12.TimedOut, tls12.Output);
            Assert.NotEqual(0, tls12.ExitCode);
            Assert.DoesNotContain("CONNECTION ESTABLISHED", tls12.Output, StringComparison.Ordinal);
            Assert.Contains("alert", tls12.Output, StringComparison.OrdinalIgnoreCase);

            var tls13 = await OpenSslTool.RunAsync(
                ["s_client", "-tls1_3", "-brief", .. common],
                TimeSpan.FromSeconds(15));
            Assert.False(tls13.TimedOut, tls13.Output);
            Assert.Equal(0, tls13.ExitCode);
            Assert.Contains("TLSv1.3", tls13.Output, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task X16_client_rejects_tls12_server_and_accepts_tls13()
    {
        var directory = Directory.CreateTempSubdirectory("limlink-x16").FullName;
        try
        {
            using var serverCert = DeviceCertificate.Create();
            using var clientCert = DeviceCertificate.Create();
            var (certificatePath, keyPath) = WritePem(serverCert, directory);
            var expected = Fingerprint.Compute(serverCert);
            using var client = new LimLinkClient(new LimLinkClientOptions { Certificate = clientCert });

            await AssertHandshakeFailsAsync(certificatePath, keyPath, "-tls1_2", client, expected);
            await AssertHandshakeSucceedsAsync(certificatePath, keyPath, "-tls1_3", client, expected);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task X18_peer_certificate_alpn_and_session_is_not_resumed()
    {
        await using var node = await TestNodes.StartAsync();
        var directory = Directory.CreateTempSubdirectory("limlink-x18").FullName;
        try
        {
            using var clientCert = DeviceCertificate.Create();
            var (certificatePath, keyPath) = WritePem(clientCert, directory);
            var sessionPath = Path.Combine(directory, "session.pem");
            var common = new List<string>
            {
                "s_client",
                "-tls1_3",
                "-connect", $"127.0.0.1:{node.Node.Port}",
                "-cert", certificatePath,
                "-key", keyPath,
                "-alpn", "http/1.1",
                "-servername", "limlink",
            };

            var first = await OpenSslTool.RunAsync(
                [.. common, "-sess_out", sessionPath],
                TimeSpan.FromSeconds(15),
                stdin: "Q\n");
            Assert.False(first.TimedOut, first.Output);
            Assert.Equal(0, first.ExitCode);
            Assert.Contains("New,", first.Output, StringComparison.Ordinal);
            Assert.DoesNotContain("Reused,", first.Output, StringComparison.Ordinal);
            Assert.Contains("http/1.1", first.Output, StringComparison.Ordinal);
            Assert.Contains("limlink", first.Output, StringComparison.OrdinalIgnoreCase);

            if (File.Exists(sessionPath) && new FileInfo(sessionPath).Length > 0)
            {
                var second = await OpenSslTool.RunAsync(
                    [.. common, "-sess_in", sessionPath],
                    TimeSpan.FromSeconds(15),
                    stdin: "Q\n");
                Assert.False(second.TimedOut, second.Output);
                Assert.Contains("New,", second.Output, StringComparison.Ordinal);
                Assert.DoesNotContain("Reused,", second.Output, StringComparison.Ordinal);
            }
            else
            {
                var second = await OpenSslTool.RunAsync(common, TimeSpan.FromSeconds(15), stdin: "Q\n");
                Assert.False(second.TimedOut, second.Output);
                Assert.Contains("New,", second.Output, StringComparison.Ordinal);
                Assert.DoesNotContain("Reused,", second.Output, StringComparison.Ordinal);
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task AssertHandshakeFailsAsync(
        string certificatePath,
        string keyPath,
        string versionFlag,
        LimLinkClient client,
        string expectedFingerprint)
    {
        var port = await OpenSslTool.ReserveLoopbackPortAsync();
        using var server = OpenSslServer.Start(certificatePath, keyPath, port, versionFlag);
        await server.WaitUntilReadyAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var error = await Assert.ThrowsAsync<LimLinkConnectionException>(() =>
            client.HandshakeAsync("127.0.0.1", port, expectedFingerprint, timeout.Token));
        Assert.NotEqual(LimLinkConnectionFailure.FingerprintMismatch, error.Failure);
        Assert.True(
            error.Failure is LimLinkConnectionFailure.TlsHandshake or LimLinkConnectionFailure.ProtocolVersion,
            error.ToString());
    }

    private static async Task AssertHandshakeSucceedsAsync(
        string certificatePath,
        string keyPath,
        string versionFlag,
        LimLinkClient client,
        string expectedFingerprint)
    {
        var port = await OpenSslTool.ReserveLoopbackPortAsync();
        using var server = OpenSslServer.Start(certificatePath, keyPath, port, versionFlag);
        await server.WaitUntilReadyAsync();
        if (versionFlag == "-tls1_3")
        {
            var probe = await OpenSslTool.RunAsync(
                [
                    "s_client", "-tls1_3", "-connect", $"127.0.0.1:{port}",
                    "-cert", certificatePath, "-key", keyPath,
                    "-alpn", "http/1.1", "-servername", "limlink", "-brief",
                ],
                TimeSpan.FromSeconds(10),
                stdin: "Q\n");
            if (probe.TimedOut || probe.ExitCode != 0 || !probe.Output.Contains("TLSv1.3", StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "openssl s_client could not complete TLS 1.3 with s_server.\n"
                    + probe.Output
                    + "\nserver:\n"
                    + server.Transcript());
            }
        }

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        TlsHandshakeInfo info;
        using var sslLog = new SecurityEventLog();
        try
        {
            info = await client.HandshakeAsync("127.0.0.1", port, expectedFingerprint, timeout.Token);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "openssl s_server output:\n" + server.Transcript() + "\nsecurity events:\n" + sslLog.Text(),
                ex);
        }
        Assert.Equal(System.Security.Authentication.SslProtocols.Tls13, info.Protocol);
        Assert.Contains("limlink", info.RemoteSubject, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(expectedFingerprint, info.RemoteFingerprint);
    }

    private static (string CertificatePath, string KeyPath) WritePem(X509Certificate2 certificate, string directory)
    {
        var certificatePath = Path.Combine(directory, "cert.pem");
        var keyPath = Path.Combine(directory, "key.pem");
        File.WriteAllText(certificatePath, certificate.ExportCertificatePem());
        using var key = certificate.GetECDsaPrivateKey();
        Assert.NotNull(key);
        File.WriteAllText(keyPath, key.ExportPkcs8PrivateKeyPem());
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(keyPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }

        return (certificatePath, keyPath);
    }
}

internal sealed class OpenSslServer : IDisposable
{
    private readonly System.Diagnostics.Process _process;
    private readonly StringBuilder _output = new();
    private readonly object _gate = new();

    private OpenSslServer(System.Diagnostics.Process process)
    {
        _process = process;
    }

    public static OpenSslServer Start(string certificatePath, string keyPath, int port, string versionFlag)
    {
        var start = new System.Diagnostics.ProcessStartInfo(OpenSslTool.Executable())
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        // Bind every IPv4 interface by port only. OpenSSL 3.6 on Windows did not
        // complete a handshake, even for s_client, when given a host:port accept
        // address plus a custom OPENSSL_CONF.
        foreach (var argument in new[]
                 {
                     "s_server", "-4", versionFlag,
                     "-cert", certificatePath, "-key", keyPath,
                     "-accept", port.ToString(System.Globalization.CultureInfo.InvariantCulture),
                     "-alpn", "http/1.1",
                     "-Verify", "1",
                     "-no_ticket",
                     // www_body handshakes from the accepted socket. The default
                     // sv_body on Windows treats any redirected, non-EOF stdin as
                     // ready (has_stdin_waiting) and blocks in raw_read_stdin
                     // before init_ssl_connection. Closing that pipe is EOF and
                     // OpenSSL quits with "DONE" / 0 server accepts. -www does
                     // not read stdin, so the pipe stays open and unused.
                     "-www",
                 })
        {
            start.ArgumentList.Add(argument);
        }

        var process = new System.Diagnostics.Process { StartInfo = start };
        process.Start();

        var server = new OpenSslServer(process);
        _ = server.PumpAsync(process.StandardOutput);
        _ = server.PumpAsync(process.StandardError);
        return server;
    }

    public async Task WaitUntilReadyAsync()
    {
        // "ACCEPT" is printed when s_server enters its accept loop, before any
        // client connects. A TCP probe would occupy that single-threaded accept
        // and the following handshake would wait until OpenSSL gave up on it.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            if (_process.HasExited)
            {
                throw new InvalidOperationException("openssl s_server exited early: " + Output());
            }

            if (Output().Contains("ACCEPT", StringComparison.Ordinal))
            {
                return;
            }

            await Task.Delay(50);
        }

        throw new TimeoutException("openssl s_server did not become ready: " + Output());
    }

    public void Dispose()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }

        _process.Dispose();
    }

    private async Task PumpAsync(StreamReader reader)
    {
        var buffer = new char[256];
        while (true)
        {
            int read;
            try
            {
                read = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
            }
            catch (ObjectDisposedException)
            {
                return;
            }

            if (read == 0)
            {
                return;
            }

            lock (_gate)
            {
                _output.Append(buffer, 0, read);
            }
        }
    }

    public string Transcript() => Output();

    private string Output()
    {
        lock (_gate)
        {
            return _output.ToString();
        }
    }
}

internal sealed class SecurityEventLog : EventListener
{
    private readonly StringBuilder _text = new();

    protected override void OnEventSourceCreated(EventSource eventSource)
    {
        if (eventSource.Name.Contains("Security", StringComparison.Ordinal)
            || eventSource.Name.Contains("Ssl", StringComparison.Ordinal))
        {
            EnableEvents(eventSource, EventLevel.Verbose, EventKeywords.All);
        }
    }

    protected override void OnEventWritten(EventWrittenEventArgs eventData)
    {
        lock (_text)
        {
            _text.Append(eventData.EventSource.Name);
            _text.Append(' ');
            _text.Append(eventData.EventName);
            if (eventData.Payload is { Count: > 0 })
            {
                _text.Append(' ');
                _text.Append(string.Join(", ", eventData.Payload));
            }

            _text.AppendLine();
        }
    }

    public string Text()
    {
        lock (_text)
        {
            return _text.ToString();
        }
    }
}
