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

### Ignoring the trackpad (setting `ignorePointerWhileForwarding`, off by default)

A **second event tap** in `KeyCapture` swallows every pointer event: clicks,
drags, scrolls, moves, and the gesture types (raw values 18–20, 29–32, 34,
which have no `CGEventType` case). It is installed next to the keyboard tap but
kept **disabled** unless forwarding is on *and* the setting is on, so pointer
events never pass through our main-thread callback otherwise. `AppModel.syncPointerBlocking()`
decides when it is on. Nothing is forwarded; the input is just dropped, which
keeps "no mouse forwarding" intact.

**It requires a toggle shortcut.** Forwarding swallows every key, so without a
shortcut, clicking RemKeys is the only way to stop it. `AppSettings` refuses to
turn the setting on without a shortcut, clearing the shortcut turns it off, and
`syncPointerBlocking` checks for the shortcut again, because that line decides
whether the user can still get out.

A button already held when blocking starts is released on the Mac normally.
Only ups whose down was swallowed are swallowed, so the Mac isn't left in the
middle of a drag.

Not yet verified on hardware: whether the cursor still moves (`mouseMoved` is
dropped, but the cursor may be drawn below the tap), and whether the Dock's
system gestures (three- and four-finger swipes, Mission Control) are really
blocked at this tap. There's no public event field that tells the built-in
trackpad apart from an external mouse, so the setting covers both.

## Updates (`Updater.swift`, Sparkle 2)

The Mac app can't use the App Store's updates, so it carries Sparkle. Every
push to main that changes the Mac app publishes an update. The pieces are:

- **Feed:** `SUFeedURL` points at `appcast.xml` on the rolling
  **`macos-updates` prerelease**, which `deploy-macos.yml` rewrites on each
  build, along with `RemKeys-macOS-<build>.zip` and a fixed-name
  `RemKeys-macOS.zip` for first installs. It's a prerelease on purpose: that's
  never GitHub's "latest", so a Windows-agent release can't displace the feed.
- **Version:** Sparkle compares `CFBundleVersion`, so the lane stamps the
  commit count (`BUILD_NUMBER`), and CI asserts the built bundle carries it.
  Before this, every Mac build shipped as `(1)`.
- **Signing:** each zip is signed with an Ed25519 key. The private half is the
  `SPARKLE_ED_PRIVATE_KEY` secret (base64 of the 32-byte seed, Sparkle's own
  format), and the public half is `SUPublicEDKey` in `project.yml`. CI checks
  the signature against the key *inside the built app* before publishing.
  **Changing or losing the key strands every installed copy**, which would then
  need one manual reinstall.
- **Never installs unasked** (`SUAllowsAutomaticUpdates: false`). An update
  relaunches the app, which ends a forwarding session.
- **Gentle reminders:** Sparkle only shows its own dialog right after launch,
  when forwarding is always off. Otherwise a found update goes through
  `AppModel`'s usual channels: the status line ("Update available (build N)"),
  the "Hero" sound and an announcement. The window's button becomes
  **Install update (build N)…**. The app menu has **Check for Updates…**.
- `scripts/make-appcast.py` writes the one-item appcast. The release notes are
  the Mac-relevant commit subjects of the push.

To verify on hardware: that Accessibility and Input Monitoring grants survive an
update (they should, since both builds carry the same Developer ID identity),
and that Sparkle's dialogs read well with VoiceOver.

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
