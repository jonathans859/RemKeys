# KeyBridge

Capture physical keyboard input on iOS and macOS, forward it over the network,
and replay it as real keystrokes on a Windows PC. The Windows side is a fully
standalone service — no dependency on NVDA or any other screen reader.

Bundle id: `com.jonathan859.keybridge`.

**Naming**: the user-facing product name is **RemKeys** (the App Store name
"KeyBridge" was taken, so the ASC app record is "RemKeys"). The rebrand covers
everything a user sees: display names, `PRODUCT_NAME` (so the bundle is
`RemKeys.app` / `RemKeys.ipa`), in-app strings, permission-prompt text, the
icon, and the macOS zip (`RemKeys-macOS.zip`). Internal names stay KeyBridge —
targets/schemes (`KeyBridge-iOS`/`-macOS`), bundle id, `BridgeCore`
API names, and the Windows agent (`KeyBridgeAgent`, service name, its zip) —
renaming those buys nothing and would churn CI, the ASC record, and installed
services. Don't "fix" the mismatch in either direction. (Exception: Jonathan
renamed the GitHub repo itself to `jonathans859/RemKeys` on 2026-07-18; old
`…/keybridge` URLs redirect.)

## What each piece does

| Component | Path | Role |
|---|---|---|
| **BridgeCore** | `BridgeCore/` | Shared Swift package: wire format, Windows VK constants, settings, network client. Used by both apps. |
| **iOS app** | `apps/iOS/` | SwiftUI app, three tabs: Start (captures an external keyboard via a first-responder `UIView`, forwards while foreground), Virtual Input (on-screen key sender, no physical keyboard needed), Settings. |
| **macOS app** | `apps/macOS/` | Menu-bar (`LSUIElement`) app. System-wide capture via `CGEventTap` + `IOHIDManager`. |
| **Windows agent** | `windows-agent/` | C#/.NET 8 Worker Service. Listens on TCP, replays keystrokes via `SendInput`. |

## Architecture and why

- **One repo, one Xcode project, two app targets** sharing `BridgeCore`.
  Platform-specific capture (CGEventTap on macOS, UIResponder on iOS) and UI
  (menu bar vs. iOS screens) live outside the shared core, in `apps/`.
- **Wire format is plain text lines**, one per event. Two line types:
  `key <vk> pressed=<0|1>\n` (one physical key transition; `<vk>` is a decimal
  Windows virtual-key code) and `char <codepoint>\n` (one Unicode character to
  type, injected as a down+up pair via `KEYEVENTF_UNICODE`, layout-independent
  — used by the iOS virtual-input tab for plain text). The `key … pressed=…`
  naming is a convention carried over from an old prototype — not an
  integration point with anything. Defined once in
  `BridgeCore/Sources/BridgeCore/KeyEvent.swift`; the C# mirror is
  `windows-agent/WireProtocol.cs` (keep them in sync).
- **Complete, explicit key mapping tables**, not a "common subset":
  `apps/iOS/HIDToVK.swift` (UIKit HID usage → VK) and
  `apps/macOS/MacKeyVK.swift` (CGKeyCode → VK). Both cover full alphanumerics,
  every modifier individually, F1–F20/F24, numpad, the nav/edit cluster, and
  media keys. **Anything unmapped is logged, never silently dropped**, so gaps
  are visible during on-device testing.
- **Modifier mapping is configurable** because there is no fixed correct
  mapping between the Apple and Windows layouts. Option and Command each map
  **per physical side** on both platforms — four `ModifierMapping` settings
  (`Alt`/`Control`/`Windows key`/`AltGr`): left/right Option, left/right
  Command. Per-side matters because PC-style boards present the right-of-space
  cluster as *right* Option/Command, and "right Option = AltGr" must not drag
  left Option along (single-mapping installs migrate by seeding both sides). AltGr exists because on e.g. German
  PC layouts it is the only way to type @ € { } [ ] \. Shift and Control
  always map straight across. Note: Logitech multi-OS keyboards (MX Keys)
  present their Win-labeled key to Apple hosts as *Command*, so "Windows key
  types Ctrl" = the Command mapping's default, changeable in Settings.
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
- **Screen curtain** (Start tab button, overlay in `RootTabView`): black
  overlay + brightness 0, the battery saver for long forwarding sessions;
  double-tap dismisses. Offered **only while VoiceOver is off** — VoiceOver
  has its own Screen Curtain and the dismissal gesture would collide.
  Brightness is a system-sticky setting, so it auto-restores on backgrounding
  and if VoiceOver turns on mid-curtain. Idle timer is held while forwarding
  *or* curtained. Capture keeps working under the overlay.

- **SDK 26 menu theft** (`AppDelegate.swift`): building against the iOS 26
  SDK auto-creates a main menu (`UIMainMenuSystem`) whose default commands
  (Cmd+B/I/U, Cmd+A/C/V/X/Z/F, …) consume matching chords **before
  `pressesBegan`** — field-verified 2026-07-19 (Win+B reached the PC as a
  bare Win press; Windows-side injection was exonerated by a RegisterHotKey
  probe fed agent-identical scancode INPUTs). Fix: app-delegate
  `buildMenu(with:)` removes every removable menu. Don't re-add menus.

