import XCTest

final class ProgramImportUITests: OpenLiftUITestCase {
    func testFileImportPreviewApplyAndColdLaunch() throws {
        let app = launchFixture()
        let updates = app.buttons["cycle.programUpdates"]
        scrollToElement(updates, in: app); updates.tap()
        importFixture(in: app)
        let apply = app.buttons["program.apply"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists, app.debugDescription)
        XCTAssertTrue(apply.isEnabled, app.debugDescription)
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "Imported program preview"; preview.lifetime = .keepAlways; add(preview)
        apply.tap()
        XCTAssertTrue(app.descendants(matching: .any)["program.success"].waitForExistence(timeout: 5), app.debugDescription)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v9"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Flat DB Press.1"]
        scrollToElement(weight, in: app); XCTAssertTrue(weight.exists)
        weight.tap(); weight.typeText("45")
        let reps = app.textFields["fixed.reps.Flat DB Press.1"]; reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.Flat DB Press.1"].tap()
        let complete = app.buttons["Complete Cluster 1"]; scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]; scrollToElement(finish, in: app); finish.tap()
        XCTAssertFalse(app.alerts["Workout Needs Attention"].exists)
    }
    func testFilePreviewRetainsDraftAndDisablesApply() throws {
        let app = launchFixture()
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        app.tabBars.buttons["Cycle"].tap()
        let updates = app.buttons["cycle.programUpdates"]
        scrollToElement(updates, in: app); updates.tap()
        importFixture(in: app)
        let blocked = app.staticTexts["program.draftBlocked"]
        scrollToElement(blocked, in: app)
        XCTAssertTrue(blocked.exists)
        XCTAssertFalse(app.buttons["program.apply"].isEnabled)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v8"].firstMatch.waitForExistence(timeout: 5))
    }
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        for key in ["OPENLIFT_CHEST_BACK_UI", "OPENLIFT_ROW_PAIRING_UI", "OPENLIFT_BALANCED_UI", "OPENLIFT_QUAD_PHASE_UI", "OPENLIFT_SYNCED_ARMS_UI", "OPENLIFT_PROGRAM_IMPORT_UI"] { app.launchEnvironment[key] = "1" }
        app.launch()
        return app
    }
    private func importFixture(in app: XCUIApplication) {
        app.buttons["program.import"].tap()
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3) { browse.tap() }
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone")).firstMatch
        if local.waitForExistence(timeout: 3) { local.tap() }
        let folder = app.cells["OpenLift, Container"]
        if folder.waitForExistence(timeout: 3) { folder.tap() }
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "OpenLift-Test-Revision")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
    }

}
