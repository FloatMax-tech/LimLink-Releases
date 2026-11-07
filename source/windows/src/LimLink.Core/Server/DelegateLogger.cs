using Microsoft.Extensions.Logging;

namespace LimLink;

/// <summary>Forwards Kestrel warnings and errors to a host-provided trace callback.</summary>
internal sealed class DelegateLoggerProvider(Action<string>? trace) : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName) => new Logger(categoryName, trace);
    public void Dispose() { }

    private sealed class Logger(string category, Action<string>? trace) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        // Debug for Kestrel connections so aborted handshakes and malformed requests are visible.
        public bool IsEnabled(LogLevel logLevel) => trace is not null && category.StartsWith("Microsoft.AspNetCore.Server.Kestrel", StringComparison.Ordinal) && logLevel >= LogLevel.Debug
            || trace is not null && logLevel >= LogLevel.Warning && category.StartsWith("Microsoft.AspNetCore", StringComparison.Ordinal);
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            var name = category.Replace("Microsoft.AspNetCore.", "", StringComparison.Ordinal);
            trace!(logLevel + " " + name + ": " + formatter(state, exception) + (exception is null ? "" : " | " + exception.Message));
        }
    }
}
