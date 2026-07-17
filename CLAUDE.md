# KeyBridge

Capture physical keyboard input on iOS and macOS, forward it over the network,
and replay it as real keystrokes on a Windows PC. The Windows side is a fully
standalone service — no dependency on NVDA or any other screen reader.

Bundle id: `com.jonathan859.keybridge`.

## What each piece does

| Component | Path | Role |
|---|---|---|
| **BridgeCore** | `BridgeCore/` | Shared Swift package: wire format, Windows VK constants, settings, network client. Used by both apps. |
| **iOS app** | `apps/iOS/` | SwiftUI app. Captures an external keyboard via a first-responder `UIView` and forwards while foreground. |
| **macOS app** | `apps/macOS/` | Menu-bar (`LSUIElement`) app. System-wide capture via `CGEventTap` + `IOHIDManager`. |
| **Windows agent** | `windows-agent/` | C#/.NET 8 Worker Service. Listens on TCP, replays keystrokes via `SendInput`. |

## Architecture and why

- **One repo, one Xcode project, two app targets** sharing `BridgeCore`.
  Platform-specific capture (CGEventTap on macOS, UIResponder on iOS) and UI
  (menu bar vs. iOS screens) live outside the shared core, in `apps/`.
- **Wire format is plain text lines**, one per key transition:
  `key <vk> pressed=<0|1>\n`. `<vk>` is a decimal Windows virtual-key code.
  The `key … pressed=…` naming is a convention carried over from an old
  prototype — not an integration point with anything. Defined once in
  `BridgeCore/Sources/BridgeCore/KeyEvent.swift`; the C# mirror is
  `windows-agent/WireProtocol.cs` (keep them in sync).
- **Complete, explicit key mapping tables**, not a "common subset":
  `apps/iOS/HIDToVK.swift` (UIKit HID usage → VK) and
  `apps/macOS/MacKeyVK.swift` (CGKeyCode → VK). Both cover full alphanumerics,
  every modifier individually, F1–F20/F24, numpad, the nav/edit cluster, and
  media keys. **Anything unmapped is logged, never silently dropped**, so gaps
  are visible during on-device testing.
- **Modifier mapping is configurable** because there is no fixed correct
  mapping between the Apple and Windows layouts. iOS Option/Command and macOS
  left/right Option + Command each route through a `ModifierMapping`
  (`Alt`/`Control`/`Windows key`). Shift and Control always map straight across.
- **Networking is peer-to-peer over Tailscale.** No discovery, no pairing, no
  relay, no app-level crypto — Tailscale already encrypts and authenticates.
  The apps have a text field for the target Tailscale IP and connect directly
  (`BridgeClient`, `Network.framework` TCP, Nagle off for low latency).

## Platform capture specifics

