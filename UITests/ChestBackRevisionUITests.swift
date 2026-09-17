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
        let weight = app.textFields["fixed.weight.Flat Dumbbell Press.1"]
        scrollToElement(weight, in: app)
        weight.tap(); weight.typeText("45")
        let reps = app.textFields["fixed.reps.Flat Dumbbell Press.1"]
        reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.Flat Dumbbell Press.1"].tap()
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
        XCTAssertTrue(nextThird.label.contains("Super ROM Dumbbell Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated Dumbbell Shrugs"))
    }

}
