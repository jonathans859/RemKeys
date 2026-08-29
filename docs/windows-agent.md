# Windows agent

C#/.NET 8 worker host in `windows-agent/`. The wire format it parses and the
connection rules it shares with the apps are in [`../CLAUDE.md`](../CLAUDE.md).

## Modes

One exe, five modes (`AgentMode.cs`):

| Args | Mode |
|---|---|
| *(none)* | the in-session agent (default install) |
| `--service` | the lock-screen supervisor |
| `--helper --desktop <name>` | a per-desktop injector |
| `--install-service` / `--uninstall-service` | one-shot mode switchers |
| `--set-access <Tailscale\|LocalNetwork\|Any>` | one-shot peer-policy writer |

**Default install: a logon scheduled task in the user's session, and the injecting
process is NEVER a session 0 service** (`install-agent.bat` /
`uninstall-agent.bat`, run **as Administrator**). A service lives in session 0,
where `SendInput` cannot reach the interactive desktop — every injection is
rejected (field-verified: keystrokes arrived, and each logged `SendInput
rejected`). The task runs with highest privileges so injection also reaches
elevated windows, and `install-agent.bat` clears the schtasks defaults that killed
the agent (72-hour execution limit, stop-on-battery).

Built as `WinExe` (windowless): the task must not spawn a console window a user
could close to accidentally kill the agent. Output goes to the file logger; stop
via `uninstall-agent.bat` or Task Scheduler. The content root is pinned to
`AppContext.BaseDirectory` because the task starts in `System32`, where the default
(CWD) content root would silently miss the `appsettings.json` next to the exe.

**Renaming is not free on an installed PC.** A pre-rename install has its own task
name, exe name and mutex, so a new agent does *not* supersede it — both come up and
fight over port 5391. `install-agent.bat`, `uninstall-agent.bat` and
`ServiceSetup.RemoveLegacyInstall()` therefore delete the `KeyBridgeAgent` task,
the `KeyBridgeAgent.exe` process and the `KeyBridgeSecureAgent` service first.
`RemKeysOptions.LegacySectionName` keeps reading the old `"KeyBridge"` appsettings
section underneath the new one, so a hand-edited port or log directory isn't
silently reset.

## Must run elevated

`SendInput` into windows of **uiAccess** processes (installed NVDA runs
`uiAccess="True"` — its own dialogs) or elevated apps is discarded by UIPI with **no
error and no failing return value**. Field-verified: a hand-launched Medium-IL agent
typed fine everywhere except NVDA's dialogs, with zero log entries. The agent logs a
loud startup warning and flags the tray status when un-elevated. Launch via the
scheduled task, never by double-clicking.

## Injection (`KeystrokeInjector.cs`)

- **All keys are injected scancode-primary (`KEYEVENTF_SCANCODE`), not as VKs.**
  Games reading Raw Input/DirectInput identify keys by scancode and silently drop
  make-code-0 (VK-only) events, so a VK path would work in normal apps but lose
  arrows/F-keys/modifiers in games.
- Layout-sensitive keys (letters, digits, punctuation) use a fixed **US-positional
  scancode table**: the senders encode physical positions as US-meaning VKs, and
  scancode injection lets the PC's active layout (e.g. German QWERTZ) pick the
  character.
- Layout-independent keys resolve via `MapVirtualKeyW` at send time, with quirks:
  the nav cluster maps without its E0 prefix (the `ExtendedKeys` set disambiguates
  arrows from numpad), PrintScreen maps to the Alt+SysRq code (overridden to
  `E0 37`), and Pause is E1-multi-byte — the one key left on the VK path. The
  extended-key flag is set for the nav cluster, right-hand modifiers, numpad divide,
  Win/Apps and media keys.
- **Ctrl+Alt+Del cannot be injected** — SAS is handled below the input stack. On a
  box with *Require Ctrl+Alt+Del* set that would need `SendSAS()` and the
  `SoftwareSASGeneration` policy; on a default Windows 11 install any keypress goes
  straight to the password field. Not implemented.
- Anti-cheat that filters injected input entirely (Vanguard etc.) is out of scope —
  that needs a driver.

## Key repeat (`KeyRepeater.cs`)

