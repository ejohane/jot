import Foundation
import XCTest
@testable import Jot

final class CaptureLaunchPolicyTests: XCTestCase {
    func testFirstLaunchAndShortAbsenceKeepCurrentEntry() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(CaptureLaunchPolicy.startsNewEntry(lastDeparture: nil, now: now))
        XCTAssertFalse(CaptureLaunchPolicy.startsNewEntry(lastDeparture: now.addingTimeInterval(-299), now: now))
    }

    func testFiveMinutesAndLongerStartFreshEntry() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(CaptureLaunchPolicy.startsNewEntry(lastDeparture: now.addingTimeInterval(-300), now: now))
        XCTAssertTrue(CaptureLaunchPolicy.startsNewEntry(lastDeparture: now.addingTimeInterval(-900), now: now))
    }

    func testClockMovingBackDoesNotDiscardCurrentEntry() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(CaptureLaunchPolicy.startsNewEntry(lastDeparture: now.addingTimeInterval(20), now: now))
    }
}
