using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace KeyBridgeAgent;

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
    private readonly ILogger<TrayIconService> _logger;

    private Thread? _uiThread;
    private Control? _marshal;           // handle-owning control to hop onto the UI thread
    private NotifyIcon? _icon;
    private ToolStripMenuItem? _statusItem;
    private nint _iconHandle;

    public TrayIconService(AgentStatus status, ITrayHost host, ILogger<TrayIconService> logger)
    {
        _status = status;
        _host = host;
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
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit RemKeys agent", null, (_, _) => SafeInvoke(_host.Exit));

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
    /// Distinct 16×16 icon drawn in code (blue circle, white "K") so the exe
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
            var size = g.MeasureString("K", font);
            g.DrawString("K", font, Brushes.White, (16 - size.Width) / 2, (16 - size.Height) / 2);
        }
        handle = bitmap.GetHicon();
        return Icon.FromHandle(handle);
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint hIcon);
}
