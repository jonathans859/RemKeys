using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Threading.Channels;

namespace KeyBridgeAgent;

/// <summary>
/// The service→helper link. Deliberately the same newline-framed text as the
/// network wire format, so the helper reuses <see cref="WireProtocol"/> and
/// <see cref="LineReader"/> verbatim; the service re-emits canonical lines
/// after parsing, so a helper never sees anything the parser hasn't approved.
/// </summary>
public static class PipeProtocol
{
    /// <summary>Full path is <c>\\.\pipe\KeyBridgeAgent.inject</c>.</summary>
    public const string PipeName = "KeyBridgeAgent.inject";

    /// <summary>Helper→service, once on connect: <c>hello &lt;desktop&gt;</c>.</summary>
    public const string Hello = "hello";

    /// <summary>Service→helper: <c>status &lt;text&gt;</c>, for the tray tooltip.</summary>
    public const string Status = "status";

    /// <summary>Helper→service: the tray's Exit item. Stops the whole service.</summary>
    public const string Stop = "stop";

    public static string KeyLine(ushort vk, bool pressed) => $"key {vk} pressed={(pressed ? 1 : 0)}";

    public static string CharLine(int codepoint) => $"char {codepoint}";
}

/// <summary>
/// Where a parsed key event goes. Standalone injects it directly; the service
/// hands it to whichever desktop helper is currently in front.
/// </summary>
public interface IKeystrokeSink
{
    void Key(ushort vk, bool pressed);
    void Char(int codepoint);
}

/// <summary>Standalone mode: inject right here, on this process's desktop.</summary>
public sealed class LocalKeystrokeSink : IKeystrokeSink
{
    private readonly ILogger<LocalKeystrokeSink> _logger;

    public LocalKeystrokeSink(ILogger<LocalKeystrokeSink> logger) => _logger = logger;

    public void Key(ushort vk, bool pressed)
    {
        if (!KeystrokeInjector.Send(vk, pressed))
        {
            _logger.LogWarning("SendInput rejected vk={Vk} pressed={Pressed}.", vk, pressed);
        }
    }

    public void Char(int codepoint)
    {
        if (!KeystrokeInjector.SendUnicode(codepoint))
        {
            _logger.LogWarning("SendInput rejected unicode codepoint={Codepoint}.", codepoint);
        }
    }
}

/// <summary>
/// Service mode: a named-pipe server that broadcasts every event to all
/// connected desktop helpers. Routing is the helpers' job — each one injects
/// only while its own desktop is the one receiving input, which keeps the
/// decision on the side that can actually observe it (session 0 cannot see the
/// interactive session's desktops at all).
/// </summary>
public sealed class InjectionHub : BackgroundService, IKeystrokeSink
{
    private const int MaxHelpers = 4;

    private readonly ILogger<InjectionHub> _logger;
    private readonly AgentStatus _status;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly List<HelperConnection> _clients = new();
    private readonly object _gate = new();

    public InjectionHub(ILogger<InjectionHub> logger, AgentStatus status, IHostApplicationLifetime lifetime)
    {
        _logger = logger;
        _status = status;
        _lifetime = lifetime;
    }

    public void Key(ushort vk, bool pressed) => Broadcast(PipeProtocol.KeyLine(vk, pressed));

