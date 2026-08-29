# macOS app

See [`../CLAUDE.md`](../CLAUDE.md) for the shared architecture and the
accessibility rules.

## Capture (`apps/macOS/KeyCapture.swift`)

- **`CGEventTap` at `.cghidEventTap`** sees every keyDown/keyUp/flagsChanged
  before any app or the system, and (with `.defaultTap`) swallows them while
  forwarding, so the local Mac never reacts to keys meant for the PC.
- **`IOHIDManager`** reads Caps Lock straight off the HID layer, because the
  normal event API only reports Caps Lock as a toggle — no clean up/down.
- **Toggle (UTM pattern):** the tap is installed once at launch and gated behind
  `bridge.forwardingEnabled` — never torn down and rebuilt on toggle. Forwarding
  is toggled from the menu button (⌘F). There is **no hard-wired hotkey**; the
  user can optionally **record** a global chord (`settings.toggleShortcut`) that
  flips forwarding from any app. Recording runs through the same tap, so it can
  capture Caps Lock via HID and swallow the chord so it has no side effect; the
  recorded value is a raw `CGKeyCode` plus a platform-neutral modifier set.
- **ANSI/ISO key-code swap**: `0x32` and `0x0A` swap physical positions between
  board types (ANSI: `0x32` is the key left of 1 and `0x0A` doesn't exist; ISO:
  `0x0A` is left of 1 and `0x32` is the 102nd key next to left Shift), so
  `MacKeyVK` picks per event via `MacKeyboardLayout.isISO` (Carbon
  `KBGetLayoutType` on the event's keyboard type). iOS is immune — HID usages are
  positional.
- **Always-on-top red border overlay** (`CaptureOverlay.swift`) while capturing,
  same as UTM. Purely a redundant visual cue.

### Modifier direction comes from the event's own flag bit

`flagsChanged` names the key that changed but not whether it went down or up.
Recovering that by toggling a `Set<CGKeyCode>` breaks the moment a transition is
missed — and the toggle shortcut misses them by design, since its modifiers
straddle the flip. Field-reported as **Alt stuck held on the PC** after
`Caps+Alt+K`: `toggleForwarding()` cleared the set mid-chord, so Alt's *release*
read as a press, and the phantom left behind inverted Alt for the rest of the
session.

`MacModifierFlag` (`MacKeyCode.swift`) now tests that key's device-dependent bit
(`NX_DEVICE…KEYMASK`, side-specific) in `event.flags`, which re-states the truth on
every event and self-corrects. Toggling a set survives only as the fallback for a
key code with no known bit. Two invariants go with it:

- `downModifiers`/`capsHeld` are **physical** state and are never cleared on
  toggle. Only `forwardedDown` — our idea of what the *remote* holds — is.
- `KeyCapture.forward(keyCode:vk:pressed:)` drops any release whose press we
  didn't forward. Otherwise the chord's own modifiers reach Windows as a bare
  key-up, and a lone Alt up focuses the menu bar in many apps. Modifiers still
  held when forwarding turns *on* are deliberately not pressed on the remote, for
  the same reason.

### fn-key row (`FunctionKeyRow.swift`, setting `forwardFunctionKeyRow`, on by default)

With macOS's default "special keys" behaviour the top row never becomes a key
event at all — the keyboard emits Apple-vendor / consumer HID usages (brightness
`0xFF00000005`, play/pause `0xC000000CD`, Mission Control `0xFF0100000010`) that
the system turns into actions *below* the event tap, so there is nothing to
capture or swallow and the user must hold fn.

Fixed the supported way (Apple TN2450): `hidutil property --set UserKeyMapping`
rewrites those usages to keyboard-page F1–F12 *before* the tap sees them, so they
arrive as ordinary F-key events on the normal `MacKeyVK` path. No root, effective
immediately, gone at reboot. It is **system-wide and one list per user**, so it is
installed only while forwarding is on and cleared on stop/quit — and clearing
resets the list to empty, dropping any hand-made `hidutil` remap the user had.

Don't "improve" this into a `CGEventTap` translation of `NX_SYSDEFINED` events:
several fn-row keys (Mission Control, Spotlight) never produce one.

## UI (`apps/macOS/AppDelegate.swift`, `main.swift`)

- **AppKit entry point, no SwiftUI `App`/`MenuBarExtra`.** A `MenuBarExtra` only
  ever shows a popover: it dismisses on the next click elsewhere and can never
  appear in ⌘-Tab. The status item and window are owned by `AppDelegate`;
  `MenuContentView` is hosted in a real `NSWindow` via `NSHostingController`. The
  main menu is built by hand (no nib) so the window has Close/Hide/Quit.
- **Clicking the menu-bar icon opens that window and leaves it open** (click again
  to put it away). While it is up the app switches to `.regular`, which is what
  puts RemKeys in ⌘-Tab — and, inseparably, in the Dock. Closing the window, or
  hiding the app (⌘H / `applicationDidHide`), goes back to `.accessory`.
  `LSUIElement` stays true; the policy is flipped at runtime.
