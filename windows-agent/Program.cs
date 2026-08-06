using System.Security.Principal;
using KeyBridgeAgent;
using Microsoft.Extensions.Hosting.WindowsServices;

// One executable, four personalities — see AgentMode. No arguments is the
// classic in-session agent, so an existing install keeps behaving exactly as
// it did.
var mode = AgentMode.Parse(args);

// The install/uninstall verbs are one-shot: they do their work, tell the user
// in a dialog, and exit. No host, no listener.
switch (mode.Role)
{
    case AgentRole.InstallService:
        return ServiceSetup.Install(mode);
    case AgentRole.UninstallService:
        return ServiceSetup.Uninstall();
}

// Anchor the content root to the exe's folder: the logon scheduled task and
// the SCM both start processes in C:\Windows\System32, and the default content
// root (current directory) would make the host miss the appsettings.json that
// ships next to the executable.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});

// Bind config. Missing/malformed sections just leave defaults in place — the
// options object always has safe values, so the agent never fails to start.
builder.Services.Configure<KeyBridgeOptions>(
    builder.Configuration.GetSection(KeyBridgeOptions.SectionName));

// File logging alongside the executable (or the configured directory). All
// three processes share one file, tagged so they stay tellable apart.
var logDirectory = builder.Configuration
    .GetSection(KeyBridgeOptions.SectionName)[nameof(KeyBridgeOptions.LogDirectory)] ?? string.Empty;
builder.Logging.AddProvider(new FileLoggerProvider(logDirectory, mode.LogTag));

builder.Services.AddSingleton(mode);
builder.Services.AddSingleton<AgentStatus>();

switch (mode.Role)
{
    case AgentRole.Service:
        // LocalSystem, session 0. Owns the socket and the parser; injects
        // nothing itself — session 0 has its own window station, and its
        // SendInput could never reach the interactive desktop. The supervisor
        // puts a helper on each desktop that can.
        // No-ops when the process was not started by the SCM, so running
        // "KeyBridgeAgent.exe --service" by hand still works for debugging.
        builder.Services.AddWindowsService();
        builder.Services.AddSingleton<InjectionHub>();
        builder.Services.AddSingleton<IKeystrokeSink>(sp => sp.GetRequiredService<InjectionHub>());

        // Registration order matters on the way down: hosted services stop in
        // reverse, and the hub must close its pipes before the supervisor
        // reaches for its helpers — that disconnect is what makes a helper
        // release any key still held and exit on its own, instead of being
        // killed mid-chord with a modifier stuck down.
        builder.Services.AddHostedService<DesktopSupervisor>();
        builder.Services.AddHostedService(sp => sp.GetRequiredService<InjectionHub>());
        builder.Services.AddHostedService<StatusHub>();
        builder.Services.AddHostedService<Worker>();
        break;

    case AgentRole.Helper:
        // No tray here, in either helper. A helper is LocalSystem, and a
        // screen reader cannot read the UI of a System-integrity process — the
        // tray lives in the logon-task process below instead.
        builder.Services.AddSingleton<HelperWorker>();
        builder.Services.AddHostedService(sp => sp.GetRequiredService<HelperWorker>());
        break;

    default:
        if (ServiceSetup.IsRunning())
        {
            // Lock-screen support is on: the service owns the port and the
            // helpers do the typing, so this process is the tray and nothing
            // else. It stays the logon task either way, which is what keeps
            // the tray in the user's session where NVDA can read it.
            builder.Services.AddSingleton<TrayClientWorker>();
            builder.Services.AddHostedService(sp => sp.GetRequiredService<TrayClientWorker>());
            builder.Services.AddSingleton<ITrayHost, ServiceClientTrayHost>();
        }
        else
        {
            builder.Services.AddSingleton<IKeystrokeSink, LocalKeystrokeSink>();
            builder.Services.AddHostedService<Worker>();
            builder.Services.AddSingleton<ITrayHost, StandaloneTrayHost>();
        }
        builder.Services.AddHostedService<TrayIconService>();
        break;
}

using var host = builder.Build();
var logger = host.Services.GetRequiredService<ILogger<Program>>();

// Single instance. The exe is windowless, so double-clicking it gives no
// feedback and it is easy to start several copies — which used to pile up as
// extra processes retrying the busy port forever. A second launch logs one
// line and exits. The service is exempt: the SCM already guarantees one.
Mutex? singleInstance = null;
if (mode.Role != AgentRole.Service)
{
    // Helpers are keyed by desktop so the Default and Winlogon ones coexist.
    var mutexName = mode.Role == AgentRole.Helper
        ? $@"Local\KeyBridgeAgent.helper.{mode.Desktop}"
        : @"Local\KeyBridgeAgent";

    singleInstance = new Mutex(initiallyOwned: true, mutexName, out var isFirstInstance);
    if (!isFirstInstance)
    {
        logger.LogWarning("Another KeyBridge agent ({Mode}) is already running in this session; exiting. " +
            "Use the tray icon or uninstall-agent.bat to stop the running one.", mode.LogTag);
        singleInstance.Dispose();
        return 0;
    }
}

using (singleInstance)
{
    if (mode.Role == AgentRole.Standalone && !ServiceSetup.IsRunning())
    {
        // Elevation check. An un-elevated agent LOOKS fine: SendInput into
        // windows of elevated or uiAccess processes (screen readers — NVDA's
        // own dialogs, for example) is silently discarded by UIPI, with no
        // error and no failing return value to log (field-verified
        // 2026-07-18). Warn loudly here and mark it in the tray status, because
        // nothing downstream can detect it per-keystroke. Helpers and the
        // service run as LocalSystem, where this cannot arise.
        var isElevated = new WindowsPrincipal(WindowsIdentity.GetCurrent())
            .IsInRole(WindowsBuiltInRole.Administrator);
        host.Services.GetRequiredService<AgentStatus>().IsElevated = isElevated;
        if (!isElevated)
        {
            logger.LogWarning("Running WITHOUT elevation: keystrokes will silently not reach elevated windows " +
                "or screen-reader dialogs (uiAccess). Start the agent via the KeyBridgeAgent scheduled task " +
                "(install-agent.bat) instead of launching the exe directly.");
        }
    }

    host.Run();
}

return 0;