### iOS virtual input (`apps/iOS/VirtualInputView.swift`)
- On-screen key sender (iOS-only tab), VoiceOver-first: each category row
  (editing, navigation, F-keys) is exposed to VoiceOver as **one adjustable
  element whose position IS the selection** — option 0 is "None", swipe
  up/down lands on the key the row holds (per-key buttons were rejected
  first, then browse+double-tap-to-select). Multiple rows can each
  contribute a key, tapped in row order. The **modifiers row alone** keeps
  browse + double-tap-toggle because several can be on at once. Visible
  buttons serve touch only. Plus a text field, a "will send" readout, and
  Send (also magic tap on that tab). Send resets everything to None.
- **Double-tapping a key row sends just that row's key immediately** —
  wrapped in the toggled modifiers when the "Rows send with modifiers"
  setting is on (`AppSettings.virtualRowSendsModifiers`, default on).
  Activation deliberately changes *nothing* (no value change, no reset, no
  focus move, silent on success, queued announcement on failure only), so
  repeated double taps repeat the key; a three-finger scroll on a row
  resets it to None without sending. **Send-on-adjust was tried and
  field-rejected the same day (2026-07-18)**: swiping across a row fired
  every intermediate key — don't reintroduce it. Known open issue:
  VoiceOver's double-tap activation latency is system-inherent and still
  feels sluggish to the user; split tap helps, and a direct-touch send pad
  (`allowsDirectInteraction`) is the designed escalation if needed.
