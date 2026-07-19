import XCTest
@testable import BridgeCore

final class AppSettingsTests: XCTestCase {
    func testVirtualRowSendsModifiersDefaultsTrueAndPersists() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests")!
        defaults.removePersistentDomain(forName: "AppSettingsTests")

        // Default is true — bool(forKey:) alone would have flipped this.
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.virtualRowSendsModifiers)

        settings.virtualRowSendsModifiers = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.virtualRowSendsModifiers)

        settings.virtualRowSendsModifiers = true
        let restoredReload = AppSettings(defaults: defaults)
        XCTAssertTrue(restoredReload.virtualRowSendsModifiers)
    }

    func testVirtualPadSettingsDefaultOffAndPersist() {
        let defaults = UserDefaults(suiteName: "AppSettingsTests")!
        defaults.removePersistentDomain(forName: "AppSettingsTests")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.virtualPadSliderMode)
        XCTAssertFalse(settings.virtualPadExtendedFKeys)

        settings.virtualPadSliderMode = true
        settings.virtualPadExtendedFKeys = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.virtualPadSliderMode)
        XCTAssertTrue(reloaded.virtualPadExtendedFKeys)
    }
}
