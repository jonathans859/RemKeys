namespace RemKeysAgent;

/// <summary>
/// Configuration bound from the "RemKeys" section of appsettings.json. Every
/// value has a safe default so a missing or malformed config never stops the
/// service — it logs and runs with defaults instead.
/// </summary>
public sealed class RemKeysOptions
{
    public const string SectionName = "RemKeys";

    /// <summary>
    /// What this section was called before the agent was rebranded. Still read,
    /// underneath <see cref="SectionName"/>, so an appsettings.json a user
    /// edited before the rename keeps its settings instead of silently
    /// reverting to the defaults.
    /// </summary>
    public const string LegacySectionName = "KeyBridge";

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
    /// Repeat a key the peer holds down, like a locally attached keyboard.
    ///
    /// On by default because Windows does not do it for injected input at all
    /// (see <see cref="KeyRepeater"/>): without this, holding Down Arrow moves
    /// one line and stops. Turn it off if a peer already sends its own repeats
    /// and the automatic detection somehow misses it.
    /// </summary>
    public bool KeyRepeat { get; set; } = true;

    /// <summary>
    /// How long a key must be held before it starts repeating, in milliseconds.
    /// 0 follows this PC's own "Repeat delay" setting, which is what you want
    /// unless lock-screen mode is on — that listener runs as LocalSystem and so
    /// reads Windows' defaults instead of your sliders.
    /// </summary>
    public int KeyRepeatDelayMs { get; set; }

    /// <summary>
    /// Milliseconds between repeats once one starts. 0 follows this PC's own
    /// "Repeat rate" setting; see <see cref="KeyRepeatDelayMs"/> for the case
    /// where pinning a value is worth it.
    /// </summary>
    public int KeyRepeatIntervalMs { get; set; }

    /// <summary>
    /// Lock-screen mode only: how far out the circle of machines allowed to
    /// type at this PC's lock screen reaches — <c>Tailscale</c> (the default),
    /// <c>LocalNetwork</c> or <c>Any</c>. See <see cref="PeerAccess"/>.
    ///
    /// A string rather than the enum itself so a typo in a hand-edited config
    /// cannot stop the service from starting: it is parsed leniently and falls
    /// back to the safest value with a warning. Normally set from the tray
    /// menu, which writes this key.
    ///
    /// The classic in-session agent ignores it entirely; it can only do what
    /// the signed-in user could do anyway.
    /// </summary>
    public string LockScreenAccess { get; set; } = string.Empty;

    /// <summary>
    /// Superseded by <see cref="LockScreenAccess"/>, still read so an
    /// appsettings.json written before it existed keeps its meaning: true here
    /// is what <c>Any</c> is now. The tray removes this key when it writes the
    /// new one, so the file only ever states one policy.
    /// </summary>
    public bool AllowNonTailscalePeers { get; set; }

    /// <summary>
    /// Lock-screen mode only: accept connections from this machine itself even
    /// under <see cref="PeerAccess.Tailscale"/>, which otherwise refuses them —
    /// with a LocalSystem listener, loopback turns any ordinary process on this
    /// PC into a way to type as SYSTEM on the secure desktop. Kept as the local
    /// testing escape hatch; the wider two settings allow loopback anyway.
    /// </summary>
    public bool AllowLoopbackPeers { get; set; }

    /// <summary>
    /// The peer policy actually in force, resolving the current key, then the
    /// legacy boolean, then the default. <paramref name="warning"/> is non-null
    /// only when the configured value could not be understood.
    /// </summary>
    public PeerAccess ResolveLockScreenAccess(out string? warning)
    {
        warning = null;

        // IsNullOrWhiteSpace, not Trim().Length: a literal null in the JSON
        // binds as null, and this runs in the service's constructor — an NRE
        // here would be a service that will not start over a config typo.
        if (string.IsNullOrWhiteSpace(LockScreenAccess))
        {
            return AllowNonTailscalePeers ? PeerAccess.Any : PeerAccess.Tailscale;
        }

        if (PeerAccessPolicy.TryParse(LockScreenAccess, out var access)) return access;

        warning = $"LockScreenAccess \"{LockScreenAccess}\" is not one of " +
            $"{string.Join(", ", PeerAccessPolicy.All.Select(PeerAccessPolicy.Canonical))}";
        return PeerAccess.Tailscale;
    }
}
