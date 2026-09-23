import XCTest

final class GripperModelUITests: OpenLiftUITestCase {
    func testSelectGripperModelsAndSaveHistory() {
        let app = launchLegacyAdministrationApp()
        app.tabBars.buttons["Log"].tap()
        let exercisePicker = app.buttons["log.exercisePicker"].firstMatch
        XCTAssertTrue(exercisePicker.waitForExistence(timeout: 5))
        exercisePicker.tap()
        let gripper = app.buttons["Captain of Crush"].firstMatch
        scrollToElement(gripper, in: app)
        gripper.tap()
        let picker = app.buttons["log.model.1"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Weight"].firstMatch.exists)
        for label in ["G", "T", "1"] {
            picker.tap()
            app.buttons[label].firstMatch.tap()
            XCTAssertEqual(picker.value as? String, label)
        }
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "CoC model 1 selected without pounds"; receipt.lifetime = .keepAlways; add(receipt)
        let reps = app.textFields["Reps"].firstMatch
        reps.tap(); reps.typeText("6")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let save = app.buttons["Save to History"].firstMatch
        scrollToElement(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["Saved to History."].waitForExistence(timeout: 20))
        app.tabBars.buttons["History"].tap()
        app.buttons["Workouts"].tap()
        let workout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Off-Schedule")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 10)); workout.tap()
        XCTAssertTrue(app.staticTexts["Model 1 x 6"].waitForExistence(timeout: 5))
    }
    func testGripperStorageMigrationButtonDraftGuardAndColdLaunch() throws {
        let app = legacyAdministrationApp()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launchEnvironment["OPENLIFT_CS_DB_ROW_UI"] = "1"
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.migrateGripperModels"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(apply.isEnabled)
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Flat DB Press.1"]
        scrollToElement(weight, in: app)
        weight.tap(); weight.typeText("45")
        let reps = app.textFields["fixed.reps.Flat DB Press.1"]
        reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.Flat DB Press.1"].tap()
        let complete = app.buttons["Complete Cluster 1"]
        scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        app.tabBars.buttons["Cycle"].tap()
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        let success = app.descendants(matching: .any).matching(identifier: "cycle.gripperModelsSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Gripper model history migration succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v4"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        XCTAssertTrue(app.buttons["cycle.consolidateCSDBRow"].exists)
        XCTAssertTrue(app.buttons["cycle.reviseChestBack"].exists)
    }
}
