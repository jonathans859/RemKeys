using Microsoft.Extensions.Logging;

namespace KeyBridgeAgent;

/// <summary>
/// Minimal dependency-free file logger. Writes timestamped lines to a
/// per-day file in the configured directory. Thread-safe; failures to write
/// are swallowed so logging can never take the service down.
/// </summary>
public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _directory;
    private readonly object _gate = new();

    public FileLoggerProvider(string directory)
    {
        _directory = string.IsNullOrWhiteSpace(directory)
            ? Path.Combine(AppContext.BaseDirectory, "logs")
            : directory;
        try { Directory.CreateDirectory(_directory); } catch { /* logged path may be invalid; ignore */ }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(this, categoryName);

    public void Dispose() { }

    internal void Write(string categoryName, LogLevel level, string message, Exception? exception)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {categoryName}: {message}";
        if (exception is not null)
        {
            line += Environment.NewLine + exception;
        }

        var path = Path.Combine(_directory, $"keybridge-{DateTime.Now:yyyy-MM-dd}.log");
        lock (_gate)
        {
            try { File.AppendAllText(path, line + Environment.NewLine); }
            catch { /* never crash on a logging failure */ }
        }
    }

    private sealed class FileLogger : ILogger
    {
        private readonly FileLoggerProvider _provider;
        private readonly string _category;

        public FileLogger(FileLoggerProvider provider, string category)
        {
            _provider = provider;
            _category = category;
        }

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            _provider.Write(_category, logLevel, formatter(state, exception), exception);
        }
    }
}
