using Microsoft.Extensions.Logging;

namespace LimLink.Desktop;

/// <summary>Routes core warnings and errors into the activity log.</summary>
internal sealed class ActivityLoggerFactory : ILoggerFactory
{
    public static readonly ActivityLoggerFactory Instance = new();
    public ILogger CreateLogger(string categoryName) => new Logger(categoryName);
    public void AddProvider(ILoggerProvider provider) { }
    public void Dispose() { }

    private sealed class Logger(string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            var name = category[(category.LastIndexOf('.') + 1)..];
            ActivityLog.Write("core", $"{logLevel} {name}: {formatter(state, exception)}{(exception is null ? "" : " | " + exception.Message)}");
        }
    }
}
