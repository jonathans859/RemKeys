using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;

namespace KeyBridgeAgent;

/// <summary>
/// The injector half of the service split. Runs as LocalSystem inside the
/// console session, attached to exactly one desktop, and replays whatever the
/// service sends — but only while that desktop is the one receiving input.
///
/// Two helpers run at a time: one on <c>Default</c> (ordinary apps, and the
/// tray icon) and one on <c>Winlogon</c> (the lock screen, the sign-in screen
/// and the UAC consent prompt). Both get every event; each decides for itself
/// whether it is in front. That decision has to live here, because a session 0
/// service is on a different window station and cannot see these desktops at
/// all.
/// </summary>
public sealed class HelperWorker : BackgroundService
{
    /// <summary>
    /// How stale the "am I in front?" answer may be when a key arrives. A
    /// desktop switch mid-chord is rare; 50 ms bounds the damage to at most a
    /// keystroke while keeping this off the per-event syscall path for bursts.
    /// </summary>
    private static readonly TimeSpan ActivityCacheLifetime = TimeSpan.FromMilliseconds(50);

    /// <summary>
    /// Independent of traffic: a lock usually happens with no keys in flight,
    /// and any key still held has to be released on the desktop we are leaving
    /// or it stays stuck down there until the next press.
    /// </summary>
    private static readonly TimeSpan ActivityPollInterval = TimeSpan.FromMilliseconds(250);

    private readonly ILogger<HelperWorker> _logger;
    private readonly AgentMode _mode;
    private readonly IHostApplicationLifetime _lifetime;

    private readonly object _heldGate = new();
    private readonly HashSet<ushort> _held = new();

    private readonly object _activityGate = new();
    private bool _isActive;
    private long _activityCheckedAt = -1;

    public HelperWorker(
        ILogger<HelperWorker> logger,
        AgentMode mode,
        IHostApplicationLifetime lifetime)
    {
        _logger = logger;
        _mode = mode;
        _lifetime = lifetime;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var actual = Native.GetThreadDesktopName();
        if (!string.Equals(actual, _mode.Desktop, StringComparison.OrdinalIgnoreCase))
        {
            // Not fatal — injection still goes wherever this thread actually
            // is — but it means the supervisor's lpDesktop did not take, and
            // that is worth seeing in the log.
            _logger.LogWarning("Helper was launched for desktop {Wanted} but is attached to {Actual}.",
                _mode.Desktop, actual ?? "unknown");
        }
        else
        {
            _logger.LogInformation("Helper attached to desktop {Desktop}.", _mode.Desktop);
        }

        // The poller outlives nothing: it has to stop when this session does,
        // not only when the host shuts down, or the exit path below would wait
        // on it forever.
        using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var poller = Task.Run(() => PollActivityAsync(sessionCts.Token), CancellationToken.None);

        // A helper's life is exactly one pipe session. It does not reconnect on
        // its own: if the service went away, the supervisor that restarts it
        // will spawn a fresh helper, and a lingering one would then be a second
        // injector on this desktop typing everything twice.
        try
        {
            await RunSessionAsync(stoppingToken);
            _logger.LogInformation("The service closed the injection pipe; helper exiting.");
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Injection pipe session failed; helper exiting.");
        }

        sessionCts.Cancel();
        ReleaseHeldKeys("helper stopping");
        try { await poller; } catch { /* shutting down */ }

        if (!stoppingToken.IsCancellationRequested)
        {
            _lifetime.StopApplication();
        }
    }

    private async Task RunSessionAsync(CancellationToken stoppingToken)
    {
        using var pipe = new NamedPipeClientStream(
            ".",
            PipeProtocol.PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous,
            TokenImpersonationLevel.Impersonation);

        await pipe.ConnectAsync(stoppingToken);
        _logger.LogInformation("Connected to the injection pipe.");

        await WriteLineAsync(pipe, $"{PipeProtocol.Hello} {_mode.Desktop}", stoppingToken);

        var reader = new LineReader();
        var buffer = new byte[1024];
        int read;
        while ((read = await pipe.ReadAsync(buffer.AsMemory(), stoppingToken)) > 0)
        {
            foreach (var line in reader.Feed(buffer.AsSpan(0, read)))
            {
                Handle(line);
            }
        }
    }

