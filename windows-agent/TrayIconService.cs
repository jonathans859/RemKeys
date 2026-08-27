using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Extensions.Options;

namespace RemKeysAgent;

/// <summary>
/// System-tray presence for the otherwise windowless agent: an icon whose
/// tooltip and context menu carry the live status (waiting / connected /
/// port busy, plus a "not elevated" marker), an item that switches lock-screen
/// support on or off, and an Exit item that stops the agent cleanly. The
/// tooltip text is what a screen reader announces when navigating the tray, so
/// it is the accessible status channel — full sentences, no icon-only state.
///
/// Runs in standalone mode and in the Default-desktop helper; which of those
/// it is only shows through <see cref="ITrayHost"/>.
/// </summary>
public sealed class TrayIconService : IHostedService
{
    private readonly AgentStatus _status;
    private readonly ITrayHost _host;
    private readonly RemKeysOptions _options;
    private readonly ILogger<TrayIconService> _logger;

    private Thread? _uiThread;
    private Control? _marshal;           // handle-owning control to hop onto the UI thread
    private NotifyIcon? _icon;
    private ToolStripMenuItem? _statusItem;
    private nint _iconHandle;

    public TrayIconService(
        AgentStatus status,
        ITrayHost host,
        IOptions<RemKeysOptions> options,
        ILogger<TrayIconService> logger)
    {
        _status = status;
        _host = host;
        _options = options.Value;
        _logger = logger;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _uiThread = new Thread(RunTray)
        {
            Name = "TrayIcon",
            IsBackground = true,
        };
        _uiThread.SetApartmentState(ApartmentState.STA);
        _uiThread.Start();
        return Task.CompletedTask;
    }

    private void RunTray()
    {
        try
        {
            var marshal = new Control();
            _ = marshal.Handle; // force handle creation so BeginInvoke works

            _statusItem = new ToolStripMenuItem(_status.Description) { Enabled = false };
            var menu = new ContextMenuStrip();
            menu.Items.Add(_statusItem);
            menu.Items.Add(new ToolStripMenuItem(_host.ModeLine) { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(_host.ToggleLabel, null, (_, _) => SafeInvoke(_host.Toggle));
            AddPeerMenu(menu);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("About RemKeys agent…", null, (_, _) => SafeInvoke(ShowAbout));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit RemKeys agent…", null, (_, _) => SafeInvoke(ConfirmAndExit));

            _icon = new NotifyIcon
            {
                Icon = CreateIcon(out _iconHandle),
                ContextMenuStrip = menu,
                Visible = true,
            };

            _marshal = marshal;
            _status.Changed += OnStatusChanged;
            UpdateTexts();

            Application.Run();
        }
        catch (Exception ex)
        {
            // The tray is a convenience — its death must never take the
            // keystroke service down with it.
            _logger.LogError(ex, "Tray icon thread failed; agent continues without a tray icon.");
        }
    }

    /// <summary>
    /// The "who may type at the lock screen" submenu — present only in
    /// lock-screen mode, since that is the only mode with a peer policy at all.
    ///
    /// The setting in force is the submenu's own label rather than a line
    /// inside it, so a screen reader announces it in passing and only someone
    /// who wants to change it has to open the submenu. The three choices are
    /// checkable items: a radio group is what this is, and NVDA reads the
    /// checked one without any extra wording.
    /// </summary>
    private void AddPeerMenu(ContextMenuStrip menu)
    {
        var peers = _host.Peers;
        if (peers is null) return;

        var submenu = new ToolStripMenuItem(peers.SummaryLine);
        foreach (var (value, label, inForce) in peers.Choices)
        {
            submenu.DropDownItems.Add(new ToolStripMenuItem(
                label, null, (_, _) => SafeInvoke(() => peers.Choose(value)))
            {
                Checked = inForce,
                Enabled = peers.CanChange,
            });
        }

        if (!peers.CanChange)
        {
            // A pinned AllowedRemoteIP overrides the scale entirely. Say so
            // rather than offering a choice that would change nothing.
            submenu.DropDownItems.Add(new ToolStripMenuItem(
                "Set by AllowedRemoteIP in appsettings.json") { Enabled = false });
        }

        menu.Items.Add(submenu);
    }

    /// <summary>
    /// A menu handler that throws would take down the tray thread and, with
    /// it, the only status channel a screen reader has.
    /// </summary>
    private void SafeInvoke(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "A tray menu action failed.");
        }
    }