- **Direct-touch key pad** (`VirtualKeyPad.swift`, added 2026-07-19 after the
  rows' VoiceOver latency was field-rejected): ONE accessibility element
  (never per-band regions — that would break explore-by-touch around it) with
  `.allowsDirectInteraction` + `[.silentOnTouch, .requiresActivation]`, so
  exploring can't misfire and one double tap enters direct mode. Default
  **grid model** = VoiceOver touch-typing grammar: fixed bands (modifiers /
  editing / navigation / F1–F12 / opt-in F13–F24 via
  `virtualPadExtendedFKeys`), drag announces the key under the finger
  (interrupting + haptic tick), lift sends it instantly, lift on a modifier
  toggles it, two-finger tap clears modifiers, extra finger mid-drag aborts.
  **Slider model** (`virtualPadSliderMode`) is the fallback: swipe
  left/right = band, up/down = value, tap = send, two-finger swipe left =
  reset band. Pad shares the toggled-modifier state with the rows and
  **always** wraps sends in them (`virtualRowSendsModifiers` is rows-only).
  The rows below stay — Switch Control / Full Keyboard Access path.
- Picks **Windows keys directly** (`VirtualKeys.swift`) — no `ModifierMapping`
  involved; AltGr is just `VK_RMENU`.
- Sending rides the same connection as forwarding (`forwardingEnabled` on +
  connected). If off, Send turns it on and asks the user to re-trigger —
  deliberately no queuing of the combo.
- Text rules: **no modifiers → `char` unicode lines** (layout-proof, umlauts
  work); **with modifiers → US-position VKs** via `USCharVK` (shortcut
  semantics, Shift-wrapped as needed, unmappable characters skipped and
  announced).

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
  lives on the root tab view and routes by tab: on Virtual Input it sends the
  built combination, elsewhere it toggles forwarding.
- **macOS**: NSAccessibility announcements are unreliable from a menu-bar
  (`LSUIElement`) app, so state rides **three** redundant channels
  (`AppModel.swift`): a distinct **audio cue** per event, an announcement
  attempt, and an always-current **status line** in the menu. A screen-reader
  user can track remote state from the sound alone.

## Windows agent
- .NET 8 worker host. **Runs as a logon scheduled task in the user's
  session, NOT a Windows service** (`install-agent.bat` /
  `uninstall-agent.bat`, **run as Administrator**). A service lives in
  session 0, where `SendInput` cannot reach the interactive desktop — every
  injection is rejected (verified in the field 2026-07-17; the agent
  received keystrokes and logged `SendInput rejected` for each). The task
  runs with highest privileges so injection also reaches elevated windows.
  Built as `WinExe` (windowless): the task must not spawn a console window a
  user could close to accidentally kill the agent — all output goes to the
  file logger, stop via `uninstall-agent.bat`/Task Scheduler. The content
  root is pinned to `AppContext.BaseDirectory` because the task starts in
  `System32`, where the default (CWD) content root would silently miss the
  `appsettings.json` next to the exe.
- **Must run elevated — un-elevated failure is silent and dialog-specific.**
  `SendInput` into windows of **uiAccess** processes (installed NVDA runs
  `uiAccess="True"` — its own dialogs!) or elevated apps is discarded by
  UIPI with *no error and no failing return value* (documented behavior;
  field-verified 2026-07-18: a hand-launched Medium-IL agent typed fine
  everywhere except NVDA's dialogs, with zero log entries). The agent
  therefore logs a loud startup warning and flags the tray status when
  un-elevated. Launch via the scheduled task, never by double-clicking.
- **Single instance** (named mutex; a second launch logs one line and
  exits — the windowless exe invited accidental multi-launch, which piled
  up port-retry loops) and a **tray icon** (WinForms `NotifyIcon`; csproj
  targets `net8.0-windows` + `UseWindowsForms`, `EnableWindowsTargeting`
  keeps the ubuntu CI job compiling). Tray tooltip + a disabled menu line
  carry live status ("Waiting for a connection on port 5391" /
  "Connected to <ip>" / "Port busy", with a "not elevated!" marker) — the
  tooltip is what NVDA announces in the tray, so it's the accessible status
  channel. Exit menu item stops the host cleanly. `install-agent.bat` also
  clears schtasks defaults that killed the agent (72-h execution limit,
  stop-on-battery).
- `appsettings.json`: `ListenPort` (default 5391), optional `AllowedRemoteIP`
  (empty = accept any Tailscale peer), `LogDirectory`.
- Keystroke injection via `SendInput` (`KeystrokeInjector.cs`), with the
  extended-key flag set for the nav cluster, right-hand modifiers, numpad
  divide, Win/Apps, and media keys. **All keys are injected scancode-primary
  (`KEYEVENTF_SCANCODE`), not as VKs** — games reading Raw Input/DirectInput
  identify keys by scancode and silently drop make-code-0 (VK-only) events,
  so a VK path would work in normal apps but lose arrows/F-keys/modifiers in
  games. Layout-sensitive keys (letters, digits, punctuation) use a fixed
  US-positional scancode table: the senders encode physical positions as
  US-meaning VKs, and scancode injection lets the PC's active layout (e.g.
  German QWERTZ) choose the character. Layout-independent keys resolve via
  `MapVirtualKeyW` at send time — with quirk handling: the nav cluster maps
  without its E0 prefix (the `ExtendedKeys` set disambiguates arrows from
  numpad), PrintScreen maps to the Alt+SysRq code (overridden to `E0 37`),
  and Pause is E1-multi-byte, the one key left on the VK path. Anti-cheat
  systems that filter injected input entirely (Vanguard etc.) are out of
  scope — that needs a driver.
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
Then, from the publish output, **as Administrator**: `install-agent.bat`
(registers a logon scheduled task — see the Windows agent section for why it
must not be a service).

## CI/CD & distribution
- `.github/workflows/ci.yml` — every push/PR: BridgeCore tests + an unsigned
  macOS app build (one macOS job — jobs bill separately and macOS is 10x) +
  a Windows agent build on ubuntu (1x vs 2x on windows). No secrets.
  **No iOS build in CI on purpose**: deploy-ios compiles the same code
  against the real SDK on every main push, so a simulator build was
  redundant billed minutes. Jonathan is cost-sensitive about Actions
  minutes — don't add macOS jobs casually.
- **Continuous per-platform deploys**, path-filtered so each fires only when
  its platform (or a shared input: `BridgeCore/**`, `project.yml`,
  `fastlane/**`) changed. All three also fire on Release publish and attach
  their asset to the Release:
  - `deploy-ios.yml` — push to main → TestFlight upload (internal testers via
    a group with automatic distribution). Runs on `macos-26`: ASC's SDK floor
    applies to uploads only, so ci.yml stays on the stabler `macos-15`.
  - `deploy-macos.yml` — push to main → Developer ID-signed, notarized zip as
    a run artifact (and Release asset on release). **Currently disabled**
    (`gh workflow disable`) — its `DEVID_P12_PASSWORD` secret is wrong, so
    every run failed at signing on billed minutes; re-enable once fixed.
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
- iOS signing: `IOS_DEV_P12` + `IOS_DEV_P12_PASSWORD` — ONE cached Apple
  Development cert (key material in `~/Downloads/keybridge/ios_dev.*` on
  Jonathan's PC, minted 2026-07-18 via the ASC API). Imported into the CI
  keychain by the `ios_beta` lane so Xcode cloud signing reuses it; without
  it every ephemeral runner minted a new certificate until the account hit
  Apple's cap and archiving failed with "Choose a certificate to revoke".
- macOS Developer ID signing: `DEVID_P12` (base64-encoded Developer ID
  Application `.p12`) and `DEVID_P12_PASSWORD`. The `mac_release` lane imports
  the cert into the CI keychain — no `match`, no certs repo.
- **Any .p12 destined for CI must be exported in legacy format**
  (`openssl pkcs12 -export … -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
  -macalg sha1`): macOS `security import` rejects OpenSSL 3's default
  encoding with "MAC verification failed (wrong password?)" even when the
  password is right, and `import_certificate` doesn't fail the run on it —
  the lanes now assert the identity is present right after import.
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
