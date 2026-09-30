import SwiftUI
import AppKit
import BridgeCore

/// The app's window contents: status, the forwarding toggle, connection target,
/// and mappings. Hosted in a real `NSWindow` by `AppDelegate` (not a popover —
/// a popover dismisses on the next click elsewhere and never shows up in
/// ⌘-Tab), so a VoiceOver user can reach every control by tabbing and leave the
/// window open. Every state has a text value, not just the border/icon.
struct MenuContentView: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.capture.state != .running {
                permissionsBanner
                Divider()
            }

            toggleButton
            Divider()
            connectionControls
            Divider()
            mappingControls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RemKeys")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(model.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RemKeys")
        .accessibilityValue(model.statusLine)
    }

    private var toggleButton: some View {
        Button {
            model.toggleForwarding()
        } label: {
            HStack {
                Image(systemName: model.isForwarding ? "stop.fill" : "play.fill")
                Text(model.isForwarding ? "Stop forwarding" : "Start forwarding")
                Spacer()
                if let shortcut = settings.toggleShortcut {
                    Text(shortcut.displayString).foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .keyboardShortcut("f", modifiers: [.command])
        .accessibilityLabel(model.isForwarding ? "Stop forwarding" : "Start forwarding")
        .accessibilityHint(toggleButtonHint)
    }

    private var toggleButtonHint: String {
        let base = model.isForwarding
            ? "Stops sending keystrokes to the Windows PC."
            : "Connects and starts sending keystrokes to the Windows PC."
        if let shortcut = settings.toggleShortcut {
            return base + " Also \(shortcut.displayString)."
        }
        return base
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows PC").font(.caption).foregroundStyle(.secondary)
            TextField("IP address", text: Binding(
                get: { settings.targetHost },
                set: { settings.targetHost = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("IP address")
            .accessibilityHint("The Windows PC's address: its Tailscale IP, or a local one if both machines are on the same network")

            TextField("Port", value: Binding(
                get: { settings.targetPort },
                set: { settings.targetPort = $0 }
            ), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Port")
            .accessibilityHint("Must match the port in the Windows agent configuration")
        }
    }

    private var mappingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modifier mapping").font(.caption).foregroundStyle(.secondary)
            mappingPicker("Left Option", Binding(
                get: { settings.leftOptionMapping },
                set: { settings.leftOptionMapping = $0 }))
            mappingPicker("Right Option", Binding(
                get: { settings.rightOptionMapping },
                set: { settings.rightOptionMapping = $0 }))
            mappingPicker("Left Command", Binding(
                get: { settings.leftCommandMapping },
                set: { settings.leftCommandMapping = $0 }))
            mappingPicker("Right Command", Binding(
                get: { settings.rightCommandMapping },
                set: { settings.rightCommandMapping = $0 }))

            Divider()
            functionKeyRowControl

            Divider()
            toggleShortcutControl

            Divider()
            pointerControl
        }
    }

    /// macOS's own fn-row behaviour (brightness, volume, Mission Control…)
    /// happens below the event tap, so without this remap the top row only
    /// reaches the PC when fn is held. See `FunctionKeyRow`.
    private var functionKeyRowControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Function keys").font(.caption).foregroundStyle(.secondary)
            Toggle("Send F1–F12 without holding fn", isOn: $model.forwardFunctionKeyRow)
                .accessibilityHint(
                    "While forwarding is on, the top row sends F1 to F12 to the Windows PC "
                    + "instead of running the Mac's brightness, volume and Mission Control "
                    + "functions. The Mac gets those keys back as soon as forwarding stops."
                )
        }
    }

    /// Records an optional global shortcut for toggling forwarding. Clicking the
    /// field arms the recorder; the next chord pressed becomes the shortcut.
    private var toggleShortcutControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Toggle shortcut").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    if model.isRecordingShortcut {
                        model.cancelRecordingShortcut()
                    } else {
                        model.recordToggleShortcut()
                    }
                } label: {
                    Text(shortcutFieldText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Toggle shortcut")
                .accessibilityValue(settings.toggleShortcut?.displayString ?? "None")
                .accessibilityHint(model.isRecordingShortcut
                    ? "Recording. Press the keys you want, or Escape to cancel."
                    : "Records a keyboard shortcut that turns forwarding on and off from any app.")

                if settings.toggleShortcut != nil, !model.isRecordingShortcut {
                    Button("Clear") { model.clearToggleShortcut() }
                        .accessibilityHint("Removes the shortcut; the button still toggles forwarding.")
                }
            }
        }
    }

    /// Ignoring the trackpad needs a toggle shortcut: forwarding swallows every
    /// key, so without one the pointer is the only way to stop it. The reason
    /// is shown as visible text, not only in a hint, so it reads the same to
    /// everyone.
    private var pointerControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trackpad").font(.caption).foregroundStyle(.secondary)
            Toggle("Ignore trackpad and mouse while forwarding", isOn: $model.ignorePointerWhileForwarding)
                .disabled(settings.toggleShortcut == nil)
                .accessibilityHint(
                    "While forwarding is on, clicks, scrolling, gestures and pointer movement "
                    + "are dropped so they can't act on this Mac. Nothing is sent to the "
                    + "Windows PC. The toggle shortcut is then the only way to stop forwarding."
                )
            if settings.toggleShortcut == nil {
                Text("Record a toggle shortcut first. Without one, the trackpad is the only way to stop forwarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutFieldText: String {
        if model.isRecordingShortcut { return "Press keys…  (Esc to cancel)" }
        if let shortcut = settings.toggleShortcut { return shortcut.displayString }
        return "None — click to record"
    }

    private func mappingPicker(_ title: String, _ selection: Binding<ModifierMapping>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierMapping.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityHint("Where the \(title) key lands on the Windows PC")
    }

    private var permissionsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(bannerText, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(bannerText)
            HStack {
                Button("Open System Settings") { openRelevantSettings() }
                Button("Recheck") { model.recheck() }
            }
        }
    }

    private var footer: some View {
        HStack {
            updateButton
            Spacer()
            Button("Quit RemKeys") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        }
    }

    /// Says what it will do: once a scheduled check has found an update, the
    /// label names it, so the button itself carries the state rather than a
    /// badge next to it. One visible string, no separate accessibility label.
    private var updateButton: some View {
        Button(model.availableUpdate.map { "Install update (build \($0))…" } ?? "Check for updates…") {
            model.checkForUpdates()
        }
        .accessibilityHint(model.availableUpdate == nil
            ? "Looks for a newer version of RemKeys."
            : "Opens the update. Installing restarts RemKeys, which ends forwarding.")
    }

    // MARK: Permission helpers

    private var bannerText: String {
        switch model.capture.state {
        case .needsAccessibility:
            return "Accessibility permission needed to capture keys."
        case .needsInputMonitoring:
            return "Input Monitoring permission needed for Caps Lock."
        default:
            return "Capture is not running."
        }
    }

    private func openRelevantSettings() {
        switch model.capture.state {
        case .needsInputMonitoring:
            Permissions.openInputMonitoringSettings()
        default:
            Permissions.openAccessibilitySettings()
        }
    }
}
