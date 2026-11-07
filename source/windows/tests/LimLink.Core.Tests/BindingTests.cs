using LimLink;
using Microsoft.AspNetCore.Http;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography.X509Certificates;
namespace LimLink.Core.Tests;
public sealed class BindingTests
{
    [Fact]
    public async Task Pair_start_is_production_route_and_rejects_missing_version()
    {
        using var cert = DeviceCertificate.Create();
        using var caller = DeviceCertificate.Create();
        using var binding = new DeviceBindingService(Fingerprint.Compute(cert), "receiver", "windows", new MemoryBindings());
        var options = new LimLinkServerOptions { Certificate = cert, Alias = "receiver", AppPolicy = new PeerAppPolicy("limlink"), Binding = binding };
        var server = (LimLinkServer)RuntimeHelpers.GetUninitializedObject(typeof(LimLinkServer));
        var context = new DefaultHttpContext();
        context.Request.Method = "POST"; context.Request.Path = "/limlink/v1/pair/start";
        context.Request.Headers[LimLinkProtocol.HeaderApp] = "limlink";
        context.Request.Body = new MemoryStream("{}"u8.ToArray()); context.Request.ContentLength = 2;
        context.Connection.ClientCertificate = caller; context.Connection.Id = "pair-test";
        context.Response.Body = new MemoryStream();
        await (Task)typeof(LimLinkServer).GetMethod("HandleAsync", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(server, [context, options])!;
        var json = System.Text.Json.JsonDocument.Parse(((MemoryStream)context.Response.Body).ToArray());
        Assert.Equal("E_PAIR_VERSION", json.RootElement.GetProperty("code").GetString());
    }

    [Fact]
    public async Task Actual_control_dispatch_uses_certificate_identity_through_completion()
    {
        using var own = DeviceCertificate.Create(); using var caller = DeviceCertificate.Create(); using var intruder = DeviceCertificate.Create();
        var store = new MemoryBindings();
        using var binding = new DeviceBindingService(Fingerprint.Compute(own),"Receiver","windows",store,(_,_) => Task.FromResult(true));
        var options = new LimLinkServerOptions { Certificate=own, Alias="Receiver", AppPolicy=new PeerAppPolicy("limlink"), Binding=binding };
        var server = (LimLinkServer)RuntimeHelpers.GetUninitializedObject(typeof(LimLinkServer));
        async Task<TransferReply> Route(string method,string path,byte[] bytes,Dictionary<string,string>? headers=null,X509Certificate2? certificate=null)
        {
            var context = new DefaultHttpContext(); context.Request.Method=method; context.Request.Path=path;
            context.Request.Headers[LimLinkProtocol.HeaderApp]="limlink"; if(headers is not null) foreach(var header in headers) context.Request.Headers[header.Key]=header.Value;
            context.Request.Body=new MemoryStream(bytes);context.Request.ContentLength=bytes.Length;context.Response.Body=new MemoryStream();context.Connection.ClientCertificate=certificate??caller;context.Connection.Id="wire";
            await (Task)typeof(LimLinkServer).GetMethod("HandleAsync",BindingFlags.NonPublic|BindingFlags.Instance)!.Invoke(server,[context,options])!;
            return new(context.Response.StatusCode,((MemoryStream)context.Response.Body).ToArray());
        }
        var start=await Route("POST","/limlink/v1/pair/start",Json(new{version=1,requestId=Guid.NewGuid().ToString("D"),alias="Caller",deviceType="windows"})); Assert.Equal(202,start.Status);
        var id=start.Json.GetProperty("pairId").GetString()!;var path="/limlink/v1/pair/"+id;var token=Token(start);
        Assert.Equal(403,(await Route("GET",path,[],token,intruder)).Status);
        await WaitAccepted(binding,new("wire",Fingerprint.Compute(caller)),path,token);
        Assert.Equal(200,(await Route("POST",path+"/complete","{}"u8.ToArray(),token)).Status);
        Assert.True(binding.Authorizes(Fingerprint.Compute(caller),id)); Assert.False(binding.Authorizes(Fingerprint.Compute(intruder),id));
        Assert.Equal(200,(await Route("POST",path+"/cancel","{}"u8.ToArray(),token)).Status); Assert.Empty(store.Records);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Production_dispatch_rejects_mixing_pairing_and_files_on_one_connection(bool pairFirst)
    {
        using var own = DeviceCertificate.Create();
        using var caller = DeviceCertificate.Create();
        using var binding = new DeviceBindingService(Fingerprint.Compute(own), "Receiver", "windows", new MemoryBindings());
        var directory = Directory.CreateTempSubdirectory("binding-mode").FullName;
        try
        {
            using var receiver = new TransferReceiver(directory, "Receiver", new PeerAppPolicy("limlink"), (_, _) => Task.FromResult(false));
            var options = new LimLinkServerOptions { Certificate = own, Alias = "Receiver", AppPolicy = new PeerAppPolicy("limlink"), Binding = binding, Receiver = receiver };
            var server = (LimLinkServer)RuntimeHelpers.GetUninitializedObject(typeof(LimLinkServer));
            async Task<TransferReply> Route(bool pairing)
            {
                var context = new DefaultHttpContext();
                context.Request.Method = "POST";
                context.Request.Path = pairing ? "/limlink/v1/pair/start" : LimLinkProtocol.HelloPath;
                context.Request.Headers[LimLinkProtocol.HeaderApp] = "limlink";
                var bytes = pairing
                    ? Json(new { version = 1, requestId = Guid.NewGuid().ToString("D"), alias = "Caller", deviceType = "windows" })
                    : Json(new { proto = new[] { "1.0" }, alias = "Caller", app = "limlink" });
                context.Request.Body = new MemoryStream(bytes);
                context.Request.ContentLength = bytes.Length;
                context.Response.Body = new MemoryStream();
                context.Connection.ClientCertificate = caller;
                context.Connection.Id = "mixed-wire";
                await (Task)typeof(LimLinkServer).GetMethod("HandleAsync", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(server, [context, options])!;
                return new(context.Response.StatusCode, ((MemoryStream)context.Response.Body).ToArray());
            }
            Assert.Equal(pairFirst ? 202 : 200, (await Route(pairFirst)).Status);
            var rejected = await Route(!pairFirst);
            Assert.Equal(409, rejected.Status);
            Assert.Equal("E_INVALID_STATE", rejected.Json.GetProperty("code").GetString());
        }
        finally { Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task Monotonic_deadline_rate_limit_and_exact_revoke_fail_closed()
    {
        var clock = new BindingClock();var peer=new PeerConnection("clock",Peer);
        using var service = new DeviceBindingService(Own,"Receiver","windows",new MemoryBindings(),(_,_) => Task.FromResult(true),clock);
        var start=await Start(service,peer);var path="/limlink/v1/pair/"+start.Json.GetProperty("pairId").GetString();
        Assert.Equal(409,(await Start(service,new("competitor",Peer))).Status);
        clock.Advance(TimeSpan.FromSeconds(121));
        Assert.Equal(410,(await service.HandleAsync(peer,"POST",path+"/complete",Token(start),"{}"u8.ToArray())).Status);Assert.Null(service.BindingIdFor(Peer));
        for(var i=0;i<3;i++){start=await Start(service,peer);Assert.Equal(202,start.Status);path="/limlink/v1/pair/"+start.Json.GetProperty("pairId").GetString();await service.HandleAsync(peer,"POST",path+"/cancel",Token(start),"{}"u8.ToArray());}
        Assert.Equal(429,(await Start(service,peer)).Status);
        var newer=Guid.NewGuid().ToString("D");var store=new MemoryBindings{Records=[new(Own,Peer,newer,"Caller","windows",DateTimeOffset.UtcNow)]};
        using var current=new DeviceBindingService(Own,"Receiver","windows",store);
        await current.HandleAsync(peer,"POST","/limlink/v1/pair/"+Guid.NewGuid().ToString("D")+"/revoke",Headers,"{}"u8.ToArray());Assert.True(current.Authorizes(Peer,newer));
    }
    [Fact]
    public async Task Unmatched_remote_revoke_does_not_cancel_an_unrelated_outgoing_binding()
    {
        var otherPeer = new string('C', 42) + "A";
        var oldId = Guid.NewGuid().ToString("D");
        var store = new MemoryBindings { Records = [new(Own, otherPeer, oldId, "Other", "windows", DateTimeOffset.UtcNow)] };
        using var binding = new DeviceBindingService(Own, "Caller", "windows", store);
        var generation = binding.BeginOutgoing();
        var reply = await binding.HandleAsync(new PeerConnection("foreign", otherPeer), "POST", "/limlink/v1/pair/" + Guid.NewGuid().ToString("D") + "/revoke", Headers, "{}"u8.ToArray());
        Assert.Equal(200, reply.Status);
        var id = Guid.NewGuid().ToString("D");
        binding.SaveOutgoing(generation, Peer, id, "Receiver", "windows", CancellationToken.None);
        Assert.True(binding.Authorizes(Peer, id));
        Assert.True(binding.Authorizes(otherPeer, oldId));
        binding.EndOutgoing();
    }

    [Fact]
    public void Private_atomic_store_reloads_and_corruption_or_write_failure_is_closed()
    {
        var directory=Directory.CreateTempSubdirectory("binding-store").FullName;
        try
        {
            var path=Path.Combine(directory,"bindings.bin");var protector=new TestEncryption();var store=new PrivateBindingStore(path,protector);var id=Guid.NewGuid().ToString("D");
            store.Write([new(Own,Peer,id,"Caller","windows",DateTimeOffset.UtcNow)]);
            using(var loaded=new DeviceBindingService(Own,"Receiver","windows",store)) Assert.True(loaded.Authorizes(Peer,id));
            Assert.DoesNotContain("Caller",System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)));
            File.WriteAllBytes(path,[1,2,3]);using(var corrupt=new DeviceBindingService(Own,"Receiver","windows",store)){Assert.Empty(corrupt.Bindings);Assert.NotNull(corrupt.StorageError);}
            var memory=new MemoryBindings{Records=[new(Own,Peer,id,"Caller","windows",DateTimeOffset.UtcNow)],Fail=true};
            using var service=new DeviceBindingService(Own,"Receiver","windows",memory);Assert.Throws<IOException>(()=>service.Unbind(Peer));Assert.False(service.Authorizes(Peer,id));
        }
        finally{Directory.Delete(directory,true);}
    }
    private const string Own = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private const string Peer = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA";
    private static readonly Dictionary<string,string> Headers = new();
    private static byte[] Json(object body) => System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(body);
    private static Task<TransferReply> Start(DeviceBindingService service, PeerConnection peer, string? request = null) => service.HandleAsync(peer, "POST", "/limlink/v1/pair/start", Headers, Json(new { version = 1, requestId = request ?? Guid.NewGuid().ToString("D"), alias = "Caller", deviceType = "windows" }));
    private static Dictionary<string,string> Token(TransferReply start) => new() { ["X-LimLink-Pair-Token"] = start.Json.GetProperty("token").GetString()! };
    private static async Task WaitAccepted(DeviceBindingService service, PeerConnection peer, string path, Dictionary<string,string> token)
    {
        for (var i = 0; i < 100; i++) { if ((await service.HandleAsync(peer, "GET", path, token, ReadOnlyMemory<byte>.Empty)).Json.GetProperty("state").GetString() == "accepted") return; await Task.Delay(5); }
        Assert.Fail("Responder consent did not settle.");
    }
    [Fact]
    public async Task Consent_is_recipient_only_token_owner_scoped_and_complete_is_durable()
    {
        var store = new MemoryBindings(); var consent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var service = new DeviceBindingService(Own,"Receiver","windows",store,(_,_) => consent.Task);
        var peer = new PeerConnection("connection",Peer); var request = Guid.NewGuid().ToString("D");
        var start = await Start(service,peer,request); Assert.Equal(202,start.Status);
        var id = start.Json.GetProperty("pairId").GetString()!; var path = "/limlink/v1/pair/" + id; var token = Token(start);
        Assert.Equal(start.Json.GetProperty("token").GetString(),(await Start(service,peer,request)).Json.GetProperty("token").GetString());
        Assert.Equal(409,(await service.HandleAsync(peer,"POST",path+"/complete",token,"{}"u8.ToArray())).Status);
        Assert.Equal(403,(await service.HandleAsync(new("other",Peer),"GET",path,token,ReadOnlyMemory<byte>.Empty)).Status);
        Assert.Equal(403,(await service.HandleAsync(peer,"GET",path,Headers,ReadOnlyMemory<byte>.Empty)).Status);
        Assert.Empty(store.Records); Assert.False(service.Authorizes(Peer,id));
        consent.SetResult(true); await WaitAccepted(service,peer,path,token); Assert.Empty(store.Records);
        Assert.Equal(200,(await service.HandleAsync(peer,"POST",path+"/complete",token,"{}"u8.ToArray())).Status);
        Assert.True(service.Authorizes(Peer,id));
        using var reload = new DeviceBindingService(Own,"Renamed","windows",store); Assert.True(reload.Authorizes(Peer,id));
        using var reset = new DeviceBindingService(new string('C',42)+"A","Other key","windows",store); Assert.False(reset.Authorizes(Own,id)); Assert.Null(reset.StorageError);
        await service.HandleAsync(peer,"POST",path+"/revoke",Headers,"{}"u8.ToArray());
        Assert.False(service.Authorizes(Peer,id)); Assert.Equal(409,(await service.HandleAsync(peer,"POST",path+"/complete",token,"{}"u8.ToArray())).Status);
    }
    [Fact]
    public async Task Storage_failure_and_disconnect_never_authorize_late_consent()
    {
        var store = new MemoryBindings { Fail = true };
        using var service = new DeviceBindingService(Own,"Receiver","windows",store,(_,_) => Task.FromResult(true));
        var peer = new PeerConnection("connection",Peer); var start = await Start(service,peer); var path = "/limlink/v1/pair/"+start.Json.GetProperty("pairId").GetString(); var token = Token(start);
        await WaitAccepted(service,peer,path,token);
        Assert.Equal(500,(await service.HandleAsync(peer,"POST",path+"/complete",token,"{}"u8.ToArray())).Status); Assert.Null(service.BindingIdFor(Peer));
        var delayed = new TaskCompletionSource<bool>(); using var other = new DeviceBindingService(Own,"Receiver","windows",new MemoryBindings(),(_,_) => delayed.Task);
        start = await Start(other,peer); path = "/limlink/v1/pair/"+start.Json.GetProperty("pairId").GetString(); other.Disconnect(peer.ConnectionId); delayed.SetResult(true);
        Assert.Equal(409,(await other.HandleAsync(peer,"POST",path+"/complete",Token(start),"{}"u8.ToArray())).Status); Assert.Null(other.BindingIdFor(Peer));
    }
    [Fact]
    public async Task Rejection_and_cancelled_outgoing_generation_do_not_grant_permission()
    {
        var store=new MemoryBindings();using var binding=new DeviceBindingService(Own,"Receiver","windows",store,(_,_)=>Task.FromResult(false));var peer=new PeerConnection("rejected",Peer);
        var start=await Start(binding,peer);var path="/limlink/v1/pair/"+start.Json.GetProperty("pairId").GetString();
        for(var i=0;i<100;i++){var reply=await binding.HandleAsync(peer,"GET",path,Token(start),ReadOnlyMemory<byte>.Empty);if(reply.Json.GetProperty("state").GetString()=="rejected")break;await Task.Delay(5);}
        Assert.Equal(409,(await binding.HandleAsync(peer,"POST",path+"/complete",Token(start),"{}"u8.ToArray())).Status);Assert.Empty(store.Records);
        var generation=binding.BeginOutgoing();binding.Unbind(Peer);
        Assert.Throws<TransferException>(()=>binding.SaveOutgoing(generation,Peer,Guid.NewGuid().ToString("D"),"Caller","windows",CancellationToken.None));Assert.Empty(store.Records);binding.EndOutgoing();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Cancellation_or_generation_change_during_persistence_rolls_back_only_new_binding(bool cancelToken)
    {
        var otherPeer = new string('C', 42) + "A";
        var otherId = Guid.NewGuid().ToString("D");
        var store = new MemoryBindings { Records = [new(Own, otherPeer, otherId, "Other device", "windows", DateTimeOffset.UtcNow)] };
        using var cancellation = new CancellationTokenSource();
        using var binding = new DeviceBindingService(Own, "Caller", "windows", store);
        var generation = binding.BeginOutgoing();
        var id = Guid.NewGuid().ToString("D");
        store.AfterWrite = () =>
        {
            if (cancelToken) cancellation.Cancel();
            else binding.Unbind(Peer);
        };

        if (cancelToken)
            Assert.Throws<OperationCanceledException>(() => binding.SaveOutgoing(generation, Peer, id, "Receiver", "windows", cancellation.Token));
        else
            Assert.Equal("E_PAIR_EXPIRED", Assert.Throws<TransferException>(() => binding.SaveOutgoing(generation, Peer, id, "Receiver", "windows", cancellation.Token)).Code);

        Assert.False(binding.Authorizes(Peer, id));
        Assert.True(binding.Authorizes(otherPeer, otherId));
        Assert.Single(store.Records);
        using var reloaded = new DeviceBindingService(Own, "Caller", "windows", store);
        Assert.False(reloaded.Authorizes(Peer, id));
        Assert.True(reloaded.Authorizes(otherPeer, otherId));
        binding.EndOutgoing();
    }
    [Fact]
    public async Task Hello_binding_must_match_current_record_and_unbind_changes_next_offer()
    {
        var id = Guid.NewGuid().ToString("D"); var store = new MemoryBindings { Records = [new(Own,Peer,id,"Caller","windows",DateTimeOffset.UtcNow)] };
        using var binding = new DeviceBindingService(Own,"Receiver","windows",store);
        var directory = Directory.CreateTempSubdirectory("binding-hello").FullName; var prompts = 0;
        try
        {
            using var receiver = new TransferReceiver(directory,"Receiver",new PeerAppPolicy("limlink"),(_,_) => { Interlocked.Increment(ref prompts); return Task.FromResult(false); }) { Binding = binding };
            var peer = new PeerConnection("actual-connection",Peer); var headers = new Dictionary<string,string> { [LimLinkProtocol.HeaderApp] = "limlink" };
            async Task<string> Offer(string connection, string? claimed)
            {
                var owner = new PeerConnection(connection,Peer);
                var hello = await receiver.HandleAsync(owner,"POST",LimLinkProtocol.HelloPath,headers,Json(new { proto = new[]{"1.0"}, alias = "Caller", app = "limlink", bindingId = claimed })); Assert.Equal(200,hello.Status);
                var offer = await receiver.HandleAsync(owner,"POST","/limlink/v1/sessions",headers,Json(new { clientSessionKey = Guid.NewGuid().ToString(), transport = "lan", totalEntries = 1, totalBytes = 0, entries = new[]{new {id="file",kind="file",relativePath="test.txt",size=0}} })); Assert.Equal(202,offer.Status);
                await Task.Delay(30); return offer.Json.GetProperty("sessionId").GetString()!;
            }
            var sid = await Offer(peer.ConnectionId,id); Assert.Equal(0,prompts);
            Assert.Equal(200,(await receiver.HandleAsync(peer,"GET","/limlink/v1/sessions/"+sid,headers,ReadOnlyMemory<byte>.Empty)).Status);
            await receiver.DisconnectAsync(peer.ConnectionId);
            await Offer("legacy",null); Assert.Equal(1,prompts); await receiver.DisconnectAsync("legacy");
            await receiver.HandleAsync(new("existing",Peer),"POST",LimLinkProtocol.HelloPath,headers,Json(new { proto=new[]{"1.0"},alias="Caller",app="limlink",bindingId=id }));
            binding.Unbind(Peer);
            var create = await receiver.HandleAsync(new("existing",Peer),"POST","/limlink/v1/sessions",headers,Json(new {clientSessionKey="next",transport="lan",totalEntries=1,totalBytes=0,entries=new[]{new{id="file",kind="file",relativePath="next.txt",size=0}}}));
            Assert.Equal(202,create.Status); await Task.Delay(30); Assert.Equal(2,prompts);
        }
        finally { Directory.Delete(directory,true); }
    }

    [Theory]
    [InlineData("limlink", "casecheck")]
    [InlineData("casecheck", "limlink")]
    public async Task Binding_permission_cannot_cross_host_app_boundary(string hostApp, string peerApp)
    {
        var id = Guid.NewGuid().ToString("D");
        var store = new MemoryBindings { Records = [new(Own, Peer, id, "Caller", "windows", DateTimeOffset.UtcNow)] };
        using var binding = new DeviceBindingService(Own, "Receiver", "windows", store);
        var directory = Directory.CreateTempSubdirectory("binding-app-gate").FullName;
        var prompted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            using var receiver = new TransferReceiver(directory, "Receiver", new PeerAppPolicy(hostApp), (_, _) =>
            {
                prompted.TrySetResult(true);
                return Task.FromResult(false);
            }) { Binding = binding };
            var owner = new PeerConnection("different-app", Peer);
            var headers = new Dictionary<string, string> { [LimLinkProtocol.HeaderApp] = peerApp };
            var hello = await receiver.HandleAsync(owner, "POST", LimLinkProtocol.HelloPath, headers,
                Json(new { proto = new[] { "1.0" }, alias = "Caller", app = peerApp, bindingId = id }));
            Assert.Equal(200, hello.Status);
            Assert.False(hello.Json.TryGetProperty("bindingId", out var advertised) && advertised.ValueKind == System.Text.Json.JsonValueKind.String,
                "A LimLink binding must not be advertised to a different host app.");
            var offer = await receiver.HandleAsync(owner, "POST", "/limlink/v1/sessions", headers,
                Json(new { clientSessionKey = "cross-app", transport = "lan", totalEntries = 1, totalBytes = 0,
                    entries = new[] { new { id = "file", kind = "file", relativePath = "test.txt", size = 0 } } }));
            Assert.Equal(202, offer.Status);
            await prompted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        }
        finally { Directory.Delete(directory, true); }
    }

}

internal sealed class MemoryBindings : IBindingStore
{
    public IReadOnlyList<DeviceBinding> Records = [];
    public bool Fail;
    public Action? AfterWrite;
    public IReadOnlyList<DeviceBinding> Read() => Records;
    public void Write(IReadOnlyList<DeviceBinding> records)
    {
        if (Fail) throw new IOException();
        Records = records.ToArray();
        AfterWrite?.Invoke();
    }
}

internal sealed class BindingClock : TimeProvider
{
    private long _timestamp;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp()=>_timestamp;
    public void Advance(TimeSpan time)=>_timestamp+=time.Ticks;
}
internal sealed class TestEncryption : ISecretProtector
{
    private readonly byte[] _key=System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
    public byte[] Protect(ReadOnlySpan<byte> bytes){var nonce=System.Security.Cryptography.RandomNumberGenerator.GetBytes(12);var ciphertext=new byte[bytes.Length];var tag=new byte[16];using var aes=new System.Security.Cryptography.AesGcm(_key,16);aes.Encrypt(nonce,bytes,ciphertext,tag);return nonce.Concat(tag).Concat(ciphertext).ToArray();}
    public byte[] Unprotect(ReadOnlySpan<byte> bytes){if(bytes.Length<28)throw new System.Security.Cryptography.CryptographicException();var plain=new byte[bytes.Length-28];using var aes=new System.Security.Cryptography.AesGcm(_key,16);aes.Decrypt(bytes[..12],bytes[28..],bytes.Slice(12,16),plain);return plain;}
}
