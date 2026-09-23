import XCTest

final class MovementHistoryUITests: OpenLiftUITestCase {
    func testMovementDefaultSearchProgressionAndWorkoutToggle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING"]
        app.launchEnvironment["OPENLIFT_MOVEMENT_HISTORY_UI"] = "1"
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["Movements"].isSelected)
        let press = app.buttons["history.movement.Flat DB Press"]
        XCTAssertTrue(press.waitForExistence(timeout: 5))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Movement-first history"; list.lifetime = .keepAlways; add(list)
        let search = app.searchFields["Search exercises"]
        XCTAssertTrue(search.isHittable)
        search.tap(); search.typeText("dumbbell press")
        XCTAssertTrue(press.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["history.movement.Incline Curl"].exists)
        press.tap()
        XCTAssertTrue(app.navigationBars["Movement History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 workouts · 12 sets"].exists)
        XCTAssertFalse(app.buttons["Weight"].exists)
        XCTAssertFalse(app.buttons["Reps"].exists)
        XCTAssertTrue(app.staticTexts["history.index.summary"].exists)
        XCTAssertTrue(app.staticTexts["Set 1"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Load change"].exists)
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Movement progression"; detail.lifetime = .keepAlways; add(detail)
        scrollToElement(app.staticTexts["50 × 12"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["50 × 12"].firstMatch.exists)
        scrollToElement(app.buttons["history.setup"], in: app, toward: .top)
        app.buttons["history.setup"].tap()
        app.buttons["All setups"].tap()
        XCTAssertTrue(app.staticTexts["history.index.summary"].exists, "All setups retains the segmented index chart")
        let allSetups = XCTAttachment(screenshot: app.screenshot()); allSetups.name = "Index across setup segments"; allSetups.lifetime = .keepAlways; add(allSetups)
        scrollToElement(app.staticTexts["42.5 × 15"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["42.5 × 15"].firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()
        // Search remains scoped to the same movement when changing history mode.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.buttons["Workouts"].tap()
        let workout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Strength Training")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 5)); workout.tap()
        XCTAssertTrue(app.navigationBars["Session Detail"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Movements"].tap()
        XCTAssertTrue(press.waitForExistence(timeout: 5))
    }

    func testEmptyMovementHistory() {
        let app = launchApp()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No Movement History"].waitForExistence(timeout: 5))
        app.buttons["Workouts"].tap()
        XCTAssertTrue(app.staticTexts["No Completed Sessions"].exists)
    }
}