**Windows does not auto-repeat injected keys.** Typematic repeat is produced *below*
`SendInput`, in the driver stack that sees a make code with no break; an injected
key-down enters above it. The key really is down (`GetAsyncKeyState` and games
reading raw input agree, which is why held keys *look* like they work), but nothing
repeats it — holding Down Arrow moved the caret one line and stopped. The Apple ends
can't fix it: iOS delivers `pressesBegan` once per press and `GCKeyboard` only
reports transitions.

So a held key is re-pressed here, at the PC's own **Repeat delay / Repeat rate**
(`SPI_GETKEYBOARDDELAY` / `SPI_GETKEYBOARDSPEED`, read live per press; LocalSystem in
lock-screen mode reads Windows' defaults rather than the user's sliders, which is
what the config overrides are for). This is also what makes the iOS pad's hold stage
do what it promises. Rules:

- **Typematic semantics** — only the most recently pressed repeatable key repeats,
  and releasing it doesn't resume an earlier one.
- **Modifiers, the locks, media keys and PrintScreen never repeat.** A repeating Caps
  Lock would toggle at 30 Hz, and a repeating Shift upsets Sticky Keys and screen
  readers.
- **macOS is detected, not flagged.** Its event tap forwards macOS's own repeat
  key-downs, i.e. a second `pressed=1` for a key it already holds, and that duplicate
  makes the repeater stand down for the session. The 250 ms grace on a session's
  first repeat exists so macOS's own first repeat (~375 ms) lands inside it and is
  recognised before a keystroke is doubled.
- Repeats go through the sink like any other event, so lock-screen mode carries them
  to the helpers unchanged.

## Sessions (`Worker.cs`)

- **The accept loop never blocks on a session.** It accepts continuously; a new
  allowed peer closes the previous socket, waits for that session to finish (which
  releases its held keys and resets the status), then starts. Sessions still run
  strictly one at a time, which is what keeps `_held` and the status writes
  lock-free. The repeat timer is the one thing calling the sink off the session
  thread; it keeps its own state under its own lock and never touches `_held`.
- Two details easy to undo by accident: the peer policy is checked **before** the old
  session is dropped, or anyone who can reach the port could cut off the real
  keyboard just by connecting once; and superseding **closes the socket** rather than
  cancelling the read, because a pending socket read is not reliably interruptible by
  a `CancellationToken` while closing the handle always throws it out.
- **A dropped connection releases whatever the peer left down**, in every mode. The
  Apple side holds keys on purpose (the iOS pad's hold gesture; a physical key still
  down when forwarding stops), so if the socket dies in that window the release line
  never arrives and Windows repeats that key forever. Only this end can clean up; the
  sender is gone. Keepalive is what makes this fire at all for a peer that vanished
  silently.
- **Never crashes on bad config**: invalid port or busy socket → logs and retries;
  malformed line → logged and skipped, not fatal. Per-day log file (`FileLogger.cs`).

## Single instance, tray, exit

- **Single instance** via a named mutex; a second launch logs one line and exits. The
  windowless exe invited accidental multi-launch, which piled up port-retry loops.