### iOS (`apps/iOS/KeyboardCapture.swift`)
- A `UIViewRepresentable`-hosted `CaptureView` holds first responder and reads
  raw `pressesBegan/Ended/Cancelled`. Not UIKeyCommand (no key-up, no
  individual modifiers). Not GCKeyboard — it *does* expose per-key up/down
  including left/right modifiers via `keyChangedHandler`, but the handler has
  a history of silently never firing on real devices (SDL issue #6465), which
  is disqualifying for an input bridge.
- **No "priority override" exists — none is needed.** The reference code's
  `_wantsPriorityOverSystemBehaviorWhenKeyboardEvent()` was dead code, and the
  first attempted fix (`override func
  wantsPriorityOverSystemBehavior(forPressesEvent:)`) overrode a method UIKit
  doesn't have — the only public `wantsPriorityOverSystemBehavior` is a
  property on `UIKeyCommand` (iOS 15+), which we deliberately don't use.
  The documented mechanism (WWDC21 10260) is the one already in place: presses
  reach the first responder's `pressesBegan` before the system acts; the focus
  engine only handles presses passed up via `super`. Claimed keys never call
  super, so Tab/arrows are forwarded, not eaten. (System-reserved chords like
  Cmd-H / Cmd-Space never reach any app; that's an iOS limit, not a bug.)
  Confirming Tab/arrows really flow on iPadOS 15+ hardware is part of testing
  milestone 3; the fallback, if they don't, would be no-op `UIKeyCommand`s
  with `wantsPriorityOverSystemBehavior = true` purely to claim those keys.
- **First-responder reclaim:** `CaptureView.requestReclaim()` posts a
  notification the active capture view answers by re-taking first responder.
  Called after the IP field / settings sheet steals focus, so keys flow again
  without the view having to re-enter a window.
- **Foreground-only, by iOS design.** Physical keyboard input only reaches the
  app while it is foreground and the screen is on — a sandbox restriction with
  no background entitlement. The UI is built around a clear "Forwarding active"
  state, holds the idle timer off while forwarding, and stops forwarding when
  the app leaves the foreground (so the remote never keeps a half-held chord).

### macOS (`apps/macOS/KeyCapture.swift`)
- **`CGEventTap` at `.cghidEventTap`** sees every keyDown/keyUp/flagsChanged
  before any app or the system, and (with `.defaultTap`) swallows them while
  forwarding so the local Mac never reacts to keys meant for the PC.
- **`IOHIDManager`** reads Caps Lock straight off the HID layer, because the
  normal event API only reports Caps Lock as a toggle (no clean up/down).
- **Toggle (UTM pattern):** the tap is installed once at launch and gated
  behind `bridge.forwardingEnabled` — never torn down/rebuilt on toggle.
  Forwarding is toggled from the menu button (⌘F). There is **no hard-wired
  hotkey**; the user can optionally **record** a global chord
  (`settings.toggleShortcut`) that flips forwarding from any app. Recording runs
  through the same tap (so it can capture Caps Lock via HID and swallow the
  chord so it has no side effect); the recorded key code is a raw `CGKeyCode`
  plus a platform-neutral modifier set.
- **Always-on-top red border overlay** (`CaptureOverlay.swift`) while
  capturing, same as UTM. Purely a redundant visual cue.

## Accessibility (non-negotiable — daily personal use)
- Every control has a label/hint; no state is conveyed by color/visuals alone.
- **iOS**: state changes are announced via `UIAccessibility.post(.announcement)`
  (forwarding on/off, connection status). Magic tap (two-finger double tap)
  toggles forwarding from anywhere.
- **macOS**: NSAccessibility announcements are unreliable from a menu-bar
  (`LSUIElement`) app, so state rides **three** redundant channels
  (`AppModel.swift`): a distinct **audio cue** per event, an announcement
  attempt, and an always-current **status line** in the menu. A screen-reader
  user can track remote state from the sound alone.

## Windows agent
- .NET 8 Worker Service, runs as an installable Windows service
  (`install-service.bat` / `uninstall-service.bat`, **run as Administrator**).
- `appsettings.json`: `ListenPort` (default 5391), optional `AllowedRemoteIP`
  (empty = accept any Tailscale peer), `LogDirectory`.
- Keystroke injection via `SendInput` (`KeystrokeInjector.cs`), with the
  extended-key flag set for the nav cluster, right-hand modifiers, numpad
  divide, Win/Apps, and media keys.
- **Never crashes on bad config**: invalid port or busy socket → logs and
  retries; malformed line → logged and skipped, not fatal. Logs to a per-day
  file (`FileLogger.cs`).

## Out of scope (do not add)
Mouse/pointer forwarding, clipboard sync, file transfer, screen sharing/video,
auto-update. Keyboard only.

## Building & running

### Apple apps (needs a Mac + Xcode 16+)
```sh
brew install xcodegen
xcodegen generate           # writes KeyBridge.xcodeproj (not committed)
open KeyBridge.xcodeproj
```
- Schemes: `KeyBridge-iOS`, `KeyBridge-macOS`.
- Core unit tests: `cd BridgeCore && swift test`.
- The macOS app needs **Accessibility** and **Input Monitoring** permissions
  (it prompts and deep-links to System Settings).
- Capture cannot be tested in the Simulator or SwiftUI previews — test on real
  hardware.

### Windows agent (needs .NET 8 SDK)
```sh
cd windows-agent
dotnet build -c Release            # or: dotnet publish -c Release -o publish
```
Then, from the publish output, **as Administrator**: `install-service.bat`.

## CI/CD & distribution
- `.github/workflows/ci.yml` — every push/PR: BridgeCore tests + unsigned
  builds of both apps + a Windows agent build. No secrets.
- **Continuous per-platform deploys**, path-filtered so each fires only when
  its platform (or a shared input: `BridgeCore/**`, `project.yml`,
  `fastlane/**`) changed. All three also fire on Release publish and attach
  their asset to the Release:
  - `deploy-ios.yml` — push to main → TestFlight upload (internal testers via
    a group with automatic distribution). Runs on `macos-26`: ASC's SDK floor
    applies to uploads only, so ci.yml stays on the stabler `macos-15`.
  - `deploy-macos.yml` — push to main → Developer ID-signed, notarized zip as
    a run artifact (and Release asset on release).
  - `deploy-windows.yml` — push to main → agent zip as a run artifact (and
    Release asset on release).
- fastlane lanes: `ios ios_beta`, `mac mac_release` (`fastlane/Fastfile`).
  Build number = `git rev-list --count HEAD` (needs `fetch-depth: 0`):
  monotonic on main, recomputable from any checkout. Re-running a run whose
  upload already succeeded fails as a duplicate build — push a new commit.
  The mac lane signs **manually with Developer ID end-to-end** (the CI
  keychain has no Apple Development cert, so automatic signing would find no
  identity for the archive step; no profile needed without sandbox or
  restricted entitlements).

### ⚠️ Deviation from the original brief: macOS does NOT use TestFlight
The brief asked for TestFlight for both apps. **The macOS app installs a
`CGEventTap`, which requires it to run un-sandboxed. macOS TestFlight / the Mac
App Store require App Sandbox.** The two are mutually exclusive, so the Mac app
is distributed as a **Developer ID-signed, notarized** build via GitHub
Releases (same channel as the Windows agent). iOS is unaffected and still ships
to TestFlight.

### Secrets (all set in the repo as of 2026-07-17)
- iOS TestFlight + macOS notarization: `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8` (App Store Connect API key), `APPLE_TEAM_ID`.
- macOS Developer ID signing: `DEVID_P12` (base64-encoded Developer ID
  Application `.p12`) and `DEVID_P12_PASSWORD`. The `mac_release` lane imports
  the cert into the CI keychain — no `match`, no certs repo.
- Windows release: none.

## Current state
- ✅ Shared `BridgeCore` (wire format, VK table, settings, network client) + tests.
- ✅ iOS app: fixed capture, HID→VK table, forwarding UI, settings, a11y.
- ✅ macOS app: capture from reference, CGKeyCode→VK table, permissions,
  overlay, menu-bar UI, a11y via audio cues + status line.
- ✅ Windows agent: TCP listener, wire parser, SendInput injection, service
  scripts, file logging.
- ✅ XcodeGen project, fastlane, CI + release workflows, docs.
- ✅ Signing secrets wired; asset catalogs with a **generated placeholder
  icon** (gradient + "KB→", `apps/{iOS,macOS}/Assets.xcassets`) — replace
  with real art when available (iOS marketing icon must stay flattened RGB,
  no alpha).
- ⏳ Not yet done: on-device testing on real hardware (iPhone via TestFlight,
  Mac locally, Windows PC).

## Testing milestones (each independently testable on hardware)
1. **Windows agent alone** — run it, `telnet`/netcat `key 65 pressed=1` +
   `key 65 pressed=0`, confirm an `a` is typed.
2. **macOS → Windows** — build the Mac app locally, set the Tailscale IP,
   Caps Lock+F11, type into a Windows editor.
3. **iOS → Windows** — TestFlight build, external keyboard, Start forwarding.
