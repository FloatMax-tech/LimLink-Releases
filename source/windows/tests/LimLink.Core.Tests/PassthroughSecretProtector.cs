using LimLink;
namespace LimLink.Core.Tests;
internal sealed class PassthroughSecretProtector : ISecretProtector
{
    public byte[] Protect(ReadOnlySpan<byte> bytes) => bytes.ToArray();
    public byte[] Unprotect(ReadOnlySpan<byte> bytes) => bytes.ToArray();
}
