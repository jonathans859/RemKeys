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

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var client = await listener.AcceptTcpClientAsync(stoppingToken);
                await HandleClientAsync(client, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error accepting or handling a connection.");
            }
        }

        listener.Stop();
        _logger.LogInformation("KeyBridge agent stopped.");
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken token)
    {
        var address = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
        var remote = address?.ToString() ?? "unknown";

        if (!IsAllowed(address, remote, out var rejection))
        {
            _logger.LogWarning("Rejected connection from {Remote}: {Reason}", remote, rejection);
            return;
        }

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
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
            _logger.LogInformation("Peer {Remote} session ended.", remote);
            _status.Set(AgentState.Listening, $"Waiting for a connection on port {_port}");
        }
    }

    private void ProcessLine(string line)
    {
        // Parsing happens here, at the network boundary, in every mode. In
        // service mode the sink forwards canonical lines to the desktop
        // helpers, so nothing a helper injects has skipped this check.
        if (WireProtocol.TryParse(line, out var vk, out var pressed))
        {
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
