import AppKit
import SwiftUI
import BridgeCore

/// Owns the menu-bar item and the app's single window, and installs the capture
/// tap at launch (a menu-bar-only app never gets a window `onAppear`, so
/// launch-time setup lives here).
///
/// **Window, not popover.** Clicking the menu-bar icon opens a normal window
/// that stays open until it is closed or the app is hidden — it does not
/// dismiss when focus moves elsewhere. While that window is up the app runs as
/// `.regular`, which is what puts RemKeys in ⌘-Tab (and, unavoidably, in the
/// Dock — the two come together). Closing or hiding it drops back to
/// `.accessory`, i.e. menu-bar only.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel { AppModel.shared }

    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        // The status item is the only always-visible surface, so it has to
        // track state (icon + VoiceOver value + tooltip) on every change.
        model.menuStateDidChange = { [weak self] in self?.refreshStatusItem() }
        model.start()
        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The fn-row remap is system state that outlives this process.
        model.shutdown()
    }

    /// Hiding a menu-bar app means "put it away": the window goes with it, and
    /// we leave ⌘-Tab.
    func applicationDidHide(_ notification: Notification) {
        window?.orderOut(nil)
        returnToMenuBarOnly()
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.setAccessibilityLabel("RemKeys")
        statusItem = item
    }

    /// State is never carried by the icon alone: VoiceOver reads the label plus
    /// the status line as the item's value, and the tooltip repeats it.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = model.isForwarding ? "keyboard.fill" : "keyboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "RemKeys")
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityValue(model.statusLine)
        button.toolTip = "RemKeys — \(model.statusLine)"
    }

    @objc private func statusItemClicked() {
        if let window, window.isVisible {
            window.orderOut(nil)          // no `windowWillClose` from orderOut
            returnToMenuBarOnly()
        } else {
            showWindow()
        }
    }

    // MARK: Window

    private func showWindow() {
        let window = self.window ?? makeWindow()
        NSApp.setActivationPolicy(.regular)   // ⌘-Tab + Dock while we're open
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: MenuContentView(model: model)
        ))
        window.title = "RemKeys"
        // Fixed size: the SwiftUI content defines its own width.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.delegate = self
        window.isReleasedWhenClosed = false    // reused across open/close
        window.center()
        window.setFrameAutosaveName("RemKeysMainWindow")
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        returnToMenuBarOnly()
    }

    private func returnToMenuBarOnly() {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Main menu

    /// Built by hand — there is no nib, and an `.regular` app with no main menu
    /// would leave the window without Close/Hide/Quit (and a screen-reader user
    /// without the menu bar they expect).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide RemKeys",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit RemKeys",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
