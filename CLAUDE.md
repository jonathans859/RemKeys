# RemKeys

Capture physical keyboard input on iOS and macOS, forward it over the network,
and replay it as real keystrokes on a Windows PC. The Windows side is fully
standalone — no dependency on NVDA or any other screen reader.

Per-component notes (read the one you're working in):

- [`docs/ios.md`](docs/ios.md) — iOS capture, Virtual Input tab, visual design
- [`docs/macos.md`](docs/macos.md) — event tap, menu-bar app
- [`docs/windows-agent.md`](docs/windows-agent.md) — modes, injection, lock screen, config
- [`docs/ci-cd.md`](docs/ci-cd.md) — CI, signing, distribution

A commit that changes only the Mac app or the Windows agent but still touches
`BridgeCore/` ends its message with `[skip testflight]`, so iOS testers aren't
sent a build with nothing new in it (see `docs/ci-cd.md`).

| Component | Path | Role |
|---|---|---|
| **BridgeCore** | `BridgeCore/` | Shared Swift package: wire format, Windows VK constants, settings, network client. Used by both apps. |
| **iOS app** | `apps/iOS/` | SwiftUI app, three tabs: Start (captures an external keyboard, forwards while foreground), Virtual Input (on-screen key sender), Settings. |
| **macOS app** | `apps/macOS/` | Menu-bar (`LSUIElement`) app; system-wide capture via `CGEventTap` + `IOHIDManager`. |
| **Windows agent** | `windows-agent/` | C#/.NET 8 worker. Listens on TCP, replays keystrokes via `SendInput`. |

## Naming

The user-facing product is **RemKeys** (the App Store name "KeyBridge" was
taken). That covers everything a user sees: display names, `PRODUCT_NAME`, in-app
strings, the icon, the macOS zip, and the whole Windows agent — file names,
namespace, logon task `RemKeysAgent`, service `RemKeysSecureAgent`, pipes
`RemKeysAgent.inject`/`.status`, config section `RemKeys`, log file names.

Internal names that **stay** KeyBridge, deliberately: Xcode targets and schemes
(`KeyBridge-iOS`/`-macOS`), the bundle id `com.jonathan859.keybridge`, and
`BridgeCore` API names. Renaming those would churn the App Store Connect record
and the signing setup for nothing a user sees. Don't "fix" the mismatch in
either direction.

## Architecture

- **One repo, one Xcode project, two app targets** sharing `BridgeCore`.
  Platform-specific capture and UI live outside the shared core, in `apps/`.
- **Wire format is plain text lines**, one per event:
  `key <vk> pressed=<0|1>` (one physical key transition; `<vk>` is a decimal
  Windows virtual-key code) and `char <codepoint>` (one Unicode character,
  injected as a down+up pair via `KEYEVENTF_UNICODE`, layout-independent — used
  by the iOS virtual-input tab for plain text). Defined in
  `BridgeCore/Sources/BridgeCore/KeyEvent.swift`; the C# mirror is
  `windows-agent/WireProtocol.cs` — keep them in sync.
- **Complete, explicit key mapping tables**, not a "common subset":
  `apps/iOS/HIDToVK.swift` (HID usage → VK) and `apps/macOS/MacKeyVK.swift`
  (CGKeyCode → VK). Both cover full alphanumerics, every modifier individually,
  F1–F20/F24, numpad, the nav/edit cluster, and media keys. **Anything unmapped
  is logged, never silently dropped**, so gaps show up during device testing.
- **Modifier mapping is configurable**, because there is no fixed correct
  mapping between the Apple and Windows layouts. Option and Command each map
  **per physical side** (four `ModifierMapping` settings: `Alt`/`Control`/
  `Windows key`/`AltGr`). Per-side matters because PC-style boards present the
  right-of-space cluster as *right* Option/Command, and "right Option = AltGr"
  must not drag left Option along. AltGr exists because on e.g. German PC
  layouts it is the only way to type @ € { } [ ] \. Shift and Control always map
  straight across. Logitech multi-OS keyboards present their Win-labeled key to
  Apple hosts as *Command*, which is why "Windows key types Ctrl" is the Command
  mapping's default.
- **Networking is peer-to-peer, normally over Tailscale.** No discovery, no
  pairing, no relay, no app-level crypto — Tailscale already encrypts and
  authenticates. The apps take a target IP and connect directly (`BridgeClient`,
  `Network.framework` TCP, Nagle off). Nothing *requires* Tailscale; a plain LAN
  address works identically, which is why the field is labelled "IP address".

### The link can die without saying so

A phone that loses cellular mid-session sends no FIN and no RST, so nothing about
the socket looks wrong at either end. That produced the worst failure mode: the
agent parked in the dead session's read, the OS completing the phone's *new*
handshake into the listen backlog by itself so the phone showed "Connected", and
no keystroke arriving until the agent was restarted. Three rules, none redundant:

1. **The newest peer wins** — the agent accepts continuously and drops the older
   session. This is the one that makes recovery instant.
2. **TCP keepalive on every socket** at both ends (~15s/5s×3 on Windows,
   10s/5s×3 plus a 10s `connectionDropTime` on Apple). The OS default is *off*,
   and two hours when on.
3. **The client rebuilds rather than waits** — `viabilityUpdateHandler` and a
   prolonged `.waiting` both schedule a reconnect; a stale `NWConnection` is
   never nursed.

A working Tailscale link hides interface changes from `NWConnection` (the socket
sits on the tunnel interface), which is why Wi-Fi↔cellular switching always
worked and why keepalive, not path monitoring, is the client's real detector.

## Accessibility (non-negotiable — daily personal use)

- Every control has a label/hint; no state is conveyed by colour or visuals alone.
- **Headings are real headings.** Anything that looks like a section title
  carries `.isHeader` — styling a heading is not enough, say it is one. A custom
  view handed to a `Form`'s `header:` does *not* inherit the trait, and because
  every screen uses one header type, missing it loses rotor navigation app-wide
  at once.
- **A visible label and its accessibility label must not diverge.** Voice Control
  matches on the *visible* string, so shortening a row's text and restoring the
  long phrase in `accessibilityLabel` makes the row unspeakable. Write the label
  once, self-describing.
- **iOS**: state changes are announced via `UIAccessibility.post(.announcement)`.
  Magic tap (two-finger double tap) lives on the root tab view and routes by tab:
  on Virtual Input it sends the built combination, elsewhere it toggles forwarding.
- **macOS**: NSAccessibility announcements are unreliable from an `LSUIElement`
  app, so state rides **three** redundant channels (`AppModel.swift`): a distinct
  audio cue per event, an announcement attempt, and an always-current status line
  in the menu.
- **Windows agent**: the tray tooltip is what NVDA announces, so it is the
  accessible status channel — see `docs/windows-agent.md`.

## Building & running

Apple apps (needs a Mac + Xcode 16+):

```sh
brew install xcodegen
xcodegen generate           # writes KeyBridge.xcodeproj (not committed)
open KeyBridge.xcodeproj    # schemes: KeyBridge-iOS, KeyBridge-macOS
cd BridgeCore && swift test # core unit tests
```

The macOS app needs **Accessibility** and **Input Monitoring** permissions (it
prompts and deep-links to System Settings). Capture cannot be tested in the
Simulator or in SwiftUI previews — real hardware only.

Windows agent (needs .NET 8 SDK):

```sh
cd windows-agent
dotnet publish -c Release -o publish
```

Then, from the publish output and **as Administrator**, `install-agent.bat`.

## Out of scope (do not add)

Mouse/pointer forwarding, clipboard sync, file transfer, screen sharing/video,
auto-update. Keyboard only.

## Status

Everything above is written and building in CI. Outstanding: on-device testing,
in four independently testable milestones — (1) the Windows agent alone, driven
by netcat (`key 65 pressed=1` / `key 65 pressed=0` should type an `a`);
(2) macOS → Windows; (3) iOS → Windows via TestFlight; (4) lock-screen mode (tray
toggle, Win+L, a UAC prompt, then the sign-in screen after a cold boot; the log
should show `(helper:Winlogon)` lines, and turning it off should bring the logon
task back). Lock-screen mode has never been run at all — CI is its first compile.
