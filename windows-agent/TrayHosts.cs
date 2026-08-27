using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Forms;
using Microsoft.Extensions.Options;

namespace RemKeysAgent;

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

    /// <summary>
    /// The "who may connect" choice, or null in a mode that has none. Only the
    /// lock-screen service restricts peers at all — the in-session agent types
    /// as the signed-in user and never has.
    /// </summary>
    ITrayPeerPolicy? Peers { get; }

    /// <summary>
    /// What stopping the agent costs and how to get it back, for the exit
    /// confirmation. It differs by mode — one takes the lock screen's keyboard
    /// with it and the other does not — and a tray icon that is simply gone
    /// leaves nothing behind to read, so it has to be said before the fact.
    /// </summary>
    string ExitConsequence { get; }

    /// <summary>Stop the agent — the whole thing, service and helpers included.</summary>
    void Exit();
}

/// <summary>
/// The tray's view of <see cref="PeerAccess"/>: what is in force, what else can
/// be picked, and how to pick it.
/// </summary>
public interface ITrayPeerPolicy
{
    /// <summary>
    /// The policy in force, as a whole sentence. It is the submenu's own label,
    /// not a line inside it, so a screen reader says the current setting
    /// without the user having to open anything.
    /// </summary>
    string SummaryLine { get; }

    /// <summary>Every choice in menu order, with the one in force marked.</summary>
    IReadOnlyList<(PeerAccess Value, string Label, bool InForce)> Choices { get; }

    /// <summary>
    /// False when appsettings.json pins a single allowed address, which
    /// overrides the whole scale — the menu must not offer a choice that would
    /// then change nothing.
    /// </summary>
    bool CanChange { get; }

    /// <summary>Confirm and apply, elevating to do it.</summary>
    void Choose(PeerAccess value);
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

    /// <summary>
    /// Nothing to choose: this agent accepts any peer that can reach the port,
    /// because it can only type what the signed-in user could type anyway.
    /// </summary>
    public ITrayPeerPolicy? Peers => null;

    public string ExitConsequence =>
        "Keystrokes from your iPhone, iPad or Mac will stop arriving at this PC.\r\n\r\n" +
        "The agent starts again by itself the next time you sign in. To start it now without " +
        $"signing out, run install-agent.bat as Administrator, or run the \"{ServiceSetup.TaskName}\" " +
        "task in Task Scheduler.";

