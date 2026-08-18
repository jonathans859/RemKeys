using System.Runtime.InteropServices;

namespace KeyBridgeAgent;

/// <summary>
/// Types a held key over and over, the way a keyboard attached to this PC
/// would.
///
/// Windows does <b>not</b> auto-repeat injected keys. Typematic repeat is
/// produced below <c>SendInput</c> — the i8042/HID class driver repeats the
/// make code of the key it sees held, and the input stack turns that into the
/// stream of WM_KEYDOWNs an app reads as "still going". An injected key-down
/// enters above that layer: the key is genuinely down (GetAsyncKeyState and
/// games reading raw input agree, which is exactly why a held key *looks* like
/// it works) but nothing ever repeats it, so holding Down Arrow moves the caret
/// one line and stops. Field-reported 2026-08-18.
///
/// The Apple ends cannot paper over this by themselves: iOS delivers
/// <c>pressesBegan</c> once per physical press and GCKeyboard only reports
/// transitions, so there is nothing there to forward. The repeat is generated
/// here instead, from the PC's own keyboard delay and rate — the settings the
/// user already tuned for every other keyboard on this machine. It covers the
/// iOS key pad's hold gesture at the same time, which promises exactly this.
///
/// macOS is the exception, and it needs no flag: its event tap receives repeat
/// key-downs from macOS and forwards them, so that peer sends a second
/// <c>pressed=1</c> for a key it is already holding. That duplicate is the
/// signal — see <see cref="NotePeerRepeat"/> — and this repeater stands down
/// for the rest of the session rather than repeating on top of it.
///
/// Typematic semantics, deliberately: only the most recently pressed repeatable
/// key repeats (pressing another key moves the repeat to it, and releasing the
/// repeating key stops it without resuming the earlier one), and modifiers, the
/// lock keys and media keys never repeat — a repeating Shift buys nothing and
/// upsets Sticky Keys and screen readers.
/// </summary>
public sealed class KeyRepeater : IDisposable
{
    /// <summary>
    /// Extra wait before the very first repeat of a session, while it is still
    /// unknown whether the peer repeats by itself. macOS's own first repeat
    /// (~375 ms by default) then lands inside this grace and is recognised
    /// before a single doubled keystroke is typed.
    /// </summary>
    private static readonly TimeSpan UnknownPeerGrace = TimeSpan.FromMilliseconds(250);

    /// <summary>
    /// Keys that are held as state rather than typed: modifiers, the three
    /// locks, and the media/volume keys. Repeating them ranges from pointless
    /// to harmful (Caps Lock would toggle at 30 Hz).
    /// </summary>
    private static readonly HashSet<ushort> NonRepeating = new()
    {
        0x10, 0xA0, 0xA1,       // VK_SHIFT, VK_LSHIFT, VK_RSHIFT
        0x11, 0xA2, 0xA3,       // VK_CONTROL, VK_LCONTROL, VK_RCONTROL
        0x12, 0xA4, 0xA5,       // VK_MENU, VK_LMENU, VK_RMENU (AltGr)
        0x5B, 0x5C,             // VK_LWIN, VK_RWIN
        0x14,                   // VK_CAPITAL (Caps Lock)
        0x90, 0x91,             // VK_NUMLOCK, VK_SCROLL
        0x2C,                   // VK_SNAPSHOT (Print Screen)
        0xAD, 0xAE, 0xAF,       // volume mute / down / up
        0xB0, 0xB1, 0xB2, 0xB3, // media next / prev / stop / play-pause
    };

    private readonly IKeystrokeSink _sink;
    private readonly KeyBridgeOptions _options;
    private readonly ILogger _logger;

    private readonly object _gate = new();
    private readonly Timer _timer;

    /// <summary>The key currently repeating, or null when nothing is.</summary>
    private ushort? _key;
    /// <summary>When the live arm is due (<c>Environment.TickCount64</c>), so an
    /// early callback left over from a previous arm can recognise itself.</summary>
    private long _dueAt = long.MaxValue;
    /// <summary>Null while it is still unknown whether this peer repeats by itself.</summary>
    private bool? _peerRepeats;
    private bool _disposed;

