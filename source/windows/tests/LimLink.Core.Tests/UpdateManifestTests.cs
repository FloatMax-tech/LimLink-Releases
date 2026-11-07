using LimLink.Updates;
namespace LimLink.Core.Tests;
public class UpdateManifestTests
{
    private static string Manifest(string version="0.6.2", string url="/download/windows") =>
        System.Text.Json.JsonSerializer.Serialize(new { windows = new { version, url, size=12345, sha256=new string('a',64) } });
    [Fact] public void NewWebsiteSchemaOffersRelease() => Assert.Equal("https://limlink.floatmax-tech.com/download/windows", UpdateManifest.Parse(Manifest(),new Version(0,6,1,0))!.Url.AbsoluteUri);
    [Fact] public void ThreePartVersionComparesNumerically() {
        Assert.Null(UpdateManifest.Parse(Manifest("0.6.1"),new Version(0,6,1,0)));
        Assert.Null(UpdateManifest.Parse(Manifest("0.6.0"),new Version(0,6,1,0)));
        Assert.NotNull(UpdateManifest.Parse(Manifest("0.10.0"),new Version(0,9,0,0)));
    }
    [Fact] public void FirstReleaseTwoPartVersion() {
        Assert.Null(UpdateManifest.Parse(Manifest("1.0"),new Version(1,0,0,0)));
        Assert.Null(UpdateManifest.Parse(Manifest("1.0.0"),new Version(1,0)));
        Assert.NotNull(UpdateManifest.Parse(Manifest("1.0.1"),new Version(1,0)));
        Assert.NotNull(UpdateManifest.Parse(Manifest("1.0"),new Version(0,6,2,0)));
    }
    [Fact] public void EmptyWebsiteHasNoRelease() => Assert.Throws<NoReleaseException>(()=>UpdateManifest.Parse("{}",new Version(0,6,1,0)));
    [Theory]
    [InlineData("//evil.example/file")][InlineData("https://evil.example/file")]
    [InlineData("/\\evil.example/file")][InlineData("/download/windows-cn")]
    [InlineData("/download/../windows")][InlineData("/download/windows?device=123")]
    public void UnsafeOrWrongChannelUrlRejected(string url) => Assert.Throws<FormatException>(()=>UpdateManifest.Parse(Manifest(url:url),new Version(0,6,1,0)));
    [Fact] public void MalformedAndOversizedMetadataRejected() {
        Assert.Throws<FormatException>(()=>UpdateManifest.Parse(Manifest("oops"),new Version(0,6,1,0)));
        Assert.Throws<FormatException>(()=>UpdateManifest.Parse(new string(' ',131073),new Version(0,6,1,0)));
        Assert.Throws<FormatException>(()=>UpdateManifest.Parse(Manifest().Replace(new string('a',64),"bad"),new Version(0,6,1,0)));
    }
}
