import AppKit

// AppKit entry point, not a SwiftUI `App`. A SwiftUI `MenuBarExtra` can only
// ever show a *popover*, which dismisses on the next click elsewhere and can
// never appear in ⌘-Tab. Owning the status item and the window ourselves lets a
// click open a real, persistent window and flip the activation policy while
// it's up. `AppDelegate` does all of it.
// Top-level code in `main.swift` is *not* main-actor isolated (Swift 5 language
// mode), while `AppDelegate` is — and this code does run on the main thread, so
// say so explicitly. `delegate` is a global on purpose:
// `NSApplication.delegate` is a *weak* reference, so a local would be released
// before the first callback ever arrives.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = delegate
    // LSUIElement already starts us as an accessory; set it explicitly so the
    // launch state matches what `AppDelegate` toggles back to.
    application.setActivationPolicy(.accessory)
    application.run()
}