    public void Char(int codepoint) => Broadcast(PipeProtocol.CharLine(codepoint));

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _status.Changed += OnStatusChanged;
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                NamedPipeServerStream? server = null;
                try
                {
                    // No explicit ACL: a pipe created by LocalSystem inherits
                    // that token's default DACL, which grants SYSTEM and
                    // Administrators only. The connect-time SID check below is
                    // the belt to that braces — this channel types into the
                    // secure desktop, so a medium-IL client must never be able
                    // to drive it.
                    server = new NamedPipeServerStream(
                        PipeProtocol.PipeName,
                        PipeDirection.InOut,
                        MaxHelpers,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);

                    await server.WaitForConnectionAsync(stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    server?.Dispose();
                    break;
                }
                catch (Exception ex)
                {
                    server?.Dispose();
                    _logger.LogError(ex, "Injection pipe failed to accept; retrying in 2s.");
                    await SafeDelay(TimeSpan.FromSeconds(2), stoppingToken);
                    continue;
                }

                if (!ClientIsLocalSystem(server))
                {
                    _logger.LogWarning("Rejected an injection-pipe client that is not LocalSystem.");
                    server.Dispose();
                    continue;
                }

                _ = Task.Run(() => ServeAsync(server, stoppingToken), CancellationToken.None);
            }
        }
        finally
        {
            _status.Changed -= OnStatusChanged;
            DisconnectAll();
        }
    }

    private async Task ServeAsync(NamedPipeServerStream server, CancellationToken stoppingToken)
    {
        var connection = new HelperConnection(server);
        lock (_gate) { _clients.Add(connection); }

        // Whatever the current status is, the freshly connected tray should say
        // it immediately rather than waiting for the next change.
        connection.Enqueue($"{PipeProtocol.Status} {_status.Description}");

        var pump = Task.Run(() => connection.PumpAsync(stoppingToken), CancellationToken.None);

        try
        {
            var reader = new LineReader();
            var buffer = new byte[1024];
            int read;
            while ((read = await server.ReadAsync(buffer.AsMemory(), stoppingToken)) > 0)
            {
                foreach (var line in reader.Feed(buffer.AsSpan(0, read)))
                {
                    HandleHelperLine(connection, line);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogInformation("Helper {Desktop} pipe closed: {Message}", connection.Desktop, ex.Message);
        }
        finally
        {
            lock (_gate) { _clients.Remove(connection); }
            connection.Complete();
            try { await pump; } catch { /* pump already faulted; nothing to salvage */ }
            connection.Dispose();
            _logger.LogInformation("Helper for desktop {Desktop} disconnected.", connection.Desktop);
        }
    }

    private void HandleHelperLine(HelperConnection connection, string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return;

        var space = trimmed.IndexOf(' ');
        var verb = space < 0 ? trimmed : trimmed[..space];
        var rest = space < 0 ? string.Empty : trimmed[(space + 1)..].Trim();

        switch (verb)
        {
            case PipeProtocol.Hello:
                connection.Desktop = rest.Length > 0 ? rest : "unknown";
                _logger.LogInformation("Helper for desktop {Desktop} connected.", connection.Desktop);
                break;
            case PipeProtocol.Stop:
                _logger.LogInformation("Helper for desktop {Desktop} asked the service to stop.", connection.Desktop);
                _lifetime.StopApplication();
                break;
            default:
                _logger.LogWarning("Ignoring unknown line from helper {Desktop}: {Line}", connection.Desktop, trimmed);
                break;
        }
    }

    private void OnStatusChanged() => Broadcast($"{PipeProtocol.Status} {_status.Description}");

    private void Broadcast(string line)
    {
        HelperConnection[] targets;
        lock (_gate) { targets = _clients.ToArray(); }
        foreach (var target in targets)
        {
            if (!target.Enqueue(line))
            {
                _logger.LogWarning("Helper {Desktop} is not draining the pipe; dropped a line.", target.Desktop);
            }
        }
    }

    private void DisconnectAll()
    {
        HelperConnection[] targets;
        lock (_gate) { targets = _clients.ToArray(); _clients.Clear(); }
        foreach (var target in targets)
        {
            target.Complete();
            target.Dispose();
        }
    }

    /// <summary>
    /// Compare the connecting client's SID against the well-known LocalSystem
    /// SID rather than its account name — the name is localised ("NT-AUTORITÄT"
    /// on a German install) and would fail open on a translated Windows.
    /// </summary>
    private static bool ClientIsLocalSystem(NamedPipeServerStream server)
    {
        SecurityIdentifier? sid = null;
        try
        {
            server.RunAsClient(() =>
            {
                using var identity = WindowsIdentity.GetCurrent();
                sid = identity.User;
            });
        }
        catch (Exception)
        {
            return false;
        }
        return sid is not null && sid.IsWellKnown(WellKnownSidType.LocalSystemSid);
    }

    private static async Task SafeDelay(TimeSpan delay, CancellationToken token)
    {
        try { await Task.Delay(delay, token); } catch (OperationCanceledException) { }
    }

    /// <summary>
    /// One connected helper. Writes go through a bounded queue so a wedged
    /// helper can never block the network reader — keystrokes are worthless
    /// once late, so a full queue drops rather than waits.
    /// </summary>
    private sealed class HelperConnection : IDisposable
    {
        private readonly NamedPipeServerStream _stream;
        private readonly Channel<string> _outbound = Channel.CreateBounded<string>(
            new BoundedChannelOptions(2048) { FullMode = BoundedChannelFullMode.DropWrite });

        public HelperConnection(NamedPipeServerStream stream) => _stream = stream;

        public string Desktop { get; set; } = "unknown";

        public bool Enqueue(string line) => _outbound.Writer.TryWrite(line);

        public void Complete() => _outbound.Writer.TryComplete();

        public async Task PumpAsync(CancellationToken token)
        {
            try
            {
                await foreach (var line in _outbound.Reader.ReadAllAsync(token))
                {
                    var bytes = Encoding.UTF8.GetBytes(line + "\n");
                    await _stream.WriteAsync(bytes.AsMemory(), token);
                    await _stream.FlushAsync(token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception)
            {
                // Helper went away mid-write; the read side will notice and
                // tear the connection down.
            }
        }

        public void Dispose()
        {
            try { _stream.Dispose(); } catch { /* already gone */ }
        }
    }
}