    private void Handle(string line)
    {
        if (WireProtocol.TryParse(line, out var vk, out var pressed))
        {
            Inject(vk, pressed);
            return;
        }

        if (WireProtocol.TryParseChar(line, out var codepoint))
        {
            if (!IsMyDesktopActive()) return;
            if (!KeystrokeInjector.SendUnicode(codepoint))
            {
                _logger.LogWarning("SendInput rejected unicode codepoint={Codepoint}.", codepoint);
            }
            return;
        }

        var trimmed = line.Trim();
        if (trimmed.Length > 0)
        {
            _logger.LogWarning("Ignoring malformed pipe line: {Line}", trimmed);
        }
    }

    private void Inject(ushort vk, bool pressed)
    {
        if (!IsMyDesktopActive())
        {
            // Someone else's desktop is in front. Dropping is right: injecting
            // anyway would queue the keystroke on a desktop nobody is looking
            // at, and it would arrive out of nowhere on the next switch.
            return;
        }

        if (!KeystrokeInjector.Send(vk, pressed))
        {
            _logger.LogWarning("SendInput rejected vk={Vk} pressed={Pressed}.", vk, pressed);
            return;
        }

        lock (_heldGate)
        {
            if (pressed) _held.Add(vk);
            else _held.Remove(vk);
        }
    }

    /// <summary>
    /// Whether this helper's desktop is the one receiving input. When the
    /// answer cannot be determined the Default helper assumes yes and the
    /// Winlogon helper assumes no, so a failure here degrades to exactly the
    /// pre-service behaviour instead of dropping every keystroke.
    /// </summary>
    private bool IsMyDesktopActive()
    {
        var now = Stopwatch.GetTimestamp();
        lock (_activityGate)
        {
            if (_activityCheckedAt >= 0 &&
                Stopwatch.GetElapsedTime(_activityCheckedAt, now) < ActivityCacheLifetime)
            {
                return _isActive;
            }
        }

        var active = ComputeActive();
        SetActive(active, now);
        return active;
    }

    private bool ComputeActive()
    {
        var input = Native.GetInputDesktopName();
        if (input is null) return !_mode.IsWinlogonHelper;
        return string.Equals(input, _mode.Desktop, StringComparison.OrdinalIgnoreCase);
    }

    private void SetActive(bool active, long timestamp)
    {
        bool wasActive;
        lock (_activityGate)
        {
            wasActive = _isActive;
            _isActive = active;
            _activityCheckedAt = timestamp;
        }

        if (wasActive && !active)
        {
            ReleaseHeldKeys($"desktop {_mode.Desktop} left the foreground");
        }
    }

    private async Task PollActivityAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(ActivityPollInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                SetActive(ComputeActive(), Stopwatch.GetTimestamp());
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>
    /// Let go of everything still down. Without this, locking the PC while a
    /// modifier is held leaves it stuck on the desktop being left behind — the
    /// remote-half-held-chord problem the Apple side already guards against.
    /// </summary>
    private void ReleaseHeldKeys(string reason)
    {
        ushort[] stuck;
        lock (_heldGate)
        {
            if (_held.Count == 0) return;
            stuck = _held.ToArray();
            _held.Clear();
        }

        _logger.LogInformation("Releasing {Count} held key(s) on {Desktop}: {Reason}.",
            stuck.Length, _mode.Desktop, reason);
        foreach (var vk in stuck)
        {
            KeystrokeInjector.Send(vk, false);
        }
    }

    private static async Task WriteLineAsync(PipeStream pipe, string line, CancellationToken token)
    {
        var bytes = Encoding.UTF8.GetBytes(line + "\n");
        await pipe.WriteAsync(bytes.AsMemory(), token);
        await pipe.FlushAsync(token);
    }
}
