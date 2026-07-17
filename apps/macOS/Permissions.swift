import ApplicationServices
import IOKit.hid
import Foundation

/// Thin wrapper over the two TCC permissions the capture layer needs.
///
/// - **Accessibility** lets the `CGEventTap` observe and swallow events.
/// - **Input Monitoring** lets the `IOHIDManager` read raw Caps Lock reports.
///
/// Both are checked without prompting via the `has…` properties and requested
/// (which shows the system prompt / opens System Settings) via `request…`.
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility if not yet granted. Shows the standard system
    /// alert with a link to System Settings.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the Input Monitoring prompt. Only prompts once per install;
    /// afterwards the user must grant it in System Settings, so the UI should
    /// also offer a "Open System Settings" affordance.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Deep-link into the relevant System Settings pane for the "Open
    /// Settings" buttons in the permissions banner.
    static func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openSettings(anchor: "Privacy_ListenEvent")
    }

    private static func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
