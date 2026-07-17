using KeyBridgeAgent;

var builder = Host.CreateApplicationBuilder(args);

// Run as a Windows service (also runs fine as a console app for debugging).
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "KeyBridge Agent";
});

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
