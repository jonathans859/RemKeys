namespace KeyBridgeAgent;

/// <summary>
/// Configuration bound from the "KeyBridge" section of appsettings.json. Every
/// value has a safe default so a missing or malformed config never stops the
/// service — it logs and runs with defaults instead.
/// </summary>
public sealed class KeyBridgeOptions
{
    public const string SectionName = "KeyBridge";

    /// <summary>TCP port to listen on. Must match the Apple apps' port.</summary>
    public int ListenPort { get; set; } = 5391;

    /// <summary>
    /// Optional Tailscale IP that is the only address allowed to connect. Empty
    /// means accept any peer (Tailscale already gates who can reach this host).
    /// </summary>
    public string AllowedRemoteIP { get; set; } = string.Empty;

    /// <summary>
    /// Directory for the rolling log file. Empty falls back to a "logs" folder
    /// next to the executable.
    /// </summary>
    public string LogDirectory { get; set; } = string.Empty;

    /// <summary>
    /// Lock-screen mode only: accept connections from outside Tailscale's
    /// address ranges (100.64.0.0/10 and fd7a:115c:a1e0::/48).
    ///
    /// Off by default because in that mode the listener runs as LocalSystem and
    /// can type on the secure desktop — a connection from anywhere else is a
    /// way past the lock screen. The classic in-session agent ignores this;
    /// it can only do what the signed-in user could do anyway.
    /// </summary>
    public bool AllowNonTailscalePeers { get; set; }

    /// <summary>
    /// Lock-screen mode only: accept connections from this machine itself.
    ///
    /// Off by default: with a LocalSystem listener, loopback turns any ordinary
    /// process on this PC into a way to type as SYSTEM on the secure desktop —
    /// a local privilege-escalation path that does not exist without the
    /// service.
    /// </summary>
    public bool AllowLoopbackPeers { get; set; }
}
