using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Forms;

namespace KeyBridgeAgent;

/// <summary>
/// What the tray menu can do, which differs by how the agent was started. The
/// tray itself only ever renders one of these.
/// </summary>
public interface ITrayHost
{
    /// <summary>Disabled menu line describing the current mode.</summary>
    string ModeLine { get; }

    /// <summary>Label of the item that switches modes.</summary>
    string ToggleLabel { get; }

    /// <summary>Install or remove lock-screen support, with a confirmation first.</summary>
    void Toggle();

    /// <summary>Stop the agent — the whole thing, service and helpers included.</summary>
    void Exit();
}

/// <summary>
/// Classic install: one process in the user's session. Offers to upgrade to
/// the service, which is the only way to reach the lock screen.
/// </summary>
public sealed class StandaloneTrayHost : ITrayHost
{
    private readonly IHostApplicationLifetime _lifetime;
    private readonly ILogger<StandaloneTrayHost> _logger;

    public StandaloneTrayHost(IHostApplicationLifetime lifetime, ILogger<StandaloneTrayHost> logger)
    {
        _lifetime = lifetime;
        _logger = logger;
    }

    public string ModeLine => "Lock screen support: off";

    public string ToggleLabel => "Turn on lock screen support…";

    public void Toggle()
    {
        var answer = MessageBox.Show(
            "Turn on lock screen support?\r\n\r\n" +
            "RemKeys will be installed as a Windows service that starts before you sign in. " +
            "Keystrokes will then also reach the lock screen, the sign-in screen and UAC prompts.\r\n\r\n" +
            "Because anyone who can reach this PC over Tailscale could then type at the lock screen, " +
            "only turn this on if you are comfortable with that.\r\n\r\n" +
            "Windows will ask for administrator permission.",
            "RemKeys",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question);

        if (answer != DialogResult.Yes) return;

        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            MessageBox.Show("Could not determine the agent's own path.", "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var startInfo = new ProcessStartInfo(exe)
        {
            // The installer waits for this process to exit before it starts
            // the service, so the port is free by the time it does.
            Arguments = $"--install-service --wait-pid {Environment.ProcessId}",
            UseShellExecute = true,
            Verb = "runas",
        };

        try
        {
            Process.Start(startInfo);
        }
        catch (Win32Exception ex)
        {
            // 1223 = the user said no to the UAC prompt. Nothing was changed,
            // so say so and carry on running as we were.
            _logger.LogInformation("Lock screen install was not started: {Message}", ex.Message);
            MessageBox.Show("Lock screen support was not turned on.", "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        _lifetime.StopApplication();
    }

    public void Exit() => _lifetime.StopApplication();
}

/// <summary>
/// Service install, seen from the Default-desktop helper — the only one of the
/// two helpers that has a tray icon (nothing on the secure desktop could show
/// one, and there would be no one to see it).
/// </summary>
public sealed class HelperTrayHost : ITrayHost
{
    private readonly HelperWorker _helper;
    private readonly ILogger<HelperTrayHost> _logger;

    public HelperTrayHost(HelperWorker helper, ILogger<HelperTrayHost> logger)
    {
        _helper = helper;
        _logger = logger;
    }

    public string ModeLine => "Lock screen support: on";

    public string ToggleLabel => "Turn off lock screen support…";

    public void Toggle()
    {
        var answer = MessageBox.Show(
            "Turn off lock screen support?\r\n\r\n" +
            "The RemKeys service will be removed and the normal agent put back — the one that runs " +
            "only while you are signed in. Keystrokes will no longer reach the lock screen, the " +
            "sign-in screen or UAC prompts.",
            "RemKeys",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question);

        if (answer != DialogResult.Yes) return;

        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            MessageBox.Show("Could not determine the agent's own path.", "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        // No "runas" needed: this helper is already LocalSystem, so the child
        // inherits everything the uninstall requires.
        var startInfo = new ProcessStartInfo(exe)
        {
            Arguments = "--uninstall-service",
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        try
        {
            Process.Start(startInfo);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not start the lock screen uninstaller.");
            MessageBox.Show("Could not start the uninstaller: " + ex.Message, "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    public void Exit() => _helper.RequestServiceStop();
}
