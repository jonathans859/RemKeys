# iOS app

Shared architecture and the accessibility rules: [`../CLAUDE.md`](../CLAUDE.md).

## Capture (`KeyboardCapture.swift`)

- A `UIViewRepresentable`-hosted `CaptureView` holds first responder and reads raw
  `pressesBegan/Ended/Cancelled`. Not `UIKeyCommand` as the *main* path — it gives
  no key-up and no individual modifiers.
- **Two capture sources, merged** (`GameControllerCapture.swift`). `pressesBegan`
  stays primary; `GCKeyboard`'s `keyChangedHandler` runs beside it because it reads
  the keyboard below the responder chain, so it still sees the Cmd chords UIKit
  never delivers. It is *not* the sole source — that handler has a history of
  silently never firing on real devices (SDL #6465).
  `CaptureView.report(_:pressed:from:)` merges them by counting **holders per HID
  usage**: down on the first source to report it, up when the last lets go. So a key
  both see is forwarded once, and a dead `GCKeyboard` changes nothing. `GCKeyCode`
  raw values *are* HID usages, so both resolve through the same `HIDToVK` table.
- Two gates the HID source needs and the responder chain gave for free: it forwards
  only while the capture view is first responder (it is delivered app-wide, so
  otherwise it would forward what the user types into the app's own text fields),
  and the toggle shortcut's key is suppressed explicitly
  (`swallowedGameControllerKeys`) or it would type itself on the PC.
- **No "priority override" exists, and none is needed.** The documented mechanism
  (WWDC21 10260) is already in place: presses reach the first responder's
  `pressesBegan` before the system acts, and the focus engine only handles presses
  passed up via `super`. Claimed keys never call super, so Tab and arrows are
  forwarded, not eaten. Don't re-add
  `wantsPriorityOverSystemBehavior(forPressesEvent:)` — UIKit has no such method;
  the only public one is a property on `UIKeyCommand`, which we deliberately don't
  use. System-reserved chords (Cmd-H, Cmd-Space) never reach any app: an iOS limit.
- **First-responder reclaim**: `CaptureView.requestReclaim()` posts a notification
  the active capture view answers by re-taking first responder. Called after the IP
  field or a sheet steals focus.
- **Foreground-only, by iOS design** — no background entitlement exists. The idle
  timer is held off while forwarding.
- **`.inactive` is not a reason to stop.** Only `.background` ends the session;
  Control Center, the app switcher and a call banner are all `.inactive` and none is
  the user leaving. `.inactive` instead **lets go of every held key**
  (`BridgeClient.releaseHeldKeys()` + `CaptureView.requestForgetHeldKeys()`):
  presses stop being delivered under a system overlay, so a key physically down
  right then may never report its release — and a key the capture view still
  believes held would block its own next press. An extra key-up on the PC is
  harmless; a stuck one is not. Returning to `.active` calls `requestReclaim()`.

### SDK 26 Cmd-chord theft

Since the iOS 26 SDK the system consumes Cmd chords (Cmd+B/I/U, Cmd+A/C/V/X/Z/F, …)
**before `pressesBegan`** — field-verified, with Windows-side injection exonerated
by a `RegisterHotKey` probe fed agent-identical scancode INPUTs.

**Two fixes already failed in the field — don't re-try either on its own**:
stripping the auto-built main menu via app-delegate `buildMenu(with:)`, and claiming
the chords back with priority `UIKeyCommand`s in `CaptureView.keyCommands`. Both are
kept as belts; the actual carrier is the **`GCKeyboard` source, which sits below the
layer doing the stealing**. What went with it:

- `keyCommands` is not gated on `forwardingEnabled`: UIKit collects key commands
  when the responder chain changes, not per keystroke, so a list that was empty when
  the view took first responder plausibly stayed empty all session. Safe because the
  app's text fields are never *below* the capture view in the chain.
- `AppDelegate` also removes the menu groups **upfront** via
  `UIMainMenuSystem.shared.setBuildConfiguration` in
  `didFinishLaunchingWithOptions`; `buildMenu(with:)` runs after the menu is built
  and its chords reserved, which is likeliest why it changed nothing.
- A claimed chord does not forward its synthetic `USCharVK` down+up while the HID
  source is live, or the key types twice.
- Diagnostics carry **HID capture / Last HID key / Command chords claimed**, so one
  field test says which layer a missing chord died at: "Last key seen" is UIKit,
  "Last HID key" is `GCKeyboard`, a chord in neither never reached the app.

### Screen curtain

Start-tab button, overlay in `RootTabView`: black overlay plus brightness 0, the
battery saver for long sessions. Double-tap dismisses; the idle timer is held while
forwarding *or* curtained, and capture keeps working underneath.

- **The overlay and the brightness are held separately** (`curtainActive` vs
  `brightnessHeldDown`). Brightness is a system-wide setting that outlives the app,
  so it is given back at **`.inactive`** and taken down again on the return to
  `.active`, while the overlay stays up throughout. Restoring only at `.background`
  left the phone dark everywhere: `.inactive` can last as long as the user likes, may
  never reach `.background`, and is the last callback a force-quit is sure to
  deliver. Both helpers guard on `brightnessHeldDown`, or a second hold would record
  0 as the level to restore to.
- **Offered with VoiceOver on too**: its own Screen Curtain is a different switch in
  a different place and leaves the backlight on, and brightness 0 is the half that
  saves the battery. The overlay is one labeled element with an accessibility action,
  and the `TabView` under it is `.accessibilityHidden(curtainActive)`.
- **`autoScreenCurtain`** (off by default) raises the curtain the first time a
  session reaches the PC — **once per session** (`curtainAutoRaised`, reset when
  forwarding stops) so a reconnect never re-blacks a screen the user just asked to
  see, and **only from the Start tab**, since connecting from Virtual Input means the
  user is about to touch the pad.

## Virtual Input tab (`VirtualInputView.swift`, `VirtualKeyPad.swift`)

On-screen key sender, VoiceOver-first. Rebuilt small after the full PC-keyboard
layout was field-rejected as "barely functional for a blind person". The concept in
one sentence: **the pad carries the keys the iPhone's own keyboard doesn't have, the
iPhone's keyboard carries the letters, and nothing on the pad is smaller than a
thumb.**

The diagnosis, so it isn't re-litigated: the problem was never *which* keys were on
the pad but zone size and addressability. In portrait a twelve-key band gives 29 pt
zones and a 60-key keyboard 23 pt, against Apple's 44 pt minimum — a zone narrower
than a fingertip can only be found by sweeping and listening, so adding keys made
the pad slower. And "third band, fifth key" is a counting task.

### Layout

- **Three columns, always, in both orientations** (`VirtualKeys.columns`), ~116 pt
  wide. Three is what makes every zone a corner, an edge middle or the centre — a
  physical description rather than a count. Four columns grow interior zones that can
  only be described by counting along.
- **Two blocks.** The top is **one page at a time** (3×3, or 3×4 for function keys);
  the bottom two rows are the **six modifiers, permanently** (Ctrl, Shift, Alt, Win,
  AltGr, Caps Lock — `VirtualKeys.modifierBlock`). A modifier is the one thing you
  need *together with* something else, so on a page every combination would cost two
  page changes. The block gets a **fixed fraction of the height**
  (`modifierBlockFraction`), not an equal share of rows — pages have three rows or
  four, and never moving is the entire point of the modifiers.
- **Pages**: Navigation, Editing, Function keys, plus F13–F24 when
  `virtualPadExtendedFKeys` is on — an extra *page*, which costs the other pages
  nothing, where it used to be a band that shrank every zone on screen. Two-finger
  swipe left/right, or the **adjustable page control** in the toolbar (one element,
  flick up/down). The pad reports the swipe (`onPageStep`) rather than owning the
  page, so the two can't disagree.
- **The Navigation page justifies the shape**: Up on the top edge, Down on the
  bottom, Left and Right at the sides, Enter in the centre, Home/PgUp and End/PgDn in
  the corners. The position of the key *is* its meaning.
- **Rows divide their own width**, so not every row holds three keys. The Editing
  page ends in two half-width zones (Menu, Enter) since Print Screen was dropped as
  unused: a short row beats a dead corner, both halves are still bounded by a corner,
  and Enter gets the biggest target on the pad. Print Screen is deliberately no
  longer sendable from the pad.
- **Letters are deliberately not on the pad** — the iOS keyboard, with Braille Screen
  Input and dictation behind it, is already fast and already mastered. Letters go in
  the text field, and single-letter screen-reader navigation is Caps Lock on the pad
  + the letter typed once + sticky text.

### Touch and feedback

- **Direct-touch pad**: ONE accessibility element (never per-zone regions — that
  breaks explore-by-touch around it) with `.allowsDirectInteraction` +
  `[.silentOnTouch]`, giving **instant pass-through with no activation step**
  (`.requiresActivation` was field-rejected as an extra hop). Drag announces the key
  under the finger (interrupting + haptic tick), lift sends it, lift on a modifier
  toggles it, two-finger tap clears the modifiers, an extra finger mid-drag aborts.
- State is a **filled background** — half-strength tint = on, solid tint = down on
  the PC, both with a thicker tinted border — not tinted text, which was too quiet to
  find at a glance. Outlines use **`label` at 45% alpha, not `UIColor.separator`**
  (a hairline meant to divide rows of text, which left the keys looking borderless).
  A key that is *down* takes a solid `label` border, or the border vanishes into its
  own fill.
- **Haptics carry key state while dragging** (`virtualPadRichHaptics`, on by
  default): **one zone, one vibration**, and its *strength* is the state — selection
  tick = off, `.medium` = turned on, `.rigid` = down on the PC. Both alternatives
  were field-rejected: a second, delayed pulse (cancelled by the hold countdown, and
  two ticks 0.08 s apart merge into one buzz anyway), and the multi-pulse vocabulary
  itself, because pulses must be counted and told apart mid-drag while one harder
  pulse is read instantly. No row cue, deliberately. Generators are `prepare()`d in
  `touchesBegan` so a drag's first boundary isn't the sluggish one.
- **Press and hold is one stage** (`virtualPadHoldEnabled`, `virtualPadHoldDelay`,
  default 0.8 s from the touch): the key is **pressed down on the PC** until the
  finger lifts, so it repeats there — the repeat comes from the Windows agent
  (`KeyRepeater`). The earlier "latch any key on" stage went with the rebuild, since
  every modifier now has a permanent zone. A refused hold (offline) simply spends the
  press; no latch is left behind. Because the delay's meaning changed (from touch,
  not from the latch), it stores under a **new key**, `virtualPadHoldFromTouch`.
  `virtualPadHoldSpeech` makes the hold spoken as well as felt.
- **Caps Lock counts as a modifier**, not an ordinary key: on the PC it *is* one in
  the case that matters, since NVDA's desktop layout uses it as the screen-reader key
  and that only works if it wraps the key it modifies. The plain press that flips the
  lock is still reachable — hold until the key goes down, then lift.
- **The pad must live OUTSIDE any scroll container.** A scroll-view ancestor delays
  touch delivery and cancels moved touches, killing drag-to-hear/lift-to-send under
  direct touch — one build shipped it inside a Form section and the pad was dead.
- **Sizing:** the representable implements `sizeThatFits(_:uiView:context:)`
  returning the proposal; without it a `UIViewRepresentable` with an
  `intrinsicContentSize` is sized to that and **centred** inside
  `.frame(maxHeight: .infinity)` rather than filling it. Any **resize aborts the
  press** (`layoutSubviews` compares against the last laid-out size) — rotation moves
  every zone out from under a finger that is already down.

### Sending

- Picks **Windows keys directly** (`VirtualKeys.swift`) — no `ModifierMapping`;
  AltGr is just `VK_RMENU`. Which keys toggle instead of sending is a property of the
  *key* (`VirtualKeys.modifierVKs`).
- Sending rides the same connection as forwarding. If forwarding is off, Send turns
  it on and asks the user to re-trigger — deliberately no queuing of the combo.
- Text: **no modifiers → `char` unicode lines** (layout-proof, umlauts work);
  **with modifiers → US-position VKs** via `USCharVK` (shortcut semantics,
  Shift-wrapped as needed, unmappable characters skipped and announced).
- **Sticky text** (`virtualInputKeepText`, off by default) keeps the field's contents
  after Send, for single-letter screen-reader navigation on the PC (`h` for headings)
  where retyping the letter was the whole cost. Modifiers still reset on Send either
  way. Its toggle lives **in the text row**, not in Settings — it is flipped several
  times per session.
- **Live typing** (`virtualInputLiveTyping`, off by default) makes the field a
  **direct line**: each character goes out as typed, each deletion sends a plain
  Backspace, Return sends Enter, and **Send and the keep-text pin are hidden**
  because neither has anything left to do. That is the mode for *typing at* the PC.
  Modifiers keep wrapping every character and deliberately **do not reset**, so Caps
  Lock + h + h + h walks headings. Mechanics: the change is diffed against a
  **`liveMirror`** of what the PC actually received, not `onChange`'s old value —
  that is what lets a programmatic edit be invisible (`setTextSilently` moves both),
  so Clear text empties the buffer without un-typing and Send's reset doesn't replay.
  The diff is a **common prefix**: exact for append and backspace-off-the-end,
  re-types the tail on a mid-string edit. Deletions are **never wrapped in
  modifiers** — deleting is an edit, not a shortcut. `autocorrectionDisabled` stops
  being cosmetic here: a correction rewrites a word behind the diff and goes out as a
  burst of backspaces and retypes. Failures warn once per outage (`liveWarned`).

### Tab layout

Pad filling everything from the title down, over a **single control row**: text
field, dismiss keyboard, keep text, Send. No Form on this tab.

That row must be a **bottom `safeAreaInset`** (messenger input-bar pattern), not a
`VStack` sibling — as a sibling the on-screen keyboard covered
Send/keep-text/dismiss; as an inset it rides up with the keyboard and the pad gives
up the height. **Sideways on a phone the row keeps Send alone**: focusing the field
there raises the keyboard, leaving ~70 pt for the pad, so removing the field is what
makes it *impossible* to raise.

The separate "Will send" readout was **removed** — a whole row for something only
VoiceOver read. What Send will deliver is now Send's accessibility hint
(`comboDescription`), and the pad tints its toggled modifiers. Don't reintroduce it.

### Removed, and not to be reintroduced without a new reason

The full PC keyboard layout and its per-layout key names (`pcKeyboardLayout`); the
bands arrangement and its aspect-ratio rule (`virtualPadLayout`); slider gestures
(`virtualPadSliderMode` — the fallback for zones too small to hit, which is the
problem the three-column grid solves); the two-stage hold's latch delay
(`virtualPadLatchDelay`); the pad-options menu; and the **orientation pin**
(`interfaceOrientationLock`, `OrientationLock.swift`), which existed *only* because
the keyboard layout needed a landscape frame that iOS rotation lock would never hand
a VoiceOver user. Two earlier lessons still stand: send-on-adjust fires every
intermediate value (don't reintroduce anywhere), and VoiceOver double-tap activation
latency is system-inherent, which is why the direct-touch pad exists.

## Visual design (`Theme.swift`)

Reworked after "it doesn't look like it fits together, stylish" and "we don't need
that much texting in the settings screen" — one root cause: stock SwiftUI with the
explanation for every control printed next to it.

- **One accent, everywhere.** `AccentColor` in both asset catalogs (indigo `#4B3FD6`,
  `#8B82FF` in dark mode), wired in via
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `project.yml`. Everything tints
  from it with no code, including the pad's washes (`VirtualKeyPad` reads
  `UIView.tintColor`). Don't hardcode a colour; change the asset. The pad's key-down
  label picks black or white by WCAG contrast
  (`UIColor.highestContrastForeground`) for the same reason.
- **`SectionHeader(_:systemImage:)` is the only section header in the app** — SF
  Symbol, sentence case, semibold, full contrast; the grey uppercased system default
  is most of why the screens read as unstyled. Used on all three tabs *and* in every
  info sheet. It carries `.isHeader`, which is load-bearing — see the accessibility
  rules in `../CLAUDE.md` — plus `children: .ignore` so VoiceOver lands on the title,
  not the symbol's name.
- **`remKeysCard(active:)` + `cardRow()`** are the one card treatment. Exactly one
  thing uses it — the Start tab's hero — and that is the point: if everything is a
  card, nothing is.
- **Start is a hero card**: status LED (green live / amber connecting / grey idle),
  the state, the connection line, and **both** session buttons — Start/Stop, then the
  screen curtain at the same size beneath it — in one panel over a single "Windows
  PC" section. The curtain sits with Start because it is pressed just as often: it is
  how a long session begins.
- **The address field is labelled "IP address", not "Tailscale address"** (same on
  macOS). Nothing in the app requires Tailscale, and the old label read as a
  requirement.
- **Settings rows do not explain themselves.** Teaching text lives in two opt-in
  places: the info sheet, which describes the settings *as currently set*, and each
  control's VoiceOver hint, which costs a sighted user no screen space. Exactly one
  footer survives — "Shift and Control always map straight across", because four
  pickers give no hint that two modifiers are deliberately missing. Don't reintroduce
  the others; that is the change, not an oversight.
- All titles are **`.navigationBarTitleDisplayMode(.inline)`** (three tabs plus
  `InfoSheet`): the default large title costs ~50 points and overlapped the
  non-scrollable pad once the keyboard squeezed the layout.
- **Every tab has a top-right info button** (`InfoSheet.swift`) explaining the screen
  *as currently configured*. The Start tab's sheet also hosts the tips and the live
  diagnostics; dismissing it calls `CaptureView.requestReclaim()`.
- **The app icon is generated** by `scripts/make-app-icon.py` (Pillow) into both
  catalogs. Re-run it after changing the accent. iOS needs one flattened 1024 RGB
  (no alpha — App Store Connect rejects it); macOS gets the
  rounded-square-on-transparent set at every size.
