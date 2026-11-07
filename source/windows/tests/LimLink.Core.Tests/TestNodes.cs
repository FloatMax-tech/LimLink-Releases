using System.Net;
using System.Net.Sockets;
using LimLink;

namespace LimLink.Core.Tests;

internal static class FixedPortGate
{
    public static readonly SemaphoreSlim Instance = new(1, 1);
}

internal sealed class TestNode : IAsyncDisposable
{
    public required LimLinkNode Node { get; init; }
    public required string DirectoryPath { get; init; }

    public async ValueTask DisposeAsync()
    {
        await Node.DisposeAsync().ConfigureAwait(false);
        try
        {
            Directory.Delete(DirectoryPath, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

internal static class TestNodes
{
    public static async Task<TestNode> StartAsync(
        string hostAppId = LimLinkProtocol.DefaultHostAppId,
        int? explicitPort = 0,
        bool allowSystemPortFallback = true,
        int preferredPort = LimLinkProtocol.DefaultPort,
        IReadOnlyCollection<string>? allowedPeerApps = null)
    {
        var directory = Directory.CreateTempSubdirectory("limlink-test").FullName;
        var node = await LimLinkNode.StartAsync(new LimLinkNodeOptions
        {
            DataDirectory = directory,
            HostAppId = hostAppId,
            AllowedPeerApps = allowedPeerApps,
            DeviceAlias = "unit-" + hostAppId,
            DevType = LimLinkProtocol.DefaultDevType,
            PreferredPort = preferredPort,
            AllowSystemPortFallback = allowSystemPortFallback,
            ExplicitPort = explicitPort,
            IdentityStore = new FileDeviceIdentityStore(
                Path.Combine(directory, "device-identity.bin"),
                new PassthroughSecretProtector()),
        }).ConfigureAwait(false);
        return new TestNode { Node = node, DirectoryPath = directory };
    }

    public static LimLinkClient Client(LimLinkNode node, string? hostAppId = null, bool sendAppHeader = true)
    {
        return new LimLinkClient(new LimLinkClientOptions
        {
            Certificate = node.Certificate,
            HostAppId = hostAppId ?? node.HostAppId,
            Alias = "unit",
            LocalPort = node.Port,
            SendAppHeader = sendAppHeader,
        });
    }

    public static async Task<List<TcpListener>> OccupyAsync(int first, int last)
    {
        var listeners = new List<TcpListener>();
        try
        {
            for (var port = first; port <= last; port++)
            {
                var listener = new TcpListener(IPAddress.Any, port);
                try { listener.Start(); listeners.Add(listener); }
                catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
                {
                    // Keep the occupied-range precondition without interfering with another host.
                    listener.Stop();
                }
            }
        }
        catch
        {
            foreach (var listener in listeners)
            {
                listener.Stop();
            }

            throw;
        }

        return listeners;
    }
}
