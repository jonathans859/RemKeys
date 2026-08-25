# RemKeys

Type on your Mac or iPhone/iPad keyboard and have the keystrokes replayed on a
Windows PC over Tailscale. Built for daily use with a screen reader; the Windows
side is standalone, with no NVDA dependency.

- **iOS / macOS apps** — capture the physical keyboard and forward it.
- **Windows agent** — replays the keystrokes via `SendInput`, as if they came
  from a keyboard plugged into the PC.

Keyboard only: no mouse, clipboard, files, or screen sharing.

> The App Store name is **RemKeys**; the repository, the Xcode targets and the
> bundle id are still `KeyBridge`. That mismatch is deliberate — see
> [`CLAUDE.md`](CLAUDE.md).

## Quick start

1. **Windows PC**: download `RemKeysAgent-win-x64.zip` from the latest
   [Release](../../releases), unzip it, and run `install-agent.bat` **as
   Administrator**. It registers a logon scheduled task (not a Windows service —
   a session 0 service cannot inject into your desktop) and starts the agent,
   which shows up as a tray icon. Note the PC's Tailscale IP.
2. **Mac**: install `RemKeys-macOS.zip` from the same Release, grant
   Accessibility + Input Monitoring, enter the IP address, and toggle forwarding
   from the menu-bar window (⌘F). Optionally record a global keyboard shortcut
   there to toggle it from any app.
3. **iPhone/iPad**: install from TestFlight, attach a keyboard, enter the IP
   address on the **Start** tab and tap **Start forwarding** (keeps working
   while the app is in the foreground). Optionally record a toggle shortcut in
   Settings.

Any IP address that both ends can reach works — Tailscale is just how it is
normally used, and it is what encrypts and authenticates the link.

## Worth knowing

- **Virtual Input tab (iOS)** — send keys without a physical keyboard: a
  three-column pad with the keys the iPhone keyboard lacks (navigation, editing,
  F-keys) plus a permanent modifier block, and a text field for letters. Built
  for VoiceOver: drag to hear, lift to send.
- **Screen curtain (iOS)** — blacks the display and drops brightness to zero for
  long sessions while forwarding keeps running. Double-tap to bring it back.
- **Lock-screen support (Windows, optional)** — turn it on from the tray menu to
  keep typing at the lock screen, the sign-in screen and UAC prompts. It swaps
  the logon task for a LocalSystem service, and tightens which peers are
  accepted, since anyone who can reach the port could then type as SYSTEM.
- **Key repeat** — held keys repeat at the PC's own repeat delay and rate;
  Windows does not repeat injected keys by itself.
- **Dropped links recover on their own** — TCP keepalive at both ends, the
  newest peer supersedes the older session, and any keys the vanished peer left
  held are released.

## Building

Apple apps (Mac + Xcode 16+):

```sh
brew install xcodegen
xcodegen generate      # writes KeyBridge.xcodeproj (not committed)
open KeyBridge.xcodeproj
```

Windows agent (.NET 8 SDK):

```sh
cd windows-agent
dotnet publish -c Release -o publish
```

Then run `install-agent.bat` from the publish output, as Administrator.

## Documentation

See [`CLAUDE.md`](CLAUDE.md) for architecture, design rationale, build/run
instructions for every component, known gotchas, and CI/CD setup.
