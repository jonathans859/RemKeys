using System.Buffers;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Options;

namespace KeyBridgeAgent;

/// <summary>
/// The network loop: listens for a single Apple-side peer over TCP, reads
/// newline-framed "key &lt;vk&gt; pressed=&lt;0|1&gt;" lines, and hands each parsed
/// event to an <see cref="IKeystrokeSink"/>. One peer at a time (there is only
/// ever one keyboard); a new connection supersedes the old one.
///
/// "Supersedes" is load-bearing, not a nicety. A phone that loses its link
/// abruptly — cellular handing over between towers, a border crossing, a dead
/// spot — never gets to send a FIN, so this end is left holding a socket that
/// is alive as far as the kernel is concerned and silent forever. Accepting
/// sequentially (accept, read to EOF, accept again) meant the agent stayed
/// parked in that dead session while the phone happily reconnected: the OS
/// completes the handshake into the listen backlog on its own, so the phone
/// showed "Connected" and nothing was ever typed again until the agent process
/// was restarted. So the accept loop runs continuously and the newest peer
/// wins, and every accepted socket gets TCP keepalive so a peer that never
/// comes back is dropped (and its held keys released) instead of lingering.
///
/// The sink is what differs between installs: the in-session agent injects
/// right here, while the lock-screen service forwards to whichever desktop
/// helper is in front. Parsing and the peer policy stay on this side either
/// way, so a helper only ever sees events that already passed both.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly KeyBridgeOptions _options;
    private readonly AgentStatus _status;
    private readonly IKeystrokeSink _sink;
    private readonly AgentMode _mode;
    /// <summary>Keys the current peer has pressed and not released yet.</summary>
    private readonly HashSet<ushort> _held = new();
    /// <summary>Types a held key over and over; Windows will not do it for injected input.</summary>
    private readonly KeyRepeater _repeater;
    private int _port;

    public Worker(
        ILogger<Worker> logger,
        IOptions<KeyBridgeOptions> options,
        AgentStatus status,
        IKeystrokeSink sink,
        AgentMode mode)
    {
        _logger = logger;
        _options = options.Value;
        _status = status;
        _sink = sink;
        _mode = mode;
        _repeater = new KeyRepeater(sink, _options, logger);
    }

    public override void Dispose()
    {
        _repeater.Dispose();
        base.Dispose();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var port = _options.ListenPort is > 0 and < 65536 ? _options.ListenPort : 5391;
        _port = port;
        if (port != _options.ListenPort)
        {
            _logger.LogWarning("Configured ListenPort {Configured} is invalid; using {Fallback}.",
                _options.ListenPort, port);
        }

        var listener = new TcpListener(IPAddress.Any, port);

        // Never crash on a bad config or a busy port — log and idle, retrying,
        // so the service stays installed and recovers on its own.
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                listener.Start();
                _logger.LogInformation("KeyBridge agent listening on port {Port}.", port);
                _status.Set(AgentState.Listening, $"Waiting for a connection on port {port}");
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Could not start listener on port {Port}; retrying in 10s.", port);
                _status.Set(AgentState.PortBlocked, $"Port {port} is busy — retrying");
                await SafeDelay(TimeSpan.FromSeconds(10), stoppingToken);
            }
        }

        // The current session runs as its own task so this loop can keep
        // accepting. Nothing else runs concurrently: a new peer is only started
        // after the previous session has been closed *and* awaited, which is
        // what lets _held stay lock-free and keeps the old session's
        // "released N keys" and status reset ahead of the new peer's log line.
        TcpClient? currentClient = null;
        var currentRemote = string.Empty;
        var currentSession = Task.CompletedTask;

        while (!stoppingToken.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                // Never let a bad accept spin the loop hot.
                _logger.LogError(ex, "Error accepting a connection; retrying in 1s.");
                await SafeDelay(TimeSpan.FromSeconds(1), stoppingToken);
                continue;
            }

            var address = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
            var remote = address?.ToString() ?? "unknown";

            // Check the peer policy BEFORE dropping the live session, or any
            // stranger who can reach the port could cut off the real keyboard
            // just by connecting once.
            if (!IsAllowed(address, remote, out var rejection))
            {
                _logger.LogWarning("Rejected connection from {Remote}: {Reason}", remote, rejection);
                CloseQuietly(client);
                continue;
            }

            if (!currentSession.IsCompleted)
            {
                _logger.LogInformation(
                    "Peer {Remote} connected while {Previous} was still connected; dropping the older connection.",
                    remote, currentRemote);
                // Close the socket rather than cancelling the read: a pending
                // socket read is not reliably interruptible by a token, but
                // closing the handle always makes it throw.
                CloseQuietly(currentClient);
            }

            await currentSession;

            currentClient = client;
            currentRemote = remote;
            currentSession = RunSessionAsync(client, remote, stoppingToken);
        }

        CloseQuietly(currentClient);
        await currentSession;
        listener.Stop();
        _logger.LogInformation("KeyBridge agent stopped.");
    }

    /// <summary>
    /// Owns one peer session end to end, so the accept loop can move on and a
    /// failure here can never take the listener down with it.
    /// </summary>
    private async Task RunSessionAsync(TcpClient client, string remote, CancellationToken token)
    {
        try
        {
            using (client)
            {
                await HandleClientAsync(client, remote, token);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error handling the connection from {Remote}.", remote);
        }
    }

    private void CloseQuietly(TcpClient? client)
    {
        if (client is null) return;
        try { client.Close(); }
        catch (Exception ex) { _logger.LogDebug(ex, "Ignoring error while closing a connection."); }
    }

    private async Task HandleClientAsync(TcpClient client, string remote, CancellationToken token)
    {
        ConfigureKeepAlive(client.Client, remote);

        _repeater.BeginSession();
        _logger.LogInformation("Peer connected from {Remote}.", remote);
        _status.Set(AgentState.Connected, $"Connected to {remote}");
        client.NoDelay = true;

        using var stream = client.GetStream();
        var reader = new LineReader();
        var buffer = ArrayPool<byte>.Shared.Rent(4096);
        try
        {
            int read;
            while ((read = await stream.ReadAsync(buffer.AsMemory(), token)) > 0)
            {
                foreach (var line in reader.Feed(buffer.AsSpan(0, read)))
                {
                    ProcessLine(line);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException ex)
        {
            _logger.LogInformation("Peer {Remote} disconnected: {Message}", remote, ex.Message);
        }
        catch (ObjectDisposedException)
        {
            // The socket was closed under us — this session was superseded by a
            // newer peer, or the host is shutting down. Not an error.
            _logger.LogInformation("Peer {Remote} session was closed.", remote);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
            // Before the releases below, so nothing re-presses a key on its way out.
            _repeater.Stop();
            ReleaseHeldKeys(remote);
            _logger.LogInformation("Peer {Remote} session ended.", remote);
            _status.Set(AgentState.Listening, $"Waiting for a connection on port {_port}");
        }
    }

    /// <summary>
    /// Turn on TCP keepalive for an accepted peer, aggressively.
    ///
    /// Windows leaves keepalive off unless a socket asks for it, and its
    /// default idle time is two hours even then — so a peer that vanishes
    /// without closing its socket (a phone whose cellular link drops mid-
    /// session, which is the common case on the move) would otherwise leave
    /// this session readable-forever-but-silent, holding down whatever keys it
    /// left pressed. Roughly 15s idle plus three probes 5s apart puts the
    /// detection at about half a minute, cheap on a link that carries
    /// keystrokes anyway.
    ///
    /// Never fatal: on a Windows build that refuses one of these the session
    /// still runs, it just falls back to being superseded by the next peer.
    /// </summary>
    private void ConfigureKeepAlive(Socket socket, string remote)
    {
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 15);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 5);
            // Windows 10 1703+; set last so the three above still apply if it throws.
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "Could not fully configure TCP keepalive for {Remote}; a silently dropped peer may take " +
                "longer to notice.", remote);
        }
    }

    /// <summary>
    /// Let go of every key the peer left down when its session ended. The
    /// Apple side can hold a key on purpose — the iOS key pad's hold gesture
    /// keeps one down for as long as the finger is on it, and a physical key
    /// can still be down when forwarding stops — and if the socket dies in
    /// that window, the matching release line never arrives and Windows
    /// repeats that key forever. Only this end can clean that up: the sender
    /// is already gone. The desktop helpers do the same thing when their
    /// desktop leaves the foreground; this covers the network case, in every
    /// mode. Sessions are handled one at a time, so no locking is needed.
    /// </summary>
    private void ReleaseHeldKeys(string remote)
    {
        if (_held.Count == 0) return;

        _logger.LogInformation("Releasing {Count} key(s) left down by {Remote}.", _held.Count, remote);
        foreach (var vk in _held)
        {
            _sink.Key(vk, false);
        }
        _held.Clear();
    }

    private void ProcessLine(string line)
    {
        // Parsing happens here, at the network boundary, in every mode. In
        // service mode the sink forwards canonical lines to the desktop
        // helpers, so nothing a helper injects has skipped this check.
        if (WireProtocol.TryParse(line, out var vk, out var pressed))
        {
            if (pressed)
            {
                // A second press for a key already held is the peer forwarding
                // its own OS's key repeat (macOS does); the repeater then leaves
                // that key alone instead of repeating it a second time.
                if (_held.Add(vk)) _repeater.Pressed(vk); else _repeater.NotePeerRepeat(vk);
            }
            else
            {
                _held.Remove(vk);
                _repeater.Released(vk);
            }
            _sink.Key(vk, pressed);
        }
        else if (WireProtocol.TryParseChar(line, out var codepoint))
        {
            _sink.Char(codepoint);
        }
        else if (line.Trim().Length > 0)
        {
            // Unparseable, non-blank line: surface it rather than dropping it
            // silently, so protocol gaps are visible.
            _logger.LogWarning("Ignoring malformed line: {Line}", line);
        }
    }

    private bool IsAllowed(IPAddress? address, string remote, out string rejection)
    {
        rejection = string.Empty;

        var allowed = _options.AllowedRemoteIP.Trim();
        if (allowed.Length > 0)
        {
            if (string.Equals(remote, allowed, StringComparison.OrdinalIgnoreCase)) return true;
            rejection = "not the allowed IP";
            return false;
        }

        // Everything below only applies to lock-screen mode. The in-session
        // agent keeps its old, laxer policy on purpose: it types as the
        // signed-in user, on that user's own desktop, so a local connection
        // buys an attacker nothing they did not already have.
        if (_mode.Role != AgentRole.Service) return true;

        if (address is null)
        {
            rejection = "the peer address could not be read";
            return false;
        }

        if (IPAddress.IsLoopback(address) && !_options.AllowLoopbackPeers)
        {
            // The listener is LocalSystem and can type on the secure desktop:
            // loopback would let any process on this PC escalate to SYSTEM
            // input. Set AllowLoopbackPeers to override for local testing.
            rejection = "loopback is not allowed while lock screen support is on";
            return false;
        }

        if (!_options.AllowNonTailscalePeers && !IsTailscaleAddress(address) && !IPAddress.IsLoopback(address))
        {
            rejection = "not a Tailscale address (set AllowNonTailscalePeers to override)";
            return false;
        }

        return true;
    }

    /// <summary>
    /// Tailscale hands out IPv4 from the CGNAT block 100.64.0.0/10 and IPv6
    /// from fd7a:115c:a1e0::/48. Anything else reached this port over a plain
    /// LAN or a forwarded port, which is not the threat model.
    /// </summary>
    private static bool IsTailscaleAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();

        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var octets = address.GetAddressBytes();
            return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            var bytes = address.GetAddressBytes();
            return bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11 && bytes[3] == 0x5C
                && bytes[4] == 0xA1 && bytes[5] == 0xE0;
        }

        return false;
    }

    private static async Task SafeDelay(TimeSpan delay, CancellationToken token)
    {
        try { await Task.Delay(delay, token); } catch (OperationCanceledException) { }
    }
}

/// <summary>Reassembles newline-delimited text from arbitrary byte chunks.</summary>
internal sealed class LineReader
{
    private readonly StringBuilder _pending = new();

    public IEnumerable<string> Feed(ReadOnlySpan<byte> bytes)
    {
        _pending.Append(Encoding.UTF8.GetString(bytes));
        var result = new List<string>();
        int newline;
        while ((newline = IndexOfNewline(out var length)) >= 0)
        {
            result.Add(_pending.ToString(0, newline));
            _pending.Remove(0, newline + length);
        }
        return result;
    }

    private int IndexOfNewline(out int length)
    {
        for (int i = 0; i < _pending.Length; i++)
        {
            if (_pending[i] == '\n') { length = 1; return i; }
            if (_pending[i] == '\r')
            {
                length = (i + 1 < _pending.Length && _pending[i + 1] == '\n') ? 2 : 1;
                return i;
            }
        }
        length = 0;
        return -1;
    }
}
