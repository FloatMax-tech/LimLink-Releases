using System.Diagnostics;

namespace LimLink.Core.Tests;

internal sealed class OpenSslResult
{
    public required int ExitCode { get; init; }
    public required string Output { get; init; }
    public required bool TimedOut { get; init; }
}

internal static class OpenSslTool
{
    public static string Executable()
    {
        var configured = Environment.GetEnvironmentVariable("LIMLINK_OPENSSL");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured;
        }

        return "openssl";
    }

    public static async Task<OpenSslResult> RunAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        string? stdin = null,
        CancellationToken cancellationToken = default)
    {
        var start = new ProcessStartInfo(Executable())
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = start };
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("Failed to start openssl.");
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            throw new InvalidOperationException(
                "openssl was not found. Install OpenSSL 3 and put it on PATH, or set LIMLINK_OPENSSL.",
                ex);
        }

        var stdout = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
        if (stdin is null)
        {
            process.StandardInput.Close();
        }
        else
        {
            await process.StandardInput.WriteAsync(stdin.AsMemory(), cancellationToken).ConfigureAwait(false);
            process.StandardInput.Close();
        }

        // Race against a delay. WaitForExitAsync's token is not enough: a stuck
        // s_client plus a pipe read that never observes the kill will sit until
        // the CI job is cancelled.
        var wait = process.WaitForExitAsync(CancellationToken.None);
        var finished = await Task.WhenAny(wait, Task.Delay(timeout, cancellationToken)).ConfigureAwait(false);
        if (finished != wait)
        {
            Kill(process);
            var partial = await Take(stdout) + await Take(stderr);
            return new OpenSslResult { ExitCode = -1, Output = partial, TimedOut = true };
        }

        await wait.ConfigureAwait(false);
        var output = await Take(stdout).ConfigureAwait(false) + await Take(stderr).ConfigureAwait(false);
        return new OpenSslResult { ExitCode = process.ExitCode, Output = output, TimedOut = false };
    }

    public static async Task<int> ReserveLoopbackPortAsync()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        await Task.Delay(20).ConfigureAwait(false);
        return port;
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(2000);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }

    private static async Task<string> Take(Task<string> read)
    {
        var finished = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(2))).ConfigureAwait(false);
        if (finished != read)
        {
            return string.Empty;
        }

        try
        {
            return await read.ConfigureAwait(false);
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }
}
