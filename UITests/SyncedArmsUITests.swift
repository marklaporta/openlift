import XCTest

final class SyncedArmsUITests: OpenLiftUITestCase {
    func testSyncedArmsButtonBlocksDraftAndPersistsCold() throws {
        let app = legacyAdministrationApp()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launchEnvironment["OPENLIFT_ROW_PAIRING_UI"] = "1"
        app.launchEnvironment["OPENLIFT_BALANCED_UI"] = "1"
        app.launchEnvironment["OPENLIFT_QUAD_PHASE_UI"] = "1"
        app.launchEnvironment["OPENLIFT_SYNCED_ARMS_UI"] = "1"
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.applySyncedArms"]
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.syncedArmsSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Arms synchronized"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        let unexpectedAlert = app.alerts["Workout Needs Attention"]
        XCTAssertFalse(unexpectedAlert.exists, unexpectedAlert.debugDescription)
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v8"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let persisted = app.descendants(matching: .any).matching(identifier: "cycle.syncedArmsSuccess").firstMatch
        scrollToElement(persisted, in: app)
        XCTAssertTrue(persisted.exists)
    }
    func testHammerBlankRowsAndOverheadPerSideNote() throws {
        let app = legacyAdministrationApp()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        for key in ["OPENLIFT_CHEST_BACK_UI", "OPENLIFT_ROW_PAIRING_UI", "OPENLIFT_BALANCED_UI", "OPENLIFT_QUAD_PHASE_UI", "OPENLIFT_SYNCED_ARMS_UI", "OPENLIFT_SYNCED_ARMS_ROWS_UI"] { app.launchEnvironment[key] = "1" }
        app.launch()
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        let hammer = app.textFields["fixed.weight.Seated DB Hammer Curl.1"]
        scrollToElement(hammer, in: app)
        XCTAssertEqual(hammer.value as? String, "Weight")
        XCTAssertEqual(app.textFields["fixed.reps.Seated DB Hammer Curl.1"].value as? String, "Reps")
        XCTAssertTrue(app.textFields["fixed.weight.Seated DB Hammer Curl.2"].exists)
        XCTAssertFalse(app.textFields["fixed.weight.Seated DB Hammer Curl.3"].exists)
        let note = app.staticTexts["workout.singleArmOverheadLoggingNote"]
        scrollToElement(note, in: app)
        XCTAssertTrue(note.exists)
    }

}
