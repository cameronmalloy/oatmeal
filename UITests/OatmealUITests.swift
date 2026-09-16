import XCTest

final class OatmealUITests: XCTestCase {
    func testLaunchShowsHistoryAndPrimaryAction() {
        let app = XCUIApplication(bundleIdentifier: "com.cameronmalloy.oatmeal")
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["meeting-history"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["start-meeting"].exists ||
            app.descendants(matching: .any)["model-setup"].exists
        )
    }

    func testBacklogStatusIsInlineAndStopRemainsUsable() {
        let app = XCUIApplication(bundleIdentifier: "com.cameronmalloy.oatmeal")
        app.launchArguments = ["--ui-testing", "--ui-testing-backlog"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["transcription-backlog-status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Oatmeal"].exists)
        let stop = app.buttons["stop-meeting"]
        XCTAssertTrue(stop.isEnabled)
    }
}
