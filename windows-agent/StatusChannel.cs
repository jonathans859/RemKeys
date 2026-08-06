using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading.Channels;

namespace KeyBridgeAgent;

/// <summary>
/// Service side of the tray link: publishes the status line to whoever is
/// showing the tray icon, and accepts exactly one command back ("stop").
///
/// This is a second pipe rather than a second use of the injection pipe, and
/// that separation is the point. The injection pipe is LocalSystem-only because
/// it types on the secure desktop; the tray runs as the signed-in user and must
/// never be able to reach it. The worst this channel grants a non-admin user is
/// stopping a service on their own console — no worse than pulling the plug.
/// </summary>
public sealed class StatusHub : BackgroundService
{
    private const int MaxClients = 4;

    private readonly ILogger<StatusHub> _logger;
    private readonly AgentStatus _status;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly List<StatusConnection> _clients = new();
    private readonly object _gate = new();

    public StatusHub(ILogger<StatusHub> logger, AgentStatus status, IHostApplicationLifetime lifetime)
    {
        _logger = logger;
        _status = status;
        _lifetime = lifetime;
    }

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
                    server = CreateServer();
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
                    _logger.LogError(ex, "Status pipe failed to accept; retrying in 2s.");
                    try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken); }
                    catch (OperationCanceledException) { break; }
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

    /// <summary>
    /// The pipe is created by LocalSystem, whose default DACL would shut the
    /// signed-in user out entirely — so the ACL is spelled out: full control
    /// for SYSTEM and administrators, read/write for whoever is logged on at
    /// the console.
    /// </summary>
    private static NamedPipeServerStream CreateServer()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
            PipeAccessRights.ReadWrite, AccessControlType.Allow));

        return NamedPipeServerStreamAcl.Create(
            PipeProtocol.StatusPipeName,
            PipeDirection.InOut,
            MaxClients,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            0,
            0,
            security);
    }

    private async Task ServeAsync(NamedPipeServerStream server, CancellationToken stoppingToken)
    {
        var connection = new StatusConnection(server);
        lock (_gate) { _clients.Add(connection); }

        // Say the current state at once, rather than leaving the tray blank
        // until something happens to change it.
        connection.Enqueue($"{PipeProtocol.Status} {_status.Description}");

        var pump = Task.Run(() => connection.PumpAsync(stoppingToken), CancellationToken.None);

        try
        {
            _logger.LogInformation("Tray client connected.");
            var reader = new LineReader();
            var buffer = new byte[512];
            int read;
            while ((read = await server.ReadAsync(buffer.AsMemory(), stoppingToken)) > 0)
            {
                foreach (var line in reader.Feed(buffer.AsSpan(0, read)))
                {
                    // Exactly one command is accepted. Anything else is noise
                    // from a client that should not be talking to us.
                    if (line.Trim() == PipeProtocol.Stop)
                    {
                        _logger.LogInformation("Tray asked the service to stop.");
                        _lifetime.StopApplication();
                    }
                    else if (line.Trim().Length > 0)
                    {
                        _logger.LogWarning("Ignoring unknown line from the tray: {Line}", line.Trim());
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogInformation("Tray client disconnected: {Message}", ex.Message);
        }
        finally
        {
            lock (_gate) { _clients.Remove(connection); }
            connection.Complete();
            try { await pump; } catch { /* already faulted */ }
            connection.Dispose();
        }
    }

    private void OnStatusChanged()
    {
        var line = $"{PipeProtocol.Status} {_status.Description}";
        StatusConnection[] targets;
        lock (_gate) { targets = _clients.ToArray(); }
        foreach (var target in targets)
        {
            target.Enqueue(line);
        }
    }

    private void DisconnectAll()
    {
        StatusConnection[] targets;
        lock (_gate) { targets = _clients.ToArray(); _clients.Clear(); }
        foreach (var target in targets)
        {
            target.Complete();
            target.Dispose();
        }
    }

    private sealed class StatusConnection : IDisposable
    {
        private readonly NamedPipeServerStream _stream;
        private readonly Channel<string> _outbound = Channel.CreateBounded<string>(
            new BoundedChannelOptions(64) { FullMode = BoundedChannelFullMode.DropOldest });

        public StatusConnection(NamedPipeServerStream stream) => _stream = stream;

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
            catch (Exception) { /* client vanished; the read side tears down */ }
        }

        public void Dispose()
        {
            try { _stream.Dispose(); } catch { /* already gone */ }
        }
    }
}

/// <summary>
/// User-session side of the tray link. Runs in the ordinary logon-task process
/// while lock-screen support is on: no listener, no injection, just the tray
/// icon and this connection.
///
/// The tray must live here rather than in a desktop helper. A helper is
/// LocalSystem, i.e. System integrity, and a screen reader running at medium
/// integrity with uiAccess cannot read the UI of a System-integrity process —
/// uiAccess reaches into elevated apps, not into SYSTEM ones. A tray icon owned
/// by a helper therefore renders an empty menu to NVDA, which is precisely the
/// status channel this app cannot afford to lose (field-reported 2026-08-06).
/// </summary>
public sealed class TrayClientWorker : BackgroundService
{
    private readonly ILogger<TrayClientWorker> _logger;
    private readonly AgentStatus _status;
    private readonly IHostApplicationLifetime _lifetime;

    private NamedPipeClientStream? _pipe;
    private volatile bool _stopRequested;

    public TrayClientWorker(ILogger<TrayClientWorker> logger, AgentStatus status, IHostApplicationLifetime lifetime)
    {
        _logger = logger;
        _status = status;
        _lifetime = lifetime;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested && !_stopRequested)
        {
            try
            {
                await RunSessionAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogInformation("Status pipe session ended: {Message}", ex.Message);
            }

            if (_stopRequested) break;

            // Unlike a desktop helper this one may reconnect freely: it injects
            // nothing, so a second copy could never type anything twice. The
            // service restarting (sc failure actions) should not cost the user
            // their tray.
            _status.SetDescription("Reconnecting to the RemKeys service…");
            try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken); }
            catch (OperationCanceledException) { break; }
        }

        if (_stopRequested)
        {
            _lifetime.StopApplication();
        }
    }

    private async Task RunSessionAsync(CancellationToken stoppingToken)
    {
        using var pipe = new NamedPipeClientStream(
            ".",
            PipeProtocol.StatusPipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);

        await pipe.ConnectAsync(stoppingToken);
        _pipe = pipe;
        _logger.LogInformation("Tray connected to the RemKeys service.");

        try
        {
            var reader = new LineReader();
            var buffer = new byte[512];
            int read;
            while ((read = await pipe.ReadAsync(buffer.AsMemory(), stoppingToken)) > 0)
            {
                foreach (var line in reader.Feed(buffer.AsSpan(0, read)))
                {
                    var trimmed = line.Trim();
                    if (trimmed.StartsWith(PipeProtocol.Status + " ", StringComparison.Ordinal))
                    {
                        _status.SetDescription(trimmed[(PipeProtocol.Status.Length + 1)..]);
                    }
                }
            }
        }
        finally
        {
            _pipe = null;
        }
    }

    /// <summary>Tray Exit: stop the service, which takes the helpers with it.</summary>
    public void RequestServiceStop()
    {
        _stopRequested = true;
        var pipe = _pipe;
        if (pipe is not null && pipe.IsConnected)
        {
            try
            {
                var bytes = Encoding.UTF8.GetBytes(PipeProtocol.Stop + "\n");
                pipe.Write(bytes, 0, bytes.Length);
                pipe.Flush();
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Could not ask the service to stop.");
            }
        }

        _lifetime.StopApplication();
    }
}
