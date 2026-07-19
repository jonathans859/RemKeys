import XCTest
@testable import BridgeCore

final class AppSettingsTests: XCTestCase {
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
