import SwiftUI
import AppKit
import BridgeCore

/// The menu-bar popover: status, the forwarding toggle, connection target, and
/// modifier mappings. Kept in one window-style popover so a VoiceOver user can
/// reach every control by tabbing, and every state has a text value (not just
/// the border/icon).
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
            Text("KeyBridge")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(model.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("KeyBridge")
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
            TextField("Tailscale address", text: Binding(
                get: { settings.targetHost },
                set: { settings.targetHost = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Tailscale address")
            .accessibilityHint("The target computer's Tailscale IP address")

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
            mappingPicker("Command", Binding(
                get: { settings.commandMapping },
                set: { settings.commandMapping = $0 }))

            Divider()
            toggleShortcutControl
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
        Button("Quit KeyBridge") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
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
