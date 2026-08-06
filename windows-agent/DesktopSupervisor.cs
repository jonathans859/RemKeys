using System.Diagnostics;

namespace KeyBridgeAgent;

/// <summary>
/// Service-side supervisor: keeps one injector helper alive on each desktop of
/// the console session, and follows that session as it moves (sign-out,
/// fast user switching, reboot).
///
/// This is the piece that makes the lock screen reachable. The service itself
/// is in session 0 with its own window station, where SendInput can never
/// touch the interactive desktop — the fix is not to inject from here, but to
/// place a process on each desktop that can.
/// </summary>
public sealed class DesktopSupervisor : BackgroundService
{
    private static readonly string[] Desktops = { DesktopNames.Default, DesktopNames.Winlogon };
    private static readonly TimeSpan SweepInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan MinBackoff = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);

    private readonly ILogger<DesktopSupervisor> _logger;
    private readonly List<HelperProcess> _helpers = new();
    private uint _session = Native.INVALID_SESSION;

    public DesktopSupervisor(ILogger<DesktopSupervisor> logger) => _logger = logger;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Desktop supervisor started.");
        using var timer = new PeriodicTimer(SweepInterval);
        try
        {
            do
            {
                try
                {
                    Sweep();
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Desktop supervisor sweep failed; continuing.");
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException) { }
        finally
        {
            StopHelpers("service stopping");
            _logger.LogInformation("Desktop supervisor stopped.");
        }
    }

    private void Sweep()
    {
        var session = Native.WTSGetActiveConsoleSessionId();

        // 0xFFFFFFFF means no console session attached at all (it happens
        // briefly during fast user switching); session 0 is the non-interactive
        // one and has no desktop worth injecting into.
        if (session == Native.INVALID_SESSION || session == 0)
        {
            if (_helpers.Count > 0) StopHelpers("no interactive console session");
            _session = Native.INVALID_SESSION;
            return;
        }

        if (session != _session)
        {
            if (_helpers.Count > 0) StopHelpers($"console session moved to {session}");
            _logger.LogInformation("Console session is now {Session}; starting desktop helpers.", session);
            _session = session;
            foreach (var desktop in Desktops)
            {
                _helpers.Add(new HelperProcess(desktop));
            }
        }

        foreach (var helper in _helpers)
        {
            EnsureRunning(helper);
        }
    }

    private void EnsureRunning(HelperProcess helper)
    {
        if (helper.Process is { HasExited: false }) return;

        if (helper.Process is not null)
        {
            var exitCode = TryGetExitCode(helper.Process);
            _logger.LogWarning("Helper for {Desktop} exited ({ExitCode}); will restart.", helper.Desktop, exitCode);
            helper.Process.Dispose();
            helper.Process = null;
            helper.Failures++;
        }

        if (DateTime.UtcNow < helper.NextAttempt) return;

        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            _logger.LogError("Cannot determine this executable's path; no helper can be started.");
            helper.Backoff(MinBackoff, MaxBackoff);
            return;
        }

        var commandLine = $"\"{exe}\" --helper --desktop {helper.Desktop}";
        try
        {
            helper.Process = Native.StartOnDesktop(commandLine, _session, helper.Desktop, AppContext.BaseDirectory);
            if (helper.Process is null)
            {
                helper.Failures++;
                helper.Backoff(MinBackoff, MaxBackoff);
                return;
            }

            _logger.LogInformation("Started helper for desktop {Desktop} in session {Session} (pid {Pid}).",
                helper.Desktop, _session, helper.Process.Id);
            helper.Failures = 0;
            helper.NextAttempt = DateTime.UtcNow;
        }
        catch (Exception ex)
        {
            helper.Failures++;
            _logger.LogError(ex, "Could not start the helper for desktop {Desktop}; retrying with backoff.", helper.Desktop);
            helper.Backoff(MinBackoff, MaxBackoff);
        }
    }

    private void StopHelpers(string reason)
    {
        foreach (var helper in _helpers)
        {
            var process = helper.Process;
            helper.Process = null;
            if (process is null) continue;

            try
            {
                if (!process.HasExited)
                {
                    _logger.LogInformation("Stopping helper for {Desktop} ({Reason}).", helper.Desktop, reason);

                    // Give it a moment to notice the pipe closed and leave on
                    // its own — that path releases held keys, Kill does not.
                    if (!process.WaitForExit(1500))
                    {
                        process.Kill();
                        process.WaitForExit(3000);
                    }
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Could not stop the helper for {Desktop}.", helper.Desktop);
            }
            finally
            {
                process.Dispose();
            }
        }
        _helpers.Clear();
    }

    private static string TryGetExitCode(Process process)
    {
        try { return process.ExitCode.ToString(); } catch { return "unknown"; }
    }

    private sealed class HelperProcess
    {
        public HelperProcess(string desktop) => Desktop = desktop;

        public string Desktop { get; }
        public Process? Process { get; set; }
        public int Failures { get; set; }
        public DateTime NextAttempt { get; set; } = DateTime.UtcNow;

        /// <summary>
        /// Exponential, capped. A helper that cannot start (a desktop that does
        /// not exist yet during session setup, say) must not turn into a spawn
        /// loop that fills the log and the process table.
        /// </summary>
        public void Backoff(TimeSpan min, TimeSpan max)
        {
            var seconds = Math.Min(max.TotalSeconds, min.TotalSeconds * Math.Pow(2, Math.Min(Failures, 5)));
            NextAttempt = DateTime.UtcNow.AddSeconds(seconds);
        }
    }
}
