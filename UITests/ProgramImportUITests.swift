import XCTest

/// Import activation is now exercised through the actual private-file/URL bridge
/// by scripts/test-program-agent.py. No user-facing administration route remains.
final class ProgramImportUITests: OpenLiftUITestCase {
    func testOnlyLoggingWorkoutAndHistoryTabsRemain() throws {
        let app = launchApp(["OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT"])
        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(app.tabBars.buttons["Log"].exists)
        XCTAssertTrue(app.tabBars.buttons["History"].exists)
        XCTAssertFalse(app.tabBars.buttons["Cycle"].exists)
        XCTAssertFalse(app.buttons["cycle.programUpdates"].exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(app.buttons["program.import"].exists)
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workout with three tabs and no administration menu"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

/// simctl routes links through SpringBoard, unlike CoreDevice's bundle-targeted
/// payload delivery. This opt-in harness accepts only that OS-owned link dialog;
/// the external transport gate verifies the actual private receipts/store.
final class ProgramBridgeTransportUITests: XCTestCase {
    func testAcceptSimulatorLinkDialogs() throws {
        guard ProcessInfo.processInfo.environment["OPENLIFT_BRIDGE_TRANSPORT_UI"] == "1" else {
            throw XCTSkip("Only scripts/test-program-agent.py's disposable transport gate uses this harness")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(75)
        let resultPath = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENLIFT_BRIDGE_RESULT_PATH"])
        while Date() < deadline && !FileManager.default.fileExists(atPath: resultPath) {
            let button = springboard.buttons["Open"].firstMatch
            if button.waitForExistence(timeout: 2) {
                button.tap()
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultPath), "External receipt/store transport gate did not complete")
    }
}
