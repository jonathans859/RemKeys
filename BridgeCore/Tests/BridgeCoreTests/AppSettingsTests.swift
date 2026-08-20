import XCTest
@testable import BridgeCore

final class AppSettingsTests: XCTestCase {
    func testVirtualPadSettingsDefaultOffAndPersist() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests")!
        defaults.removePersistentDomain(forName: "AppSettingsTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.virtualPadExtendedFKeys)
        XCTAssertFalse(settings.virtualInputKeepText)
        XCTAssertFalse(settings.virtualInputLiveTyping)
        XCTAssertTrue(settings.virtualPadRichHaptics)

        settings.virtualPadExtendedFKeys = true
        settings.virtualInputKeepText = true
        settings.virtualInputLiveTyping = true
        settings.virtualPadRichHaptics = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.virtualPadExtendedFKeys)
        XCTAssertTrue(reloaded.virtualInputKeepText)
        XCTAssertTrue(reloaded.virtualInputLiveTyping)
        XCTAssertFalse(reloaded.virtualPadRichHaptics)
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

    /// The key pad's hold gesture: on by default at 0.8 s, and a stored
    /// `false`/custom timing has to survive a reload — same
    /// `bool(forKey:)`/`double(forKey:)` trap as the function-key row.
    func testHoldSettingsDefaultOnAndPersist() {
        let defaults = UserDefaults(suiteName: "AppSettingsHoldTests")!
        defaults.removePersistentDomain(forName: "AppSettingsHoldTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.virtualPadHoldEnabled)
        XCTAssertTrue(settings.virtualPadHoldSpeech)
        XCTAssertEqual(settings.virtualPadHoldDelay, 0.8, accuracy: 0.0001)

        settings.virtualPadHoldEnabled = false
        settings.virtualPadHoldSpeech = false
        settings.virtualPadHoldDelay = 1.2

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.virtualPadHoldEnabled)
        XCTAssertFalse(reloaded.virtualPadHoldSpeech)
        XCTAssertEqual(reloaded.virtualPadHoldDelay, 1.2, accuracy: 0.0001)
    }

    /// A zero or wild delay would make the pad either fire instantly or never,
    /// so both the setter and the loader clamp into the published range.
    func testHoldDelayIsClamped() {
        let defaults = UserDefaults(suiteName: "AppSettingsHoldClampTests")!
        defaults.removePersistentDomain(forName: "AppSettingsHoldClampTests")

        let settings = AppSettings(defaults: defaults)
        settings.virtualPadHoldDelay = 0
        XCTAssertEqual(settings.virtualPadHoldDelay, AppSettings.holdDelayRange.lowerBound)
        settings.virtualPadHoldDelay = 99
        XCTAssertEqual(settings.virtualPadHoldDelay, AppSettings.holdDelayRange.upperBound)

        // A value written straight into defaults (an older build, a synced
        // preference) is clamped on the way in, not trusted.
        defaults.set(0.0, forKey: "virtualPadHoldFromTouch")
        XCTAssertEqual(
            AppSettings(defaults: defaults).virtualPadHoldDelay,
            AppSettings.holdDelayRange.lowerBound
        )
    }

    /// The hold delay moved to a new storage key with the 2026-08-20 rebuild,
    /// because the old one counted from the moment a key *latched* rather than
    /// from the touch. An install carrying the old number must get the new
    /// default, not inherit a value that meant something else.
    func testOldTwoStageHoldDelayIsNotInherited() {
        let defaults = UserDefaults(suiteName: "AppSettingsHoldMigrationTests")!
        defaults.removePersistentDomain(forName: "AppSettingsHoldMigrationTests")
        defaults.set(0.4, forKey: "virtualPadHoldDelay")
        defaults.set(1.5, forKey: "virtualPadLatchDelay")

        XCTAssertEqual(
            AppSettings(defaults: defaults).virtualPadHoldDelay,
            0.8,
            accuracy: 0.0001
        )
    }
}
