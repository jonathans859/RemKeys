using System.Security.Principal;
using KeyBridgeAgent;

// Anchor the content root to the exe's folder: the logon scheduled task
// starts processes in C:\Windows\System32, and the default content root
// (current directory) would make the host miss the appsettings.json that
// ships next to the executable.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});

// Deliberately NOT a Windows service: services run in session 0, where
// SendInput cannot reach the interactive desktop — every injection is
// rejected. The agent must run inside the logged-in user's session; the
// install script registers it as a logon scheduled task instead.

// Bind config. Missing/malformed sections just leave defaults in place — the
// options object always has safe values, so the service never fails to start.
builder.Services.Configure<KeyBridgeOptions>(
    builder.Configuration.GetSection(KeyBridgeOptions.SectionName));

// File logging alongside the executable (or the configured directory).
var logDirectory = builder.Configuration
    .GetSection(KeyBridgeOptions.SectionName)[nameof(KeyBridgeOptions.LogDirectory)] ?? string.Empty;
builder.Logging.AddProvider(new FileLoggerProvider(logDirectory));

builder.Services.AddSingleton<AgentStatus>();
builder.Services.AddHostedService<Worker>();
builder.Services.AddHostedService<TrayIconService>();

using var host = builder.Build();
var logger = host.Services.GetRequiredService<ILogger<Program>>();

// Single instance, per session. The exe is windowless, so double-clicking it
// gives no feedback and it is easy to start several copies — which used to
// pile up as extra processes retrying the busy port forever. A second launch
// now logs one line and exits.
using var singleInstance = new Mutex(initiallyOwned: true, @"Local\KeyBridgeAgent", out var isFirstInstance);
if (!isFirstInstance)
{
    logger.LogWarning("Another KeyBridge agent is already running in this session; exiting. " +
        "Use the tray icon or uninstall-agent.bat to stop the running one.");
    return;
}

// Elevation check. An un-elevated agent LOOKS fine: SendInput into windows of
// elevated or uiAccess processes (screen readers — NVDA's own dialogs, for
// example) is silently discarded by UIPI, with no error and no failing return
// value to log (field-verified 2026-07-18). Warn loudly here and mark it in
// the tray status, because nothing downstream can detect it per-keystroke.
var isElevated = new WindowsPrincipal(WindowsIdentity.GetCurrent())
    .IsInRole(WindowsBuiltInRole.Administrator);
host.Services.GetRequiredService<AgentStatus>().IsElevated = isElevated;
if (!isElevated)
{
    logger.LogWarning("Running WITHOUT elevation: keystrokes will silently not reach elevated windows " +
        "or screen-reader dialogs (uiAccess). Start the agent via the KeyBridgeAgent scheduled task " +
        "(install-agent.bat) instead of launching the exe directly.");
}

host.Run();
