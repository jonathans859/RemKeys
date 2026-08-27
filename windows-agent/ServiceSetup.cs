using System.Diagnostics;
using System.ServiceProcess;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace RemKeysAgent;

/// <summary>
/// Installs and removes the optional lock-screen service, swaps it with the
/// classic logon scheduled task so exactly one of the two ever owns the port,
/// and writes the one setting that only exists while it is on — who may type at
/// the lock screen.
///
/// All three run as their own short-lived process (<c>--install-service</c> /
/// <c>--uninstall-service</c> / <c>--set-access</c>) launched from the tray
/// menu, because each needs elevation and the swap needs the agent that is
/// being replaced to be gone first.
/// </summary>
public static class ServiceSetup
{
    public const string ServiceName = "RemKeysSecureAgent";
    public const string ServiceDisplayName = "RemKeys lock screen support";
    public const string TaskName = "RemKeysAgent";

    // What the same three things were called before the agent was renamed from
    // KeyBridge to RemKeys. A leftover old install is not harmless: it has its
    // own task, exe and mutex, so the new agent does not supersede it — both
    // start and fight over port 5391. Every path that installs something clears
    // these first.
    private const string LegacyServiceName = "KeyBridgeSecureAgent";
    private const string LegacyTaskName = "KeyBridgeAgent";
    private const string LegacyProcessName = "KeyBridgeAgent";

    private const string ServiceDescription =
        "Receives RemKeys keystrokes and replays them on whichever desktop is in front, " +
        "including the lock screen, the sign-in screen and the UAC prompt.";

    /// <summary>Is the lock-screen service registered on this machine?</summary>
    public static bool IsInstalled()
    {
        try
        {
            using var controller = new ServiceController(ServiceName);
            _ = controller.Status; // throws if it does not exist
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static bool IsRunning()
    {
        try
        {
            using var controller = new ServiceController(ServiceName);
            return controller.Status is ServiceControllerStatus.Running
                or ServiceControllerStatus.StartPending;
        }
        catch (Exception)
        {
            return false;
        }
    }

    // ---- Install ---------------------------------------------------------

    public static int Install(AgentMode mode)
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            Ui.Error("RemKeys", "Could not determine the agent's own path; nothing was changed.");
            return 1;
        }

        // The agent we are replacing still owns port 5391. Let it go first, or
        // the service starts into a busy socket and spends its first ten
        // seconds retrying.
        WaitForProcessExit(mode.WaitForPid, TimeSpan.FromSeconds(15));

        RemoveLegacyInstall();

        // The logon task stays registered — it is what puts the tray in the
        // user's session, and only a process there can show a menu a screen
        // reader can read. It is stopped just long enough to hand the port
        // over; when it comes back it will see the service running and start
        // as a tray client instead of a listener.
        Run("schtasks", "/End", "/TN", TaskName);

        // /End returns before the process is actually gone. Two seconds is
        // enough in practice, and the service's listener retries anyway if the
        // socket is still held.
        Thread.Sleep(2000);

        if (IsInstalled())
        {
            StopAndDeleteService();
        }

        var create = Run("sc",
            "create", ServiceName,
            "binPath=", $"\"{exe}\" --service",
            "start=", "auto",
            "obj=", "LocalSystem",
            "DisplayName=", ServiceDisplayName);

        if (create.ExitCode != 0)
        {
            Ui.Error("RemKeys",
                "Could not register the lock screen service.\r\n\r\n" +
                create.Output + "\r\n\r\n" +
                "The agent was not changed — run install-agent.bat to put the normal agent back.");
            return create.ExitCode;
        }

        Run("sc", "description", ServiceName, ServiceDescription);
        // Survive a crash without needing a reboot: this is the only thing
        // standing between a locked PC and no keyboard at all.
        Run("sc", "failure", ServiceName, "reset=", "0", "actions=", "restart/5000/restart/10000/restart/30000");

        var started = StartService(out var error);
        if (!started)
        {
            Ui.Error("RemKeys",
                "The lock screen service was registered but would not start.\r\n\r\n" + error);
            return 1;
        }

        // Bring the tray back in the user's session. Without it the service
        // runs headless: no accessible way to read its state, and no way to
        // turn it off again short of a batch file.
        var task = EnsureLogonTask(exe);
        if (task.ExitCode != 0)
        {
            Ui.Error("RemKeys",
                "Lock screen support is on, but the tray icon could not be restored.\r\n\r\n" +
                task.Output + "\r\n\r\n" +
                "Keystrokes still work. Run install-agent.bat as Administrator to get the tray back.");
            return 0;
        }
        Run("schtasks", "/Run", "/TN", TaskName);

        Ui.Info("RemKeys",
            "Lock screen support is on.\r\n\r\n" +
            "RemKeys now runs as a Windows service and starts before you sign in, so you can type " +
            "on the lock screen, at the sign-in screen and in UAC prompts.\r\n\r\n" +
            "Only Tailscale addresses are accepted while this is on. If you connect over a plain " +
            $"home or office network instead, change \"{TrayText.PeerMenuTitle}\" in the tray menu, " +
            "or nothing you type will arrive.\r\n\r\n" +
            "The tray icon comes back in a few seconds. To turn this off again, use " +
            "\"Turn off lock screen support\" in the tray menu.");
        return 0;
    }

