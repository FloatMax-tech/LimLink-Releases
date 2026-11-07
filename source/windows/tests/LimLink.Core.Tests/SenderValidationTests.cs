using System.Text;
using System.Text.Json;
using LimLink;

namespace LimLink.Core.Tests;
public sealed class SenderValidationTests
{
    [Theory]
    [InlineData("{\"committedBytes\":2}")]
    [InlineData("{\"committedBytes\":4}")]
    [InlineData("{\"committedBytes\":3.0}")]
    [InlineData("{\"committedBytes\":\"3\"}")]
    [InlineData("{\"committedBytes\":true}")]
    public void Sender_rejects_inexact_or_noninteger_ACK(string json) => Assert.Throws<TransferException>(() => TransferResponseValidator.Ack(JsonSerializer.Deserialize<JsonElement>(json), 3));

    [Fact]
    public void Sender_accepts_exact_64bit_ACK() => TransferResponseValidator.Ack(JsonSerializer.Deserialize<JsonElement>("{\"committedBytes\":5000000000}"), 5_000_000_000L);

    [Theory]
    [InlineData("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")]
    [InlineData("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}")]
    [InlineData("HTTP/1.1 200 OK\r\nContent-Length: 65537\r\n\r\n")]
    [InlineData("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n{}")]
    public async Task Http_reader_rejects_ambiguous_oversized_and_truncated_frames(string frame)
    {
        using var stream = new MemoryStream(Encoding.ASCII.GetBytes(frame));
        await Assert.ThrowsAnyAsync<IOException>(() => TransferHttp.ReadResponseAsync(stream, default));
    }

    [Fact]
    public async Task Http_reader_preserves_next_response_on_connection()
    {
        using var stream = new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\n\r\n{}"));
        Assert.Equal(200, (await TransferHttp.ReadResponseAsync(stream, default)).Status);
        Assert.Equal(202, (await TransferHttp.ReadResponseAsync(stream, default)).Status);
    }

    [Fact]
    public async Task Binding_reader_rejects_oversized_control_reply_before_reading_body()
    {
        var header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 16385\r\n\r\n");
        using var stream = new MemoryStream(header.Concat(new byte[16_385]).ToArray());
        await Assert.ThrowsAsync<IOException>(() => TransferHttp.ReadResponseAsync(stream, default, 16_384));
        Assert.Equal(header.Length, stream.Position);
    }

    [Fact]
    public async Task Control_boundary_is_allowed_and_file_reply_limit_is_preserved()
    {
        var controlHeader = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 16384\r\n\r\n");
        using var control = new MemoryStream(controlHeader.Concat(new byte[16_384]).ToArray());
        Assert.Equal(16_384, (await TransferHttp.ReadResponseAsync(control, default, 16_384)).Body.Length);
        var fileHeader = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n\r\n");
        using var file = new MemoryStream(fileHeader.Concat(new byte[65_536]).ToArray());
        Assert.Equal(65_536, (await TransferHttp.ReadResponseAsync(file, default)).Body.Length);
    }
    [Theory]
    [InlineData("false", "completed", "3", "saved.txt")]
    [InlineData("true", "failed", "3", "saved.txt")]
    [InlineData("true", "completed", "2", "saved.txt")]
    [InlineData("true", "completed", "3", "other.txt")]
    public void Sender_rejects_inconsistent_final_report(string match, string state, string size, string name)
    {
        var json = $$"""{"sessionId":"sid","state":"finished","files":[{"id":"file","state":"{{state}}","size":{{size}},"bytesReceived":3,"finalName":"{{name}}","sha256Match":{{match}}}]}""";
        Assert.Throws<TransferException>(() => TransferResponseValidator.Finish(JsonSerializer.Deserialize<JsonElement>(json), "sid", "file", 3, "saved.txt"));
    }
    [Theory]
    [InlineData("{\"token\":\"secret\",\"offset\":0,\"accept\":false}")]
    [InlineData("{\"token\":\"secret\",\"offset\":0}")]
    [InlineData("{\"token\":\"secret\",\"offset\":0,\"accept\":\"true\"}")]
    public void Sender_requires_explicit_true_accept_before_sending(string json) =>
        Assert.Throws<TransferException>(() => TransferResponseValidator.AcceptedFile(JsonSerializer.Deserialize<JsonElement>(json)));

    [Fact]
    public void Sender_accepts_explicit_consent_at_offset_zero() =>
        Assert.Equal("secret", TransferResponseValidator.AcceptedFile(JsonSerializer.Deserialize<JsonElement>("{\"token\":\"secret\",\"offset\":0,\"accept\":true}")));
    [Theory]
    [InlineData("POST", "/limlink/v1/sessions/session/files/file/complete", 1800)]
    [InlineData("POST", "/limlink/v1/sessions/session/files/file/complete?wait=1", 1800)]
    [InlineData("GET", "/limlink/v1/sessions/session/files/file/complete", 120)]
    [InlineData("PUT", "/limlink/v1/sessions/session/files/file", 120)]
    [InlineData("POST", "/limlink/v1/sessions/session/finish", 120)]
    [InlineData("POST", "/limlink/v1/hello", 120)]
    [InlineData("POST", "/limlink/v1/sessions/session/files/file/complete/extra", 120)]
    public void Only_file_completion_allows_slow_durable_publication(string method, string path, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), TransferHttp.ResponseTimeout(method, path));

    [Fact]
    public async Task Cancelling_file_completion_interrupts_wait_without_waiting_for_publication_budget()
    {
        using var caller = new CancellationTokenSource();
        using var timeout = TransferHttp.CreateRequestTimeout("POST", "/limlink/v1/sessions/session/files/file/complete", caller.Token);
        using var stream = new CancellationOnlyReadStream();
        var response = TransferHttp.ReadResponseAsync(stream, timeout.Token);
        Assert.False(response.IsCompleted);
        caller.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => response.WaitAsync(TimeSpan.FromSeconds(2)));
    }
}

internal sealed class CancellationOnlyReadStream : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() => throw new NotSupportedException();
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        await Task.Delay(Timeout.Infinite, cancellationToken);
        return 0;
    }
}
