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
| **macOS app** | `apps/macOS/` | Menu-bar (`LSUIElement`) app; the icon opens a real window (⌘-Tab-able while open). System-wide capture via `CGEventTap` + `IOHIDManager`. |
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
  are visible during on-device testing. One macOS wrinkle: key codes `0x32` and
  `0x0A` swap physical positions between ANSI and ISO boards (ANSI: 0x32 is the
  key left of 1, 0x0A doesn't exist; ISO: 0x0A is left of 1, 0x32 is the 102nd
  key next to left Shift), so `MacKeyVK` picks per event via
  `MacKeyboardLayout.isISO` (Carbon `KBGetLayoutType` on the event's keyboard
  type). Field-reported unswapped 2026-07-28. iOS is immune — HID usages are
  positional.
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
  raw `pressesBegan/Ended/Cancelled`. Not UIKeyCommand as the *main* path (no
  key-up, no individual modifiers).
- **Two capture sources, merged** (`GameControllerCapture.swift`, since
  2026-08-06). `pressesBegan` stays primary, but GCKeyboard's
  `keyChangedHandler` runs beside it: it reads the keyboard at the HID layer,
  below the responder chain and below whatever the system claims, so it still
  sees the Cmd chords UIKit never delivers. It is *not* the sole source
  because the handler has a history of silently never firing on real devices
  (SDL #6465) — so both run and `CaptureView.report(_:pressed:from:)` merges
  them by counting **holders per HID usage**: a key goes down when the first
  source reports it and up when the last one lets go. Whichever source sees a
  key carries it; a key both see is forwarded once; a dead GCKeyboard leaves
  behavior exactly as before. `GCKeyCode` raw values *are* HID usages, so both
  sources resolve through the same `HIDToVK` table (usage-keyed entry point).
  Two gates the HID source needs and the responder chain gave for free:
  it only forwards while the capture view is first responder (it is delivered
  app-wide, so otherwise it would forward what the user types into the app's
  own text fields), and the toggle shortcut's key is suppressed explicitly
  (`swallowedGameControllerKeys`) or it would type itself on the PC.
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

- **SDK 26 Cmd-chord theft**: since the iOS 26 SDK, the system consumes
  Cmd chords (Cmd+B/I/U, Cmd+A/C/V/X/Z/F, …) **before `pressesBegan`** —
  field-verified 2026-07-19 (Win+B reached the PC as a bare Win press;
  Windows-side injection was exonerated by a RegisterHotKey probe fed
  agent-identical scancode INPUTs). **Two fixes have already failed in the
  field**, don't re-try either on its own: stripping the auto-built main menu
  via app-delegate `buildMenu(with:)` (build 24), and claiming the chords
  back in `CaptureView.keyCommands` with priority `UIKeyCommand`s (build 39,
  reported 2026-08-06). Both are kept as belts, plus a third: the
  **GCKeyboard source is the actual carrier** — it sits below the layer doing
  the stealing, which is the only structural reason to expect it to hold.
  Supporting changes shipped with it:
  - `keyCommands` is no longer gated on `forwardingEnabled`. UIKit collects a
    responder's key commands when the responder chain changes, not per
    keystroke, so the old list — empty at the moment the view took first
    responder — plausibly stayed empty all session. A constant list has
    nothing to invalidate. It is safe because the app's text fields are never
    *below* the capture view in the responder chain.
  - `AppDelegate` now also removes the menu groups **upfront** via iOS 26's
    `UIMainMenuSystem.shared.setBuildConfiguration` (`textFormattingPreference
    = .removed` etc.) in `didFinishLaunchingWithOptions`. `buildMenu(with:)`
    runs *after* the menu is built and its chords reserved, which is the
    likeliest reason build 24's removals changed nothing.
  - A claimed chord no longer forwards its synthetic `USCharVK` down+up when
    the HID source is live — that would type the key twice.
  - Diagnostics gained **HID capture / Last HID key / Command chords claimed**,
    so one field test now says which layer a missing chord died at: "Last key
    seen" is UIKit, "Last HID key" is GCKeyboard, and a chord that shows up in
    neither never reached the app at all.

### iOS virtual input (`apps/iOS/VirtualInputView.swift`)
- On-screen key sender (iOS-only tab), VoiceOver-first. The UI is the
  **direct-touch key pad** plus a text field, a "will send" readout, and
  Send (also magic tap on that tab). The earlier **adjustable-rows UI was
  built, refined twice, and retired 2026-07-19** once the pad worked — the
  user chose pad-only to give the pad the screen space. Lessons that must
  survive the rows' removal: send-on-adjust fires every intermediate value
  (field-rejected 2026-07-18, don't reintroduce anywhere); VoiceOver
  double-tap activation latency is system-inherent — which is exactly why
  the pad exists.
- **Direct-touch key pad** (`VirtualKeyPad.swift`): ONE accessibility
  element (never per-band regions — that would break explore-by-touch
  around it) with `.allowsDirectInteraction` + `[.silentOnTouch]` —
  **instant pass-through, no activation step**: `.requiresActivation` was
  tried and field-rejected as an extra hop (2026-07-19); touching the pad
  interacts immediately, piano-app style. Default **grid model** =
  VoiceOver touch-typing grammar: fixed bands (modifiers / editing /
  navigation / F1–F12 / opt-in F13–F24 via `virtualPadExtendedFKeys`), drag
  announces the key under the finger (interrupting + haptic tick), lift
  sends it instantly wrapped in the toggled modifiers, lift on a modifier
  toggles it, two-finger tap clears modifiers, extra finger mid-drag
  aborts. **Slider model** (`virtualPadSliderMode`) is the fallback: swipe
  left/right = band, up = forward / down = back (the VoiceOver-adjustable
  convention; a down-forward flip was requested and reverted as a mistake
  the same day, 2026-07-19 — keep the convention), tap = send, two-finger
  swipe left = reset band, and stepping past either end answers with a
  harder edge haptic (`.rigid`) against the normal selection tick.
  **The pad must live OUTSIDE the Form** (pinned above it): a scroll-view
  ancestor delays touch delivery and cancels moved touches, which kills
  drag-to-hear/lift-to-send under direct touch — build 25 shipped it inside
  a Form section and the pad was dead in the field (2026-07-19). Don't move
  it back into scrollable content.
- **Tab layout (field-specified 2026-07-19, revised 2026-08-06):** pad
  filling everything from the title down, over a **single control row** at
  the bottom: text field, dismiss keyboard, keep text, Send. No Form on this
  tab. That row must be a **bottom `safeAreaInset`** (messenger input-bar
  pattern), not a `VStack` sibling — as a sibling the on-screen keyboard
  covered Send/keep-text/dismiss (field-reported 2026-08-05); as an inset it
  rides up with the keyboard and the pad gives up the height.
  All iOS titles are **`.navigationBarTitleDisplayMode(.inline)`** (all three
  tabs + `InfoSheet`): the default large title sits low, costs ~50 points,
  and — with the pad being non-scrollable content it can't collapse into —
  overlapped the pad once the keyboard squeezed the layout (field-reported
  2026-08-06). Inline puts the heading at the top of the screen, smaller, and
  the pad takes the reclaimed height. Don't go back to large titles.
  The separate "Will send" readout was **removed** — it cost a whole row
  for something only VoiceOver read; what Send will deliver is now Send's
  **accessibility hint** (`comboDescription`, recomputed on focus), and the
  pad already tints its toggled modifiers. Don't reintroduce the readout row.
- **Every tab has a top-right info button** (`InfoSheet.swift`) opening a
  sheet that explains the screen *as currently configured* (e.g. Virtual
  Input's text follows `virtualPadSliderMode`). The Start tab's sheet also
  hosts the tips and the live **diagnostics section** (moved off the main
  screen to keep Start lean); its dismissal calls
  `CaptureView.requestReclaim()`.
- Picks **Windows keys directly** (`VirtualKeys.swift`) — no `ModifierMapping`
  involved; AltGr is just `VK_RMENU`.
- Sending rides the same connection as forwarding (`forwardingEnabled` on +
  connected). If off, Send turns it on and asks the user to re-trigger —
  deliberately no queuing of the combo.
- Text rules: **no modifiers → `char` unicode lines** (layout-proof, umlauts
  work); **with modifiers → US-position VKs** via `USCharVK` (shortcut
  semantics, Shift-wrapped as needed, unmappable characters skipped and
  announced).
- **Sticky text** (`virtualInputKeepText`, off by default): Send normally
  clears the text field; with this on it keeps its contents so the same text
  fires again on the next Send. Requested 2026-08-05 for single-letter
  screen-reader navigation on the PC (`h` for headings), where retyping the
  letter after every send was the whole cost. Modifiers still reset on Send in
  both modes — only the text is sticky. Its toggle lives **in the text row**
  (between the field and Dismiss keyboard), not in Settings: it is flipped
  several times per session, unlike the set-and-forget pad settings.

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
- **Modifier direction comes from the event's own flag bit, never from
  inferring.** `flagsChanged` names the key that changed but not whether it
  went down or up; recovering that by toggling a `Set<CGKeyCode>` breaks the
  moment a transition is missed, and the toggle shortcut misses them by design
  (its modifiers straddle the flip). Field-reported 2026-08-08 as **Alt stuck
  held on the PC** after using `Caps+Alt+K`: `toggleForwarding()` cleared the
  set mid-chord, so Alt's *release* read as a press — and the phantom left
  behind inverted Alt for the rest of the session. Now `MacModifierFlag`
  (`MacKeyCode.swift`) tests that key's device-dependent bit
  (`NX_DEVICE…KEYMASK`, side-specific) in `event.flags`, which re-states the
  truth on every event and self-corrects. Toggling a set survives only as the
  fallback for a key code with no known bit. Two invariants go with it:
  `downModifiers`/`capsHeld` are **physical** state and are never cleared on
  toggle (only `forwardedDown`, our idea of what the *remote* holds, is), and
  `KeyCapture.forward(keyCode:vk:pressed:)` drops any release whose press we
  didn't forward — otherwise the chord's own modifiers reach Windows as a bare
  key-up, and a lone Alt up focuses the menu bar in many apps. Modifiers still
  held when forwarding turns *on* are deliberately not pressed on the remote,
  for the same reason.
- **Always-on-top red border overlay** (`CaptureOverlay.swift`) while
  capturing, same as UTM. Purely a redundant visual cue.
- **fn-key row** (`FunctionKeyRow.swift`, setting `forwardFunctionKeyRow`, on
  by default): with macOS's default "special keys" behaviour the top row never
  becomes a key event at all — the keyboard emits Apple-vendor / consumer HID
  usages (brightness `0xFF00000005`, play/pause `0xC000000CD`, Mission Control
  `0xFF0100000010`) that the system turns into actions *below* the event tap,
  so there is nothing to capture or swallow and the user must hold fn. Fixed
  the supported way (Apple TN2450): `hidutil property --set UserKeyMapping`
  rewrites those usages to keyboard-page F1–F12 *before* the tap sees them, so
  they arrive as ordinary F-key events on the normal `MacKeyVK` path. No root,
  effective immediately, gone at reboot. It is **system-wide and one list per
  user**, so it is installed only while forwarding is on and cleared on
  stop/quit — clearing resets the list to empty, dropping any hand-made
  `hidutil` remap the user had. Don't "improve" this into a `CGEventTap`
  translation of `NX_SYSDEFINED` events: several fn-row keys (Mission Control,
  Spotlight) never produce one.

### macOS UI (`apps/macOS/AppDelegate.swift`, `main.swift`)
- **AppKit entry point, no SwiftUI `App`/`MenuBarExtra`.** A `MenuBarExtra`
  only ever shows a popover: it dismisses on the next click elsewhere and can
  never appear in ⌘-Tab. The status item and window are owned by
  `AppDelegate`; `MenuContentView` is hosted in a real `NSWindow` via
  `NSHostingController`. The main menu is built by hand (no nib) so the window
  has Close/Hide/Quit.
- **Clicking the menu-bar icon opens that window and leaves it open** (click
  again to put it away). While it is up the app switches to `.regular`, which
  is what puts RemKeys in ⌘-Tab — and, inseparably, in the Dock. Closing the
  window, or hiding the app (⌘H / `applicationDidHide`), goes back to
  `.accessory`, i.e. menu-bar only. `LSUIElement` stays true; the policy is
  flipped at runtime.

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
- .NET 8 worker host, **one exe with four modes** (`AgentMode.cs`): no args =
  the in-session agent, `--service` = the lock-screen supervisor, `--helper
  --desktop <name>` = a per-desktop injector, and `--install-service` /
  `--uninstall-service` = the one-shot mode switchers.
- **Default install: a logon scheduled task in the user's session, and the
  injecting process is NEVER a session 0 service** (`install-agent.bat` /
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

### Optional lock-screen support (service + per-desktop helpers)
- **The problem it solves is a *desktop* problem, not a privilege one.** The
  lock screen, the sign-in screen and the UAC consent prompt render on the
  `Winlogon` desktop; `SendInput` only ever reaches the input queue of the
  desktop the calling thread is attached to. No integrity level and no
  uiAccess flag crosses that boundary — **uiAccess would buy nothing here**
  (and is unreachable unsigned anyway). The only fix is a process *on that
  desktop*.
- **Shape**: a LocalSystem service (`KeyBridgeSecureAgent`) owns the socket,
  the wire parser and the peer policy in session 0, and never injects.
  `DesktopSupervisor` duplicates the service's own token, re-homes it to the
  console session (`WTSGetActiveConsoleSessionId` +
  `SetTokenInformation(TokenSessionId)`) and `CreateProcessAsUser`s one helper
  per desktop with `STARTUPINFO.lpDesktop` = `WinSta0\Default` /
  `WinSta0\Winlogon` (`Native.cs`). Parsed events go out over a named pipe
  (`InjectionChannel.cs`) as the *same* newline wire format, so helpers reuse
  `WireProtocol`/`LineReader` and never see anything the parser didn't approve.
- **Helpers self-route**: the hub broadcasts to both, and each injects only
  while `OpenInputDesktop` says its own desktop is in front (50 ms cache,
  250 ms poll). That decision must live in the helper — session 0 is on a
  different window station and cannot see these desktops at all. When a helper
  goes inactive it **releases every key it still holds**, or locking mid-chord
  leaves a modifier stuck on the desktop being left.
- Helpers run as **LocalSystem, i.e. above High IL**, so elevated windows and
  NVDA's uiAccess dialogs work with no certificate and no elevation dance —
  the un-elevated footgun simply doesn't exist in this mode. It also starts
  **before sign-in**, so the password can be typed at a cold boot.
- **A helper's life is one pipe session.** It exits when the pipe drops rather
  than reconnecting; the supervisor spawns a fresh one. A lingering helper
  plus a new one would be two injectors on one desktop typing everything
  twice. For the same reason the hub is registered *after* the supervisor:
  hosted services stop in reverse, so pipes close (helpers leave cleanly,
  releasing held keys) before the supervisor reaches for `Kill()`.
- **The tray must NOT live in a helper.** Helpers are LocalSystem, i.e. System
  integrity, and a screen reader at medium IL with uiAccess **cannot read the
  UI of a System-integrity process** — uiAccess reaches into *elevated* apps,
  not into SYSTEM ones. Build 1 put the tray in the Default helper and the menu
  came up **empty in NVDA** (field-reported 2026-08-06), taking the accessible
  status channel with it. So the **logon task stays registered in both modes**:
  with the service on, that user-session process runs no listener and injects
  nothing — it is just the tray, fed by a second pipe
  (`KeyBridgeAgent.status`, `StatusChannel.cs`) carrying the status line out
  and exactly one command (`stop`) back. That pipe is separate from the
  injection pipe *on purpose*: the injection pipe stays LocalSystem-only
  because it types on the secure desktop, while the status pipe is ACL'd for
  `Interactive` so the signed-in user can read it.
- **Exactly one of the two may own the port** — the service and an in-session
  *listener* would fight for 5391. Switching is a tray menu item ("Turn on/off
  lock screen support…", `TrayHosts.cs`) that relaunches the exe with the
  install/uninstall verb; `install-lockscreen.bat` / `uninstall-lockscreen.bat`
  are the no-tray recovery path. Install stops the logon task just long enough
  to hand the port over, then re-creates and re-runs it (asking WTS who is
  signed in, since LocalSystem has no "current user"); the restarted process
  sees the service running and comes up as a tray client instead.
- **Security consequence, deliberate**: with this on, anyone who can reach the
  port can type at the lock screen, and the listener is LocalSystem. So in
  service mode *only*, the peer policy tightens — loopback is refused
  (otherwise any medium-IL process on the PC could type as SYSTEM on the
  secure desktop, a local EoP that doesn't exist otherwise) and peers outside
  Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48) are refused.
  `AllowLoopbackPeers` / `AllowNonTailscalePeers` override. The in-session
  agent keeps its old laxer policy: it can only do what the signed-in user
  already could.
- **Ctrl+Alt+Del cannot be injected** — SAS is handled below the input stack.
  On a box with *Require Ctrl+Alt+Del* set, that needs `SendSAS()` and the
  `SoftwareSASGeneration` policy; on a default Windows 11 install any keypress
  goes straight to the password field. Not implemented.
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
  channel. Exit menu item stops the host cleanly (in lock-screen mode it asks
  the service to stop over the status pipe, taking the helpers with it).
  `install-agent.bat` also clears schtasks defaults that killed the agent
  (72-h execution limit, stop-on-battery). The tray always runs in the
  **user's session** (the logon task), never in a LocalSystem process — see
  the lock-screen section for why.
- `appsettings.json`: `ListenPort` (default 5391), optional `AllowedRemoteIP`
  (empty = accept any Tailscale peer), `LogDirectory`, and the lock-screen-only
  `AllowLoopbackPeers` / `AllowNonTailscalePeers` (both off).
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
    a run artifact (and Release asset on release). Was disabled 2026-07-17
    over a wrong `DEVID_P12_PASSWORD`; the secret was fixed and the workflow
    re-enabled 2026-07-18 (green runs since).
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
- ✅ Windows agent lock-screen mode: LocalSystem supervisor service +
  per-desktop helpers, tray toggle, tightened peer policy. **Written but never
  run** — no .NET SDK on Jonathan's PC, so CI is its first compile and
  milestone 4 its first execution.
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
4. **Lock-screen mode** — tray → "Turn on lock screen support…", confirm the
   tray comes back and normal typing still works; then Win+L and type; then a
   UAC prompt; then a full reboot and type the password at the sign-in screen.
   Check the log has `(helper:Winlogon)` lines. Turn it off again from the tray
   and confirm the logon task is back.