    public KeyRepeater(IKeystrokeSink sink, KeyBridgeOptions options, ILogger logger)
    {
        _sink = sink;
        _options = options;
        _logger = logger;
        _timer = new Timer(OnTick, null, Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>A new peer: nothing is held, and its repeat behaviour is unknown again.</summary>
    public void BeginSession()
    {
        lock (_gate)
        {
            Disarm();
            _peerRepeats = null;
        }
    }

    /// <summary>A key the peer was not already holding went down.</summary>
    public void Pressed(ushort vk)
    {
        if (!_options.KeyRepeat || NonRepeating.Contains(vk)) return;

        lock (_gate)
        {
            if (_disposed || _peerRepeats == true) return;

            _key = vk;
            var delay = InitialDelay();
            if (_peerRepeats is null) delay += UnknownPeerGrace;
            Arm(delay);
        }
    }

    /// <summary>A key went up. Stops the repeat if that was the repeating one.</summary>
    public void Released(ushort vk)
    {
        lock (_gate)
        {
            if (_key != vk) return;
            Disarm();
        }
    }

    /// <summary>
    /// The peer sent a second press for a key it is already holding, i.e. it
    /// forwards its own OS's key repeat (macOS does). Stand down for the rest
    /// of the session, so the key does not repeat at two rates at once.
    /// </summary>
    public void NotePeerRepeat(ushort vk)
    {
        lock (_gate)
        {
            if (_peerRepeats == true) return;
            _peerRepeats = true;
            Disarm();
        }

        _logger.LogInformation(
            "Peer sends its own key repeat (vk={Vk}); leaving repeat to it for this session.", vk);
    }

    /// <summary>Session over (or its held keys are being released). Stop repeating.</summary>
    public void Stop()
    {
        lock (_gate)
        {
            Disarm();
        }
    }

    private void OnTick(object? state)
    {
        ushort vk;
        lock (_gate)
        {
            if (_disposed) return;
            if (_key is not { } current) return;
            // A callback queued by an earlier arm can still run after the timer
            // was re-armed for another key; it is early for the live arm, which
            // will fire on its own. Without this, pressing a second key just as
            // the first one's delay elapses repeats it immediately.
            if (Environment.TickCount64 + TimerSlackMs < _dueAt) return;

            vk = current;

            // Surviving the grace period is the proof that this peer does not
            // repeat by itself; later holds start at the plain delay.
            _peerRepeats ??= false;

            Arm(RepeatInterval());
        }

        // Outside the lock: the sink writes to a pipe or calls SendInput, and
        // must not block a press or release arriving on the network thread. A
        // release racing this send is harmless — it disarms the timer and is
        // followed by its own key-up line, so nothing stays down.
        _sink.Key(vk, true);
    }

    /// <summary>Arm the one-shot timer. The caller holds the lock.</summary>
    private void Arm(TimeSpan delay)
    {
        _dueAt = Environment.TickCount64 + (long)delay.TotalMilliseconds;
        _timer.Change(delay, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Stop repeating and forget the held key. The caller holds the lock.</summary>
    private void Disarm()
    {
        _key = null;
        _dueAt = long.MaxValue;
        _timer.Change(Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>
    /// How long a key must be held before it starts repeating. Follows the PC's
    /// own setting (Control Panel's "Repeat delay", SPI_GETKEYBOARDDELAY: 0-3 =
    /// 250/500/750/1000 ms) unless the config pins a value.
    ///
    /// One caveat, and it is why the override exists: in lock-screen mode this
    /// runs as LocalSystem, which has its own profile, so it reads Windows'
    /// defaults rather than the signed-in user's sliders.
    /// </summary>
    private TimeSpan InitialDelay()
    {
        if (_options.KeyRepeatDelayMs > 0)
        {
            return TimeSpan.FromMilliseconds(Math.Clamp(_options.KeyRepeatDelayMs, 100, 5000));
        }

        var index = Math.Clamp(ReadSystemParameter(SPI_GETKEYBOARDDELAY, fallback: 1), 0, 3);
        return TimeSpan.FromMilliseconds(250 * (index + 1));
    }

    /// <summary>
    /// The gap between repeats. Follows "Repeat rate" (SPI_GETKEYBOARDSPEED,
    /// 0-31), which Windows documents as roughly 2.5 to 30 repeats per second,
    /// linear in the setting.
    /// </summary>
    private TimeSpan RepeatInterval()
    {
        if (_options.KeyRepeatIntervalMs > 0)
        {
            return TimeSpan.FromMilliseconds(Math.Clamp(_options.KeyRepeatIntervalMs, 10, 2000));
        }

        var speed = Math.Clamp(ReadSystemParameter(SPI_GETKEYBOARDSPEED, fallback: 31), 0, 31);
        var perSecond = 2.5 + speed * (27.5 / 31.0);
        return TimeSpan.FromMilliseconds(1000.0 / perSecond);
    }

    /// <summary>
    /// Read live rather than cached, so moving the sliders takes effect on the
    /// next held key. Never throws: a refusal falls back to the Windows default
    /// for that setting.
    /// </summary>
    private int ReadSystemParameter(uint action, int fallback)
    {
        try
        {
            int value = 0;
            if (SystemParametersInfoW(action, 0, ref value, 0)) return value;
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Could not read keyboard repeat setting {Action}; using the default.", action);
        }
        return fallback;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            _key = null;
        }
        _timer.Dispose();
    }

    /// <summary>System timers fire a little early or late; anything within this
    /// of the due time is the live arm, not a leftover.</summary>
    private const long TimerSlackMs = 16;

    private const uint SPI_GETKEYBOARDSPEED = 0x000A;
    private const uint SPI_GETKEYBOARDDELAY = 0x0016;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfoW(uint action, uint param, ref int value, uint winIni);
}
