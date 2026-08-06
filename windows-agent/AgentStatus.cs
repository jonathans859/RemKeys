namespace KeyBridgeAgent;

public enum AgentState
{
    Starting,
    PortBlocked,
    Listening,
    Connected,
}

/// <summary>
/// Live agent status shared between the worker (writer) and the tray icon
/// (reader). Thread-safe: the worker sets it from the service loop, the tray
/// reads it on its UI thread via <see cref="Changed"/>.
/// </summary>
public sealed class AgentStatus
{
    private readonly object _gate = new();
    private AgentState _state = AgentState.Starting;
    private string _detail = "Starting";

    /// <summary>
    /// Whether the process runs elevated. Set once in Program before the host
    /// starts. Un-elevated matters enough to surface in every status text:
    /// SendInput into uiAccess windows (screen-reader dialogs) and elevated
    /// windows is silently discarded by UIPI — the injection APIs report
    /// success, so this flag is the only visible symptom.
    /// </summary>
    public bool IsElevated { get; set; } = true;

    /// <summary>Raised after every Set, on the caller's thread.</summary>
    public event Action? Changed;

    public void Set(AgentState state, string detail)
    {
        lock (_gate)
        {
            _state = state;
            _detail = detail;
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Adopt a status line verbatim. Used by a desktop helper, whose status is
    /// really the service's — the helper has no listener of its own to describe,
    /// and the text arriving over the pipe already carries any marker.
    /// </summary>
    public void SetDescription(string description)
    {
        lock (_gate)
        {
            _detail = description;
        }
        Changed?.Invoke();
    }

    public AgentState State
    {
        get { lock (_gate) { return _state; } }
    }

    /// <summary>
    /// Human-readable status line, e.g. "Connected to 100.64.0.7". Doubles as
    /// the tray tooltip, which is exactly what a screen reader announces for
    /// the tray item — keep it a plain sentence.
    /// </summary>
    public string Description
    {
        get
        {
            string detail;
            lock (_gate) { detail = _detail; }
            return IsElevated ? detail : detail + " — not elevated!";
        }
    }
}
