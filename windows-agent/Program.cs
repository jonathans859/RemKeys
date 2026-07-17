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

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