    // ---- Uninstall -------------------------------------------------------

    public static int Uninstall()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            Ui.Error("RemKeys", "Could not determine the agent's own path; nothing was changed.");
            return 1;
        }

        RemoveLegacyInstall();

        if (IsInstalled())
        {
            StopAndDeleteService();
        }

        var task = EnsureLogonTask(exe);
        if (task.ExitCode != 0)
        {
            Ui.Error("RemKeys",
                "Lock screen support was removed, but the normal logon task could not be restored.\r\n\r\n" +
                task.Output + "\r\n\r\n" +
                "Run install-agent.bat as Administrator to finish putting the agent back.");
            return task.ExitCode;
        }

        // Restart it so the tray process notices the service is gone and comes
        // back up as a full agent rather than a tray client.
        Run("schtasks", "/End", "/TN", TaskName);
        Run("schtasks", "/Run", "/TN", TaskName);

        Ui.Info("RemKeys",
            "Lock screen support is off.\r\n\r\n" +
            "RemKeys is back to the normal agent that runs while you are signed in. Keystrokes no " +
            "longer reach the lock screen, the sign-in screen or UAC prompts.");
        return 0;
    }

    // ---- Peer policy -----------------------------------------------------

    /// <summary>
    /// Write the lock-screen peer policy into appsettings.json and make it
    /// take effect. Runs as its own elevated process (<c>--set-access</c>)
    /// launched from the tray.
    ///
    /// Elevation is not just about writing a file in Program Files. Widening
    /// who may type on the secure desktop is an administrator's decision: the
    /// tray runs as the signed-in user and its status pipe is open to any
    /// interactive account, so this deliberately does not travel down that
    /// pipe as a command.
    ///
    /// The service is restarted rather than told to re-read: its options are
    /// bound once at startup, and a live-reload path through the one check
    /// that guards the lock screen is not worth the saving. The logon task is
    /// restarted too, so the tray's menu shows the new value instead of the
    /// one it read when it started.
    /// </summary>
    public static int SetPeerAccess(PeerAccess access)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");

        if (!TryWritePeerAccess(path, access, out var error))
        {
            Ui.Error("RemKeys",
                "Could not save the setting.\r\n\r\n" + error + "\r\n\r\n" +
                $"File: {path}\r\n\r\nNothing was changed.");
            return 1;
        }

        // The service is only there to restart when lock-screen support is on,
        // which is the only mode the setting means anything in — but writing it
        // ahead of time is harmless and keeps this verb usable from a script.
        var serviceInstalled = IsInstalled();
        var serviceError = string.Empty;
        var restarted = !serviceInstalled || RestartService(out serviceError);
        if (!restarted)
        {
            Ui.Error("RemKeys",
                "The setting was saved, but the lock screen service would not restart, so it is " +
                "still using the old one.\r\n\r\n" + serviceError + "\r\n\r\n" +
                "Restart the PC, or turn lock screen support off and on again from the tray menu.");
        }

        // Bring the tray back with fresh config; it reads the same file.
        Run("schtasks", "/End", "/TN", TaskName);
        Run("schtasks", "/Run", "/TN", TaskName);

        if (!restarted) return 1;

        Ui.Info("RemKeys",
            $"{TrayText.PeerMenuTitle}: {PeerAccessPolicy.Label(access)}.\r\n\r\n" +
            (serviceInstalled
                ? "The lock screen service was restarted, so any connected device has to reconnect — " +
                  "the apps do that by themselves."
                : "It takes effect the next time lock screen support is turned on."));
        return 0;
    }

    /// <summary>
    /// Set the key in the "RemKeys" section, creating it if the file has none,
    /// and drop the superseded <c>AllowNonTailscalePeers</c> from both the
    /// current and the legacy section so the file states exactly one policy.
    /// A file that will not parse is left untouched: overwriting someone's
    /// hand-edited config to fix one key would be the worse failure.
    /// </summary>
    private static bool TryWritePeerAccess(string path, PeerAccess access, out string error)
    {
        error = string.Empty;
        try
        {
            JsonObject root;
            if (File.Exists(path))
            {
                var parsed = JsonNode.Parse(
                    File.ReadAllText(path),
                    documentOptions: new JsonDocumentOptions
                    {
                        CommentHandling = JsonCommentHandling.Skip,
                        AllowTrailingCommas = true,
                    });
                if (parsed is not JsonObject obj)
                {
                    error = "appsettings.json is not a JSON object; fix it by hand and try again.";
                    return false;
                }
                root = obj;
            }
            else
            {
                root = new JsonObject();
            }

            if (root[RemKeysOptions.SectionName] is not JsonObject section)
            {
                section = new JsonObject();
                root[RemKeysOptions.SectionName] = section;
            }

            section[nameof(RemKeysOptions.LockScreenAccess)] = PeerAccessPolicy.Canonical(access);
            section.Remove(nameof(RemKeysOptions.AllowNonTailscalePeers));
            (root[RemKeysOptions.LegacySectionName] as JsonObject)
                ?.Remove(nameof(RemKeysOptions.AllowNonTailscalePeers));

            // Write via a temporary file so a failure halfway cannot leave the
            // agent with a truncated config it would have to fall back from.
            var temporary = path + ".new";
            File.WriteAllText(temporary, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static bool RestartService(out string error)
    {
        error = string.Empty;
        try
        {
            using var controller = new ServiceController(ServiceName);
            if (controller.Status != ServiceControllerStatus.Stopped)
            {
                controller.Stop();
                controller.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }

        return StartService(out error);
    }

    /// <summary>
    /// (Re)register the logon task. It is wanted in both modes — as the agent
    /// itself when lock-screen support is off, and as the tray client when it
    /// is on — so both directions come through here.
    /// </summary>
    private static (int ExitCode, string Output) EnsureLogonTask(string exe)
    {
        // We may be running as LocalSystem, which has no "current user" of its
        // own — ask the session who is signed in.
        var user = Native.GetSessionUserName(Native.WTSGetActiveConsoleSessionId());

        var args = new List<string>
        {
            "/Create", "/TN", TaskName, "/TR", $"\"{exe}\"", "/SC", "ONLOGON", "/RL", "HIGHEST", "/F",
        };
        if (!string.IsNullOrEmpty(user))
        {
            args.Add("/RU");
            args.Add(user);
            args.Add("/IT");
        }

        var result = Run("schtasks", args.ToArray());
        if (result.ExitCode == 0)
        {
            // schtasks defaults would stop the agent after 72 hours and refuse
            // to run on battery — same fix-up install-agent.bat applies.
            Run("powershell", "-NoProfile", "-Command",
                $"Set-ScheduledTask -TaskName '{TaskName}' -Settings (New-ScheduledTaskSettingsSet " +
                "-ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)");
        }
        return result;
    }

    /// <summary>
    /// Clear out an install made under the old KeyBridge names. Every step is
    /// best-effort and silent when there is nothing there, which is the normal
    /// case — this only ever finds something on a PC that ran a pre-rename
    /// build. Settings survive: both names read the same appsettings.json.
    /// </summary>
    private static void RemoveLegacyInstall()
    {
        Run("schtasks", "/End", "/TN", LegacyTaskName);
        Run("schtasks", "/Delete", "/TN", LegacyTaskName, "/F");
        Run("taskkill", "/IM", LegacyProcessName + ".exe", "/F");
        Run("sc", "stop", LegacyServiceName);
        Run("sc", "delete", LegacyServiceName);
    }

    private static void StopAndDeleteService()
    {
        try
        {
            using var controller = new ServiceController(ServiceName);
            if (controller.Status != ServiceControllerStatus.Stopped)
            {
                controller.Stop();
                controller.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
            }
        }
        catch (Exception)
        {
            // Already stopped, already gone, or refusing to stop — sc delete
            // below still marks it for deletion.
        }

        Run("sc", "delete", ServiceName);

        // sc delete only takes effect once every handle is closed; give the
        // SCM a moment so a re-install right after does not hit "marked for
        // deletion".
        Thread.Sleep(1000);
    }

    private static bool StartService(out string error)
    {
        error = string.Empty;
        try
        {
            using var controller = new ServiceController(ServiceName);
            if (controller.Status != ServiceControllerStatus.Running)
            {
                controller.Start();
                controller.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static void WaitForProcessExit(int pid, TimeSpan timeout)
    {
        if (pid <= 0) return;
        try
        {
            using var process = Process.GetProcessById(pid);
            process.WaitForExit((int)timeout.TotalMilliseconds);
        }
        catch (ArgumentException)
        {
            // Already gone, which is the state we were waiting for.
        }
        catch (Exception)
        {
            // Not worth failing the install over; the listener retries anyway.
        }
    }

    private static (int ExitCode, string Output) Run(string fileName, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null) return (-1, $"Could not start {fileName}.");
            var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            process.WaitForExit(60_000);
            return (process.HasExited ? process.ExitCode : -1, output.Trim());
        }
        catch (Exception ex)
        {
            return (-1, ex.Message);
        }
    }
}

/// <summary>
/// Message boxes for the install/uninstall flows. A dialog is the accessible
/// channel here — a screen reader reads it aloud, where a log line or an exit
/// code would pass unnoticed.
/// </summary>
internal static class Ui
{
    public static void Info(string title, string text) => Show(title, text, MessageBoxIcon.Information);

    public static void Error(string title, string text) => Show(title, text, MessageBoxIcon.Error);

    private static void Show(string title, string text, MessageBoxIcon icon)
    {
        // Own STA thread: these processes have no message loop of their own,
        // and MessageBox on a pooled MTA thread is unreliable.
        var thread = new Thread(() => MessageBox.Show(text, title, MessageBoxButtons.OK, icon));
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
    }
}
