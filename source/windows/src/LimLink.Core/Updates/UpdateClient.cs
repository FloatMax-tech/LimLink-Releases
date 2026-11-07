using System.Net;
using System.Text;
namespace LimLink.Updates;
public static class UpdateClient {
    public const string Endpoint = "https://limlink.floatmax-tech.com/version.json";
    public const int MaxBytes = UpdateManifest.MaxBytes;
    public static async Task<AvailableUpdate?> CheckAsync(Version installed, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
        using var client = new HttpClient(handler);
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"LimLink/{installed.Major}.{installed.Minor}.{installed.Build} (Windows)");
        using var response = await client.GetAsync(Endpoint, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (response.StatusCode == HttpStatusCode.NotFound) throw new NoReleaseException();
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > MaxBytes) throw new FormatException();
        using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var data = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(buffer, timeout.Token)) != 0)
        {
            if (data.Length + count > MaxBytes) throw new FormatException();
            data.Write(buffer, 0, count);
        }
        return UpdateManifest.Parse(new UTF8Encoding(false, true).GetString(data.ToArray()), installed);
    }
}
