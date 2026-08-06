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
    private readonly string _tag;
    private readonly object _gate = new();

    /// <param name="tag">
    /// Which of the agent's processes this is ("agent", "service",
    /// "helper:Winlogon", …). With lock-screen support on, three processes
    /// share one log file, and a line is close to useless without knowing
    /// which desktop it came from.
    /// </param>
    public FileLoggerProvider(string directory, string tag = "agent")
    {
        _directory = string.IsNullOrWhiteSpace(directory)
            ? Path.Combine(AppContext.BaseDirectory, "logs")
            : directory;
        _tag = tag;
        try { Directory.CreateDirectory(_directory); } catch { /* logged path may be invalid; ignore */ }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(this, categoryName);

    public void Dispose() { }

    internal void Write(string categoryName, LogLevel level, string message, Exception? exception)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] ({_tag}) {categoryName}: {message}";
        if (exception is not null)
        {
            line += Environment.NewLine + exception;
        }

        var path = Path.Combine(_directory, $"keybridge-{DateTime.Now:yyyy-MM-dd}.log");
        lock (_gate)
        {
            // The lock only covers this process. With lock-screen support on,
            // the service and both helpers append to the same file, so a
            // sharing violation is normal rather than exceptional — retry
            // briefly before giving the line up.
            for (int attempt = 0; attempt < 4; attempt++)
            {
                try
                {
                    File.AppendAllText(path, line + Environment.NewLine);
                    return;
                }
                catch (IOException)
                {
                    Thread.Sleep(5 * (attempt + 1));
                }
                catch { return; /* never crash on a logging failure */ }
            }
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
