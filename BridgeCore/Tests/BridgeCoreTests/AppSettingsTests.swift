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
}
