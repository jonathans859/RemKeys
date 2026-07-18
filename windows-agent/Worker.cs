using System.Buffers;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Options;

namespace KeyBridgeAgent;

/// <summary>
/// The service loop: listens for a single Apple-side peer over TCP, reads
/// newline-framed "key &lt;vk&gt; pressed=&lt;0|1&gt;" lines, and replays each as a
/// real keystroke. One peer at a time (there is only ever one keyboard); a new
/// connection supersedes the old one.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly KeyBridgeOptions _options;
    private readonly AgentStatus _status;
    private int _port;

    public Worker(ILogger<Worker> logger, IOptions<KeyBridgeOptions> options, AgentStatus status)
    {
        _logger = logger;
        _options = options.Value;
        _status = status;
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
        var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "unknown";

        if (!IsAllowed(remote))
        {
            _logger.LogWarning("Rejected connection from {Remote} (not the allowed IP).", remote);
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
        if (WireProtocol.TryParse(line, out var vk, out var pressed))
        {
            if (!KeystrokeInjector.Send(vk, pressed))
            {
                _logger.LogWarning("SendInput rejected vk={Vk} pressed={Pressed}.", vk, pressed);
            }
        }
        else if (WireProtocol.TryParseChar(line, out var codepoint))
        {
            if (!KeystrokeInjector.SendUnicode(codepoint))
            {
                _logger.LogWarning("SendInput rejected unicode codepoint={Codepoint}.", codepoint);
            }
        }
        else if (line.Trim().Length > 0)
        {
            // Unparseable, non-blank line: surface it rather than dropping it
            // silently, so protocol gaps are visible.
            _logger.LogWarning("Ignoring malformed line: {Line}", line);
        }
    }

    private bool IsAllowed(string remote)
    {
        if (string.IsNullOrWhiteSpace(_options.AllowedRemoteIP)) return true;
        return string.Equals(remote, _options.AllowedRemoteIP.Trim(), StringComparison.OrdinalIgnoreCase);
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
