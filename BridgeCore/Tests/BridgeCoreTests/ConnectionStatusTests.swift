import XCTest
@testable import BridgeCore

final class ConnectionStatusTests: XCTestCase {
    typealias Status = BridgeClient.ConnectionStatus

    func testRetryFailuresAreNotReannounced() {
        // Automatic retries against an unreachable PC: a new error text each
        // time must not be spoken again.
        XCTAssertFalse(Status.failed("Host is down").isWorthAnnouncing(after: .failed("Network connection lost")))
        XCTAssertFalse(Status.failed("Host is down").isWorthAnnouncing(after: .failed("Operation timed out")))
    }

    func testTransitionsIntoAndOutOfFailureAreAnnounced() {
        XCTAssertTrue(Status.failed("Network connection lost").isWorthAnnouncing(after: .connected))
        XCTAssertTrue(Status.failed("Host is down").isWorthAnnouncing(after: .connecting))
        XCTAssertTrue(Status.connected.isWorthAnnouncing(after: .failed("Host is down")))
        XCTAssertTrue(Status.connecting.isWorthAnnouncing(after: .idle))
        XCTAssertTrue(Status.idle.isWorthAnnouncing(after: .failed("Host is down")))
    }
}
