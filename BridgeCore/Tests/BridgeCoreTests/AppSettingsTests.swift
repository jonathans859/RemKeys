import XCTest
@testable import BridgeCore

final class AppSettingsTests: XCTestCase {
    func testVirtualPadSettingsDefaultOffAndPersist() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests")!
        defaults.removePersistentDomain(forName: "AppSettingsTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.virtualPadSliderMode)
        XCTAssertFalse(settings.virtualPadExtendedFKeys)
        XCTAssertFalse(settings.virtualInputKeepText)

        settings.virtualPadSliderMode = true
        settings.virtualPadExtendedFKeys = true
        settings.virtualInputKeepText = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.virtualPadSliderMode)
        XCTAssertTrue(reloaded.virtualPadExtendedFKeys)
        XCTAssertTrue(reloaded.virtualInputKeepText)
    }

    /// The pad's arrangement: the keyboard layout is the landscape default, so
    /// an existing install that never touched the setting gets it by turning
    /// the device — and a user who picks plain bands has to keep them, which
    /// only works if the stored non-default value survives a reload.
    func testPadLayoutDefaultsToKeyboardInLandscapeAndPersists() {
        let defaults = UserDefaults(suiteName: "AppSettingsPadLayoutTests")!
        defaults.removePersistentDomain(forName: "AppSettingsPadLayoutTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.virtualPadLayout, .keyboardInLandscape)
        XCTAssertEqual(settings.pcKeyboardLayout, .us)
        XCTAssertTrue(settings.virtualPadRichHaptics)

        settings.virtualPadLayout = .bands
        settings.pcKeyboardLayout = .german
        settings.virtualPadRichHaptics = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.virtualPadLayout, .bands)
        XCTAssertEqual(reloaded.pcKeyboardLayout, .german)
        XCTAssertFalse(reloaded.virtualPadRichHaptics)
    }

    /// A raw value that no longer exists (or never did) must fall back to the
    /// default rather than leave the pad with no arrangement at all.
    func testUnknownStoredLayoutFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "AppSettingsPadLayoutJunkTests")!
        defaults.removePersistentDomain(forName: "AppSettingsPadLayoutJunkTests")
        defaults.set("someFutureLayout", forKey: "virtualPadLayout")
        defaults.set("dvorak", forKey: "pcKeyboardLayout")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.virtualPadLayout, .keyboardInLandscape)
        XCTAssertEqual(settings.pcKeyboardLayout, .us)
    }

    /// This one defaults to *true*, which `bool(forKey:)` can't express — so a
    /// stored `false` has to survive a reload rather than falling back to the
    /// default.
    func testFunctionKeyRowDefaultsOnAndPersistsOff() {
        let defaults = UserDefaults(suiteName: "AppSettingsFKeyTests")!
        defaults.removePersistentDomain(forName: "AppSettingsFKeyTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.forwardFunctionKeyRow)

        settings.forwardFunctionKeyRow = false
        XCTAssertFalse(AppSettings(defaults: defaults).forwardFunctionKeyRow)
    }

    /// The key pad's hold gesture: on by default with 0.6 s stages, and a
    /// stored `false`/custom timing has to survive a reload — same
    /// `bool(forKey:)`/`double(forKey:)` trap as the function-key row.
    func testHoldSettingsDefaultOnAndPersist() {
        let defaults = UserDefaults(suiteName: "AppSettingsHoldTests")!
        defaults.removePersistentDomain(forName: "AppSettingsHoldTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.virtualPadHoldEnabled)
        XCTAssertTrue(settings.virtualPadHoldSpeech)
        XCTAssertEqual(settings.virtualPadLatchDelay, 0.6, accuracy: 0.0001)
        XCTAssertEqual(settings.virtualPadHoldDelay, 0.6, accuracy: 0.0001)

        settings.virtualPadHoldEnabled = false
        settings.virtualPadHoldSpeech = false
        settings.virtualPadLatchDelay = 1.2
        settings.virtualPadHoldDelay = 0.4

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.virtualPadHoldEnabled)
        XCTAssertFalse(reloaded.virtualPadHoldSpeech)
        XCTAssertEqual(reloaded.virtualPadLatchDelay, 1.2, accuracy: 0.0001)
        XCTAssertEqual(reloaded.virtualPadHoldDelay, 0.4, accuracy: 0.0001)
    }

    /// A zero or wild delay would make the pad either fire instantly or never,
    /// so both the setter and the loader clamp into the published ranges.
    func testHoldDelaysAreClamped() {
        let defaults = UserDefaults(suiteName: "AppSettingsHoldClampTests")!
        defaults.removePersistentDomain(forName: "AppSettingsHoldClampTests")

        let settings = AppSettings(defaults: defaults)
        settings.virtualPadLatchDelay = 0
        settings.virtualPadHoldDelay = 99
        XCTAssertEqual(settings.virtualPadLatchDelay, AppSettings.latchDelayRange.lowerBound)
        XCTAssertEqual(settings.virtualPadHoldDelay, AppSettings.holdDelayRange.upperBound)

        // A value written straight into defaults (an older build, a synced
        // preference) is clamped on the way in, not trusted.
        defaults.set(0.0, forKey: "virtualPadLatchDelay")
        XCTAssertEqual(
            AppSettings(defaults: defaults).virtualPadLatchDelay,
            AppSettings.latchDelayRange.lowerBound
        )
    }
}
