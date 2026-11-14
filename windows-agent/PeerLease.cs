namespace RemKeysAgent;

/// <summary>
/// The held-key lease: how this end tells a key that is still held from a
/// link that has stopped delivering.
///
/// While a key is down the link is otherwise silent, and a stalled link looks
/// exactly like a held key. Because the repeat is generated here (Windows never
/// repeats injected keys), a stall used to mean typing the letter over and over
/// until the delayed key-up finally got through, or until keepalive gave up on
/// the session ~30 s later. Field-reported 2026-11-14, from an iPhone on a
/// flaky connection.
///
/// A peer that keeps the lease sends <c>alive</c> once when it connects, then
/// every 100 ms while it holds any key. Every line it sends counts as hearing
/// from it. With the lease on:
/// <list type="bullet">
/// <item>after <see cref="PauseAfterMs"/> of silence the repeater pauses —
/// the key stays down, nothing more is typed — and it picks up again when the
/// peer is heard from;</item>
/// <item>after <see cref="ReleaseAfterMs"/> of silence every held key is
/// released, like a keyboard whose cable was pulled.</item>
/// </list>
/// A peer that never says <c>alive</c> (an app from before the lease) keeps the
/// old behaviour: nothing pauses, nothing is released early, since its silence
/// proves nothing.
///
/// Thread-safe: written from the network read loop, read from the repeat timer
/// and the session watchdog.
/// </summary>
public sealed class PeerLease
{
    /// <summary>Three and a half heartbeats: a single late packet on Wi-Fi does
    /// not stutter the repeat, a stall stops it within a few characters.</summary>
    public const long PauseAfterMs = 350;

    /// <summary>Long enough that ordinary jitter never lets go of a key the user
    /// is holding on purpose; short enough that a stuck modifier is gone before
    /// anyone has to go looking for it.</summary>
    public const long ReleaseAfterMs = 1500;

    private long _lastHeard = Environment.TickCount64;
    private volatile bool _enabled;

    /// <summary>A new session: the lease is unknown again until the peer says <c>alive</c>.</summary>
    public void Begin()
    {
        _enabled = false;
        Heard();
    }

    /// <summary>Any line from the peer arrived.</summary>
    public void Heard() => Interlocked.Exchange(ref _lastHeard, Environment.TickCount64);

    /// <summary>The peer said <c>alive</c>. Returns true the first time in a session.</summary>
    public bool Enable()
    {
        Heard();
        if (_enabled) return false;
        _enabled = true;
        return true;
    }

    public bool Enabled => _enabled;

    public long SilentForMs => Environment.TickCount64 - Interlocked.Read(ref _lastHeard);

    /// <summary>Whether a repeat may be typed right now.</summary>
    public bool RepeatAllowed => !_enabled || SilentForMs <= PauseAfterMs;

    /// <summary>Whether the peer has been quiet long enough that its held keys should be let go.</summary>
    public bool ReleaseDue => _enabled && SilentForMs > ReleaseAfterMs;
}
