using LimLink;
namespace LimLink.Core.Tests;

public sealed class WindowsTransferTests
{
    [Fact]
    public async Task Real_mutual_TLS_transfer_waits_for_consent_and_publishes_exact_bytes()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("Requires Windows TLS 1.3; macOS SslStream does not support TLS 1.3.");
        using var temp = new TempDirectory();
        var sourcePath = Path.Combine(temp.Path, "source.bin");
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(2_097_169);
        await File.WriteAllBytesAsync(sourcePath, bytes);
        var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var offered = new TaskCompletionSource<IncomingOffer>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var receiver = await LimLinkNode.StartAsync(new LimLinkNodeOptions
        {
            DataDirectory = Path.Combine(temp.Path, "receiver"), ExplicitPort = 0, DeviceAlias = "Receiver",
            ConfirmReceive = async (offer, ct) => { offered.TrySetResult(offer); return await decision.Task.WaitAsync(ct); }
        });
        using var cert = DeviceCertificate.Create();
        using var sender = new LimLinkClient(new LimLinkClientOptions { Certificate = cert, Alias = "Sender name" });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var task = sender.SendFileAsync(new DiscoveryPeer("Receiver", "127.0.0.1", receiver.Port, receiver.Fingerprint, "windows", "limlink"), sourcePath, Path.Combine(temp.Path, "snapshots"), cancellationToken: timeout.Token);
        var offer = await offered.Task.WaitAsync(timeout.Token);
        Assert.Equal("Sender name", offer.SenderName);
        Assert.False(task.IsCompleted);
        Assert.Empty(Directory.GetFiles(Path.Combine(temp.Path, "receiver", "Received")));
        decision.SetResult(true);
        var result = await task;
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(temp.Path, "receiver", "Received", result.FinalName)));
        Assert.Equal(bytes.Length, result.Size);
    }

    [Fact]
    public async Task Real_pair_connection_and_matching_hello_enable_auto_receive_then_unbind_restores_prompt()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("Requires Windows TLS 1.3 and CurrentUser DPAPI.");
        using var temp = new TempDirectory();
        var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var notified = new TaskCompletionSource<BindingOffer>(TaskCreationOptions.RunContinuationsAsynchronously);
        var prompts = 0;
        await using var recipient = await LimLinkNode.StartAsync(new LimLinkNodeOptions { DataDirectory=Path.Combine(temp.Path,"recipient"),ExplicitPort=0,DeviceAlias="Recipient",ConfirmBinding=async(offer,ct)=>{notified.SetResult(offer);return await consent.Task.WaitAsync(ct);},ConfirmReceive=(_,_)=>{Interlocked.Increment(ref prompts);return Task.FromResult(false);} });
        await using var caller = await LimLinkNode.StartAsync(new LimLinkNodeOptions { DataDirectory=Path.Combine(temp.Path,"caller"),ExplicitPort=0,DeviceAlias="Caller" });
        using var client=caller.CreateClient();using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var peer=new DiscoveryPeer("Recipient","127.0.0.1",recipient.Port,recipient.Fingerprint,"windows","limlink");
        var pairing=client.BindAsync(peer,cancellationToken:timeout.Token);
        await notified.Task.WaitAsync(timeout.Token);Assert.Empty(caller.Binding.Bindings);Assert.Empty(recipient.Binding.Bindings);Assert.False(pairing.IsCompleted);
        consent.SetResult(true);await pairing;
        Assert.Equal(caller.Binding.BindingIdFor(recipient.Fingerprint),recipient.Binding.BindingIdFor(caller.Fingerprint));
        var source=Path.Combine(temp.Path,"automatic.txt");await File.WriteAllTextAsync(source,"automatic receive proof");
        await client.SendFileAsync(peer,source,Path.Combine(temp.Path,"scratch"),cancellationToken:timeout.Token);Assert.Equal(0,prompts);
        Assert.True(await client.UnbindAsync(recipient.Fingerprint,peer,timeout.Token));
        var error=await Assert.ThrowsAsync<TransferException>(()=>client.SendFileAsync(peer,source,Path.Combine(temp.Path,"scratch"),cancellationToken:timeout.Token));
        Assert.Equal("E_REJECTED",error.Code);Assert.Equal(1,prompts);
    }
}

public sealed class WindowsAddressCandidateTests
{
    [Fact]
    public async Task A_stale_address_with_a_different_certificate_does_not_hide_the_pinned_candidate()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("Requires Windows TLS 1.3 and CurrentUser DPAPI.");
        using var temp = new TempDirectory();
        var wrongPrompts = 0;
        await using var correct = await LimLinkNode.StartAsync(new LimLinkNodeOptions
        {
            DataDirectory = Path.Combine(temp.Path, "correct"), ExplicitPort = 0,
            ListenAddress = System.Net.IPAddress.Parse("127.0.0.2"), ConfirmReceive = (_, _) => Task.FromResult(true),
        });
        await using var wrong = await LimLinkNode.StartAsync(new LimLinkNodeOptions
        {
            DataDirectory = Path.Combine(temp.Path, "wrong"), ExplicitPort = correct.Port,
            ListenAddress = System.Net.IPAddress.Parse("127.0.0.1"),
            ConfirmReceive = (_, _) => { Interlocked.Increment(ref wrongPrompts); return Task.FromResult(true); },
        });
        var source = Path.Combine(temp.Path, "proof.txt");
        await File.WriteAllTextAsync(source, "only the pinned recipient receives this");
        using var certificate = DeviceCertificate.Create();
        using var sender = new LimLinkClient(new LimLinkClientOptions { Certificate = certificate });
        var peer = new DiscoveryPeer("Correct", "127.0.0.1", correct.Port, correct.Fingerprint, "windows", "limlink")
        { AddressCandidates = new[] { "127.0.0.1", "127.0.0.2" } };
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var result = await sender.SendFileAsync(peer, source, Path.Combine(temp.Path, "snapshots"), cancellationToken: timeout.Token);
        Assert.Equal("only the pinned recipient receives this", await File.ReadAllTextAsync(Path.Combine(temp.Path, "correct", "Received", result.FinalName)));
        Assert.Equal(0, wrongPrompts);
        Assert.Empty(Directory.GetFiles(Path.Combine(temp.Path, "wrong", "Received")));
    }
}