- **Tray icon** (WinForms `NotifyIcon`; the csproj targets `net8.0-windows` with
  `UseWindowsForms`, and `EnableWindowsTargeting` keeps the ubuntu CI job compiling).
  The tooltip and a disabled menu line carry live status ("Waiting for a connection
  on port 5391" / "Connected to <ip>" / "Port busy", with a "not elevated!" marker).
  **The tooltip is what NVDA announces in the tray, so it is the accessible status
  channel.**
- **Exit asks you to type the word "exit"** (`ConfirmExitDialog.cs`), not to press a
  default button. Exit sits at the bottom of a menu a screen-reader user arrows
  through, and what it costs is invisible: the agent is windowless, so a mis-triggered
  Exit looks like nothing happening until a keystroke silently fails to arrive — and
  it stays gone until the next sign-in, or the next *reboot* with lock-screen support
  on. No stray Enter produces "exit" in an empty box. It is the one dialog that isn't
  a plain `MessageBox`, so it earns its accessibility explicitly: a real `FixedDialog`
  (which is what makes NVDA read the whole body on open), the prompt as a `Label`
  immediately before the text box, taskbar + topmost (a windowless app's dialog must
  not be able to hide), and — deliberately — a **Stop button that is never disabled**,
  because a disabled WinForms button is skipped in the tab order entirely and
  disable-until-valid would leave a blind user pressing Enter at a dialog that answers
  nothing. A wrong word gets a spoken `MessageBox`. `ITrayHost.ExitConsequence`
  supplies the body, since stopping the service takes the lock screen's keyboard with
  it and stopping the in-session agent does not.
- **About RemKeys agent…** is a plain `MessageBox` on purpose — a screen reader reads
  the whole body on open and Ctrl+C copies it. It shows version, commit, build date,
  lock-screen mode, elevation, port, live status, exe path and log path.

## Version stamping (`AgentVersion.cs`)

`1.0.<commit count>`, stamped by `deploy-windows.yml` via `-p:Version=` — the same
rule the iOS/macOS build numbers follow, so versions are monotonic on main and
comparable as a plain integer. The commit hash is *not* passed on the command line:
the .NET SDK appends `+<sha>` to `InformationalVersion` from the checkout's git data
by itself. The build date is an `AssemblyMetadata` item rather than the file's mtime,
because deterministic builds zero the PE timestamp and an mtime survives neither a
copy nor some unzip tools. A local `dotnet build` gets `1.0.0-dev`, so a hand-built
exe can never be mistaken for a release. It is logged as the first line every process
writes.

## Configuration (`appsettings.json`)

| Key | Meaning |
|---|---|
| `ListenPort` | default 5391 |
| `AllowedRemoteIP` | empty = accept any peer the policy allows; a pinned address overrides the policy entirely |
| `LogDirectory` | empty = next to the exe |
| `KeyRepeat` / `KeyRepeatDelayMs` / `KeyRepeatIntervalMs` | on, and 0 = follow this PC's own settings |
| `LockScreenAccess` | lock-screen mode only: `Tailscale` / `LocalNetwork` / `Any`, written by the tray |
| `AllowLoopbackPeers` | testing hatch under `Tailscale` |
| `AllowNonTailscalePeers` | superseded, still read (see below) |

---

# Optional lock-screen support

Written but **never run** — CI is its first compile.

**The problem is a *desktop* problem, not a privilege one.** The lock screen, the
sign-in screen and the UAC consent prompt render on the `Winlogon` desktop, and
`SendInput` only ever reaches the input queue of the desktop the calling thread is
attached to. No integrity level and no uiAccess flag crosses that boundary —
**uiAccess would buy nothing here** (and is unreachable unsigned anyway). The only
fix is a process *on that desktop*.

## Shape

A LocalSystem service (`RemKeysSecureAgent`) owns the socket, the wire parser and the
peer policy in session 0, and never injects. `DesktopSupervisor` duplicates the
service's own token, re-homes it to the console session
(`WTSGetActiveConsoleSessionId` + `SetTokenInformation(TokenSessionId)`) and
`CreateProcessAsUser`s one helper per desktop with `STARTUPINFO.lpDesktop` =
`WinSta0\Default` / `WinSta0\Winlogon` (`Native.cs`). Parsed events go out over a
named pipe (`InjectionChannel.cs`) in the *same* newline wire format, so helpers
reuse `WireProtocol`/`LineReader` and never see anything the parser didn't approve.

- **Helpers self-route**: the hub broadcasts to both, and each injects only while
  `OpenInputDesktop` says its own desktop is in front (50 ms cache, 250 ms poll).
  That decision must live in the helper — session 0 is on a different window station
  and cannot see these desktops at all. A helper going inactive **releases every key
  it still holds**, or locking mid-chord leaves a modifier stuck on the desktop being
  left.
- Helpers run as **LocalSystem, i.e. above High IL**, so elevated windows and NVDA's
  uiAccess dialogs work with no certificate and no elevation dance. They also start
  **before sign-in**, so the password can be typed at a cold boot.
- **A helper's life is one pipe session.** It exits when the pipe drops rather than
  reconnecting, and the supervisor spawns a fresh one — a lingering helper plus a new
  one would be two injectors on one desktop typing everything twice. For the same
  reason the hub is registered *after* the supervisor: hosted services stop in
  reverse, so pipes close (helpers leave cleanly, releasing held keys) before the
  supervisor reaches for `Kill()`.

## The tray must NOT live in a helper

Helpers are LocalSystem, i.e. System integrity, and a screen reader at medium IL with
uiAccess **cannot read the UI of a System-integrity process** — uiAccess reaches into
*elevated* apps, not into SYSTEM ones. One build put the tray in the Default helper
and the menu came up **empty in NVDA**, taking the accessible status channel with it.

So the **logon task stays registered in both modes**: with the service on, that
user-session process runs no listener and injects nothing — it is just the tray, fed
by a second pipe (`RemKeysAgent.status`, `StatusChannel.cs`) carrying the status line
out and exactly one command (`stop`) back. That pipe is separate from the injection
pipe *on purpose*: the injection pipe stays LocalSystem-only because it types on the
secure desktop, while the status pipe is ACL'd for `Interactive` so the signed-in
user can read it.

## Switching modes

**Exactly one of the two may own the port** — the service and an in-session *listener*
would fight for 5391. Switching is a tray menu item ("Turn on/off lock screen
support…", `TrayHosts.cs`) that relaunches the exe with the install/uninstall verb;
`install-lockscreen.bat` / `uninstall-lockscreen.bat` are the no-tray recovery path.
Install stops the logon task just long enough to hand the port over, then re-creates
and re-runs it (asking WTS who is signed in, since LocalSystem has no "current
user"); the restarted process sees the service running and comes up as a tray client.

## Who may type at the lock screen (`PeerAccess.cs`)

With this mode on, anyone who can reach the port can type at the lock screen, and the
listener is LocalSystem. So in service mode *only*, the peer policy tightens. The
in-session agent keeps its laxer policy — it can only do what the signed-in user
already could — so this question exists in exactly one mode.

It is **one ordered scale, not a bag of booleans**; `TrayText.PeerMenuTitle` is the
single source of the user-facing name.

| Value | Accepts |
|---|---|
| `Tailscale` (default) | 100.64.0.0/10 and fd7a:115c:a1e0::/48; loopback refused |
| `LocalNetwork` | the above plus RFC 1918, 169.254/16, fc00::/7, fe80::/10 and loopback |
| `Any` | anything |

The scale exists because **not everyone uses Tailscale** — nothing in the apps
requires it, and the old policy silently refused LAN users with the only clue in a log
file. Two things follow from the shape:

- Loopback is *not* a separate axis in the wider two settings: once any LAN address is
  accepted, a local process can just connect to the PC's own LAN address, so refusing
  127.0.0.1 would be theatre. `AllowLoopbackPeers` survives only as the testing hatch
  under `Tailscale`.
- The LAN ranges are a **fixed list, not "whatever subnet this PC's adapters are on"**,
  because a rule the user can predict beats one that changes when a VPN or a dock
  appears.

`AllowNonTailscalePeers` still reads as `Any` when `LockScreenAccess` is absent
(`ResolveLockScreenAccess`), and the tray deletes that key when it writes the new one
so the file states one policy. An unparseable value logs and falls back to
`Tailscale` rather than refusing to start.

**Changing it goes through UAC, not the status pipe** (`--set-access`,
`ServiceSetup.SetPeerAccess`). The pipe was right there and already carries `stop`,
but it is ACL'd for `Interactive`: stopping a service on your own console is no worse
than pulling the plug, while widening who may type on the secure desktop is an
administrator's decision. So the tray relaunches the exe elevated exactly like the
install toggle does; the elevated process writes `appsettings.json` (via a temp file;
a config that won't parse is left alone rather than clobbered), restarts the service —
options bind once at startup, and a live-reload path through the one check guarding
the lock screen isn't worth the saving — and restarts the logon task so the tray
re-reads the file. That restart is why the tray needs no protocol change to stay
truthful.

**A refused peer is announced, not just logged.** This setting is the one that makes a
working install look broken from the phone's end (it connects, and nothing is typed),
so a rejection also becomes the tray status — `Refused <ip> — not allowed by "Who may
type at the lock screen: …"` — which is what NVDA reads. Guarded on
`currentSession.IsCompleted` so a stray port scan can't wipe a live "Connected to …".
A pinned `AllowedRemoteIP` overrides the whole scale, so the tray greys the choices
out and says so rather than offering one that would change nothing.
