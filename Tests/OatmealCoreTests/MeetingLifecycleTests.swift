import XCTest
@testable import OatmealCore

final class MeetingLifecycleTests: XCTestCase {
    func testLifecycleAcceptsCaptureFlowAndRejectsSkippingStart() throws {
        var lifecycle = MeetingLifecycle()

        XCTAssertThrowsError(try lifecycle.transition(to: .capturing))
        try lifecycle.transition(to: .starting)
        try lifecycle.transition(to: .capturing)
        try lifecycle.transition(to: .stopping)
        try lifecycle.transition(to: .finalizing)
        try lifecycle.transition(to: .completed)

        XCTAssertEqual(lifecycle.status, .completed)
    }

    func testLifecycleAllowsRecoverableFailureFromActivePhases() throws {
        var lifecycle = MeetingLifecycle()
        try lifecycle.transition(to: .starting)
        try lifecycle.transition(to: .capturing)
        try lifecycle.transition(to: .degraded)
        try lifecycle.transition(to: .stopping)
        try lifecycle.transition(to: .finalizing)
        try lifecycle.transition(to: .completed)

        XCTAssertEqual(lifecycle.status, .completed)
    }
}
