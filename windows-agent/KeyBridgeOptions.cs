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
}
