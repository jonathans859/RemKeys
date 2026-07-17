# KeyBridge

Type on your Mac or iPhone/iPad keyboard and have the keystrokes replayed on a
Windows PC over Tailscale. Built for daily use with a screen reader; the Windows
side is a standalone service with no NVDA dependency.

- **iOS / macOS apps** — capture the physical keyboard and forward it.
- **Windows agent** — a Windows service that replays the keystrokes via
  `SendInput`.

Keyboard only: no mouse, clipboard, files, or screen sharing.

## Quick start

1. **Windows PC**: download the agent zip from the latest
   [Release](../../releases), unzip, and run `install-service.bat` **as
   Administrator**. Note the PC's Tailscale IP.
2. **Mac**: install the notarized app from the latest Release, grant
   Accessibility + Input Monitoring, enter the Tailscale IP, and toggle
   forwarding from the menu (⌘F). Optionally record a global keyboard shortcut
   in the menu to toggle it from any app.
3. **iPhone/iPad**: install from TestFlight, attach a keyboard, enter the
   Tailscale IP, tap **Start forwarding** (keeps working while the app is
   foreground). Optionally record a keyboard shortcut in Settings to toggle it.

## Documentation

See [`CLAUDE.md`](CLAUDE.md) for architecture, design rationale, build/run
instructions for every component, known gotchas, and CI/CD setup.