    /// <summary>
    /// Exit asks first, and asks for the word "exit" rather than for a button
    /// press — see <see cref="ConfirmExitDialog"/> for why this one item earns
    /// that much friction. Cancelling leaves everything running, so there is
    /// nothing to undo on that path.
    /// </summary>
    private void ConfirmAndExit()
    {
        if (!ConfirmExitDialog.Confirmed(_host.ExitConsequence)) return;
        _host.Exit();
    }

    /// <summary>
    /// Everything you would otherwise have to dig out of a log file to answer
    /// "which build is this and what is it doing": the version and the commit
    /// it came from, which mode it is in, whether it is elevated (the failure
    /// that is otherwise completely silent), the port, and where the log is.
    ///
    /// A plain MessageBox on purpose — a screen reader reads its whole body on
    /// open, and Ctrl+C copies the text, which is exactly what is wanted when
    /// reporting something. It runs on the tray's own STA thread, so the menu
    /// is already gone by the time it appears.
    /// </summary>
    private void ShowAbout()
    {
        var elevation = _status.IsElevated
            ? "elevated (keystrokes reach elevated and screen-reader windows)"
            : "NOT elevated — keystrokes will not reach elevated or screen-reader windows";

        var text = string.Join(Environment.NewLine, new[]
        {
            "RemKeys agent",
            "Version " + AgentVersion.Display,
            "",
            _host.ModeLine,
            _host.Peers?.SummaryLine ?? PinnedOrOpenLine(),
            "Running as: " + elevation,
            "Listening port: " + _options.ListenPort,
            "Status: " + _status.Description,
            "",
            "Program: " + (Environment.ProcessPath ?? "unknown"),
            "Log file: " + FileLoggerProvider.CurrentPath(_options.LogDirectory),
        });

        MessageBox.Show(text, "About RemKeys agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    /// <summary>
    /// Who may connect, for a mode that has no policy scale — the in-session
    /// agent, which accepts anyone who can reach the port because it can only
    /// type what the signed-in user could type anyway. `AllowedRemoteIP` is the
    /// one thing that still narrows it there, so say so when it is set rather
    /// than claiming the door is open.
    /// </summary>
    private string PinnedOrOpenLine()
    {
        var pinned = _options.AllowedRemoteIP.Trim();
        return pinned.Length > 0
            ? "Accepts connections from: only " + pinned
            : "Accepts connections from: any address that can reach the port";
    }

    private void OnStatusChanged()
    {
        var marshal = _marshal;
        if (marshal is null || !marshal.IsHandleCreated) return;
        try
        {
            marshal.BeginInvoke(UpdateTexts);
        }
        catch (Exception)
        {
            // Shutting down; the final texts no longer matter.
        }
    }

    private void UpdateTexts()
    {
        var text = _status.Description;
        if (_statusItem is not null)
        {
            _statusItem.Text = text;
        }
        if (_icon is not null)
        {
            // NotifyIcon.Text is length-limited (63 chars is safe everywhere).
            var tooltip = "RemKeys agent: " + text;
            _icon.Text = tooltip.Length <= 63 ? tooltip : tooltip[..62] + "…";
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _status.Changed -= OnStatusChanged;
        var marshal = _marshal;
        if (marshal is not null && marshal.IsHandleCreated)
        {
            try
            {
                marshal.Invoke(() =>
                {
                    if (_icon is not null)
                    {
                        _icon.Visible = false; // otherwise the dead icon lingers until hovered
                        _icon.Dispose();
                    }
                    Application.ExitThread();
                });
            }
            catch (Exception)
            {
                // UI thread already gone; nothing left to clean up.
            }
        }
        _uiThread?.Join(TimeSpan.FromSeconds(2));
        if (_iconHandle != 0)
        {
            DestroyIcon(_iconHandle);
            _iconHandle = 0;
        }
        return Task.CompletedTask;
    }

    /// <summary>
    /// Distinct 16×16 icon drawn in code (blue circle, white "R") so the exe
    /// ships no asset and never falls back to the generic-app icon.
    /// </summary>
    private static Icon CreateIcon(out nint handle)
    {
        using var bitmap = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var fill = new SolidBrush(Color.FromArgb(0, 120, 215));
            g.FillEllipse(fill, 0, 0, 15, 15);
            using var font = new Font("Segoe UI", 8, FontStyle.Bold, GraphicsUnit.Point);
            var size = g.MeasureString("R", font);
            g.DrawString("R", font, Brushes.White, (16 - size.Width) / 2, (16 - size.Height) / 2);
        }
        handle = bitmap.GetHicon();
        return Icon.FromHandle(handle);
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint hIcon);
}
