import XCTest

final class ChestBackRevisionUITests: OpenLiftUITestCase {
    private func launchChestBackFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launch()
        return app
    }
    func testRecoveryButtonBlocksDraftThenPersistsThroughColdLaunch() throws {
        let app = launchChestBackFixture()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.reviseChestBack"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["cycle.chestBackDraftBlocker"].exists)
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.chestBackSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Third side-delt activation succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v6"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Super ROM DB Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated DB Shrugs"))
    }

    func testCSDBRowConsolidationButtonAndColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launchEnvironment["OPENLIFT_CS_DB_ROW_UI"] = "1"
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.consolidateCSDBRow"]
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.csDBRowSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "CS DB Row consolidation succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v4"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Super ROM DB Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated DB Shrugs"))
        app.tabBars.buttons["Log"].tap()
        let picker = app.buttons["log.exercisePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        let row = app.buttons["CS DB Row"].firstMatch
        scrollToElement(row, in: app)
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.buttons["Helms Row"].exists)
        XCTAssertFalse(app.buttons["CS Row"].exists)
        XCTAssertFalse(app.buttons["Chest-Supported Dumbbell Row"].exists)
        row.tap()
        XCTAssertTrue(picker.label.contains("CS DB Row") || (picker.value as? String)?.contains("CS DB Row") == true)

    }

    func testRowPairingButtonAndColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launchEnvironment["OPENLIFT_ROW_PAIRING_UI"] = "1"
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.pairChestBackRows"]
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.rowPairingSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Row pairing succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v6"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let persisted = app.descendants(matching: .any).matching(identifier: "cycle.rowPairingSuccess").firstMatch
        scrollToElement(persisted, in: app)
        XCTAssertTrue(persisted.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextFirst = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-1").firstMatch
        scrollToElement(nextFirst, in: app)
        XCTAssertTrue(nextFirst.label.contains("Next: B"))
        XCTAssertTrue(nextFirst.label.contains("Seated Cable Flye"))
        XCTAssertTrue(nextFirst.label.contains("CS DB Row"))
        XCTAssertFalse(nextFirst.label.contains("SA CS Cable Row"))
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Super ROM DB Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated DB Shrugs"))
    }

}
