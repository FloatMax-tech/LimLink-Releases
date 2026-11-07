using System.Net.Sockets;

namespace LimLink;

public static class PortSelector
{
    public static IReadOnlyList<int> Candidates(int preferredPort, bool allowSystemPortFallback)
    {
        if (preferredPort is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(preferredPort));
        }

        var ports = new int[allowSystemPortFallback
            ? LimLinkProtocol.PortAttemptCount + 1
            : LimLinkProtocol.PortAttemptCount];
        for (var i = 0; i < LimLinkProtocol.PortAttemptCount; i++)
        {
            var port = preferredPort + i;
            if (port > 65535)
            {
                throw new ArgumentOutOfRangeException(nameof(preferredPort), "Port scan would exceed 65535.");
            }

            ports[i] = port;
        }

        if (allowSystemPortFallback)
        {
            ports[^1] = 0;
        }

        return ports;
    }

    public static bool IsAddressUnavailable(Exception exception)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current is SocketException socket
                && socket.SocketErrorCode is SocketError.AddressAlreadyInUse or SocketError.AccessDenied)
            {
                return true;
            }
        }

        return false;
    }
}

public sealed class LimLinkPortException : Exception
{
    public LimLinkPortException(string code, string message, Exception? inner = null)
        : base(message, inner)
    {
        Code = code;
    }

    public string Code { get; }
}
