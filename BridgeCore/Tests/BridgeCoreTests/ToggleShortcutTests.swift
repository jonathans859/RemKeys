import XCTest
@testable import BridgeCore

final class ToggleShortcutTests: XCTestCase {
    func testDisplayStringUsesStableModifierOrder() {
        let shortcut = ToggleShortcut(
            keyCode: 0x67,
            modifiers: [.command, .capsLock, .shift],
            keyName: "F11"
        )
        // Order follows ShortcutModifier.displayOrder, not set iteration order.
        XCTAssertEqual(shortcut.displayString, "Caps Lock + Shift + Command + F11")
    }

    func testDisplayStringWithNoModifiers() {
        let shortcut = ToggleShortcut(keyCode: 0x60, modifiers: [], keyName: "F5")
        XCTAssertEqual(shortcut.displayString, "F5")
    }

    func testCodableRoundTrip() throws {
        let shortcut = ToggleShortcut(
            keyCode: 0x67,
            modifiers: [.capsLock, .control],
            keyName: "F11"
        )
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(ToggleShortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut)
    }

    func testSettingsPersistToggleShortcut() {
        let defaults = UserDefaults(suiteName: "ToggleShortcutTests")!
        defaults.removePersistentDomain(forName: "ToggleShortcutTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.toggleShortcut)

        settings.toggleShortcut = ToggleShortcut(keyCode: 0x67, modifiers: [.capsLock], keyName: "F11")
        // A fresh instance over the same defaults should reload it.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.toggleShortcut, settings.toggleShortcut)

        settings.toggleShortcut = nil
        let clearedReload = AppSettings(defaults: defaults)
        XCTAssertNil(clearedReload.toggleShortcut)
    }
}
