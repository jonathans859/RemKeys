namespace KeyBridgeAgent;

/// <summary>
/// Which of the agent's four personalities this process is. One executable
/// covers all of them so there is a single file to ship, sign and update.
/// </summary>
public enum AgentRole
{
    /// <summary>
    /// No arguments: the classic install. One process in the user's session
    /// owns the socket and injects directly. Cannot reach the lock screen or
    /// the UAC prompt — those live on a different desktop.
    /// </summary>
    Standalone,

    /// <summary>
    /// <c>--service</c>: LocalSystem, session 0. Owns the socket and the wire
    /// parser, and supervises one injector helper per desktop. Injects nothing
    /// itself — session 0 has its own window station and its SendInput could
    /// never reach the interactive desktop.
    /// </summary>
    Service,

    /// <summary>
    /// <c>--helper --desktop &lt;name&gt;</c>: spawned by the service into the
    /// console session, bound to one desktop. Receives events over the named
    /// pipe and injects them, but only while its desktop is the one receiving
    /// input.
    /// </summary>
    Helper,

    /// <summary><c>--install-service</c>, run elevated from the tray.</summary>
    InstallService,

    /// <summary><c>--uninstall-service</c>, run from the tray.</summary>
    UninstallService,
}

/// <summary>The two desktops of an interactive window station that matter here.</summary>
public static class DesktopNames
{
    /// <summary>Where ordinary applications live.</summary>
    public const string Default = "Default";

    /// <summary>
    /// The secure desktop: the lock screen, the sign-in screen, and the UAC
    /// consent prompt all render here. Only a process running on this desktop
    /// can inject into it.
    /// </summary>
    public const string Winlogon = "Winlogon";
}

/// <summary>Parsed command line.</summary>
public sealed class AgentMode
{
    public AgentRole Role { get; init; } = AgentRole.Standalone;

    /// <summary>Desktop this helper is bound to. Meaningful for <see cref="AgentRole.Helper"/>.</summary>
    public string Desktop { get; init; } = DesktopNames.Default;

    /// <summary>
    /// Process the installer must see exit before it touches the service —
    /// the standalone agent it is replacing, which still holds the port.
    /// </summary>
    public int WaitForPid { get; init; }

    public bool IsWinlogonHelper => Role == AgentRole.Helper
        && string.Equals(Desktop, DesktopNames.Winlogon, StringComparison.OrdinalIgnoreCase);

    public static AgentMode Parse(string[] args)
    {
        var role = AgentRole.Standalone;
        var desktop = DesktopNames.Default;
        var waitPid = 0;

        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--service":
                    role = AgentRole.Service;
                    break;
                case "--helper":
                    role = AgentRole.Helper;
                    break;
                case "--install-service":
                    role = AgentRole.InstallService;
                    break;
                case "--uninstall-service":
                    role = AgentRole.UninstallService;
                    break;
                case "--desktop":
                    if (i + 1 < args.Length) desktop = args[++i];
                    break;
                case "--wait-pid":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out var pid)) { waitPid = pid; i++; }
                    break;
            }
        }

        // Normalise to the canonical spelling so string comparisons downstream
        // (and the pipe handshake) don't have to be case-insensitive.
        desktop = string.Equals(desktop, DesktopNames.Winlogon, StringComparison.OrdinalIgnoreCase)
            ? DesktopNames.Winlogon
            : DesktopNames.Default;

        return new AgentMode { Role = role, Desktop = desktop, WaitForPid = waitPid };
    }

    /// <summary>Short tag for log lines, so the three processes are tellable apart in one file.</summary>
    public string LogTag => Role switch
    {
        AgentRole.Service => "service",
        AgentRole.Helper => $"helper:{Desktop}",
        AgentRole.InstallService => "install",
        AgentRole.UninstallService => "uninstall",
        _ => "agent",
    };
}