    public void Toggle()
    {
        var answer = MessageBox.Show(
            "Turn on lock screen support?\r\n\r\n" +
            "RemKeys will be installed as a Windows service that starts before you sign in. " +
            "Keystrokes will then also reach the lock screen, the sign-in screen and UAC prompts.\r\n\r\n" +
            "Because anyone who can reach this PC could then type at the lock screen, only Tailscale " +
            $"addresses are accepted to start with. If you connect over a plain home or office " +
            $"network instead, change \"{TrayText.PeerMenuTitle}\" in the tray menu afterwards.\r\n\r\n" +
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
/// Service install, seen from the ordinary logon-task process — which, while
/// lock-screen support is on, runs no listener and injects nothing, and exists
/// only to carry this tray.
///
/// It has to be this process and not a desktop helper: helpers are LocalSystem
/// (System integrity), and a screen reader at medium integrity with uiAccess
/// cannot read the UI of a System-integrity process, so a helper-owned menu
/// reads as empty (field-reported 2026-08-06). The logon task runs as the user,
/// exactly where the tray has always worked.
/// </summary>
public sealed class ServiceClientTrayHost : ITrayHost
{
    private readonly TrayClientWorker _client;
    private readonly ILogger<ServiceClientTrayHost> _logger;

    public ServiceClientTrayHost(
        TrayClientWorker client,
        IOptions<RemKeysOptions> options,
        ILogger<ServiceClientTrayHost> logger)
    {
        _client = client;
        _logger = logger;
        // This process reads the same appsettings.json the service does, so the
        // menu can show the policy in force without asking the service for it.
        // The setter restarts this process, which is what keeps it true.
        Peers = new ServicePeerPolicy(options.Value, logger);
    }

    public string ModeLine => "Lock screen support: on";

    public string ToggleLabel => "Turn off lock screen support…";

    public ITrayPeerPolicy? Peers { get; }

    /// <summary>
    /// Worth spelling out that this is not just the tray icon: Exit here stops
    /// the service and both desktop helpers, so the lock screen loses its
    /// keyboard too — and unlike the in-session agent, signing in again does
    /// not bring it back.
    /// </summary>
    public string ExitConsequence =>
        "This stops the RemKeys service and its desktop helpers, not just the tray icon.\r\n\r\n" +
        "Keystrokes from your iPhone, iPad or Mac will stop arriving at this PC — including at the " +
        "lock screen, the sign-in screen and UAC prompts.\r\n\r\n" +
        "The service starts again by itself when this PC restarts. To start it now, run " +
        $"install-lockscreen.bat as Administrator, or start \"{ServiceSetup.ServiceDisplayName}\" " +
        "in the Services app.";

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

        // Removing a service needs administrator rights, and this process is
        // just the signed-in user — so this one does prompt.
        var startInfo = new ProcessStartInfo(exe)
        {
            Arguments = "--uninstall-service",
            UseShellExecute = true,
            Verb = "runas",
        };

        try
        {
            Process.Start(startInfo);
        }
        catch (Win32Exception ex)
        {
            // 1223 = the user declined the UAC prompt.
            _logger.LogInformation("Lock screen uninstall was not started: {Message}", ex.Message);
            MessageBox.Show("Lock screen support was not turned off.", "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not start the lock screen uninstaller.");
            MessageBox.Show("Could not start the uninstaller: " + ex.Message, "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    public void Exit() => _client.RequestServiceStop();
}

/// <summary>
/// The peer policy as the tray offers it: read out of the same appsettings.json
/// the service binds, changed by relaunching the exe elevated with
/// <c>--set-access</c>.
///
/// It does not travel down the status pipe, even though that pipe is right
/// there and already carries "stop". That pipe is ACL'd for any interactive
/// user, and stopping a service on your own console is no worse than pulling
/// the plug — but opening the lock screen to the whole LAN is a decision only
/// an administrator should be able to make, so it goes through UAC exactly
/// like turning lock-screen support on does.
/// </summary>
public sealed class ServicePeerPolicy : ITrayPeerPolicy
{
    private readonly RemKeysOptions _options;
    private readonly ILogger _logger;
    private readonly PeerAccess _current;
    private readonly string _pinned;

    public ServicePeerPolicy(RemKeysOptions options, ILogger logger)
    {
        _options = options;
        _logger = logger;
        _current = options.ResolveLockScreenAccess(out _);
        _pinned = options.AllowedRemoteIP.Trim();
    }

    public bool CanChange => _pinned.Length == 0;

    public string SummaryLine => CanChange
        ? $"{TrayText.PeerMenuTitle}: {PeerAccessPolicy.Label(_current)}"
        : $"{TrayText.PeerMenuTitle}: only {_pinned} (AllowedRemoteIP in appsettings.json)";

    public IReadOnlyList<(PeerAccess Value, string Label, bool InForce)> Choices =>
        PeerAccessPolicy.All
            .Select(value => (Value: value, Label: PeerAccessPolicy.Label(value), InForce: value == _current))
            .ToList();

    public void Choose(PeerAccess value)
    {
        if (!CanChange || value == _current) return;

        var answer = MessageBox.Show(
            $"{TrayText.PeerMenuTitle}?\r\n\r\n" +
            $"New setting: {PeerAccessPolicy.Label(value)}.\r\n\r\n" +
            PeerAccessPolicy.Consequence(value, _options.ListenPort) + "\r\n\r\n" +
            "The lock screen service will restart, so a connected device has to reconnect. " +
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
            Arguments = $"--set-access {PeerAccessPolicy.Canonical(value)}",
            UseShellExecute = true,
            Verb = "runas",
        };

        try
        {
            // No StopApplication here: the setter restarts the logon task once
            // it is done, which ends this process and brings the tray back
            // having re-read the file. Quitting now would leave no tray at all
            // if the setter failed.
            Process.Start(startInfo);
        }
        catch (Win32Exception ex)
        {
            // 1223 = the user declined the UAC prompt. Nothing was changed.
            _logger.LogInformation("Peer policy change was not started: {Message}", ex.Message);
            MessageBox.Show($"{TrayText.PeerMenuTitle} was not changed.", "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not start the peer policy setter.");
            MessageBox.Show("Could not change the setting: " + ex.Message, "RemKeys",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
