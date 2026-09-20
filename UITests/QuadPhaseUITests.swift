import XCTest

final class QuadPhaseUITests: OpenLiftUITestCase {
    func testQuadPhaseButtonBlocksDraftAndPersistsCold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        app.launchEnvironment["OPENLIFT_CHEST_BACK_UI"] = "1"
        app.launchEnvironment["OPENLIFT_ROW_PAIRING_UI"] = "1"
        app.launchEnvironment["OPENLIFT_BALANCED_UI"] = "1"
        app.launchEnvironment["OPENLIFT_QUAD_PHASE_UI"] = "1"
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.applyQuadPhase"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(apply.isEnabled)
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Incline DB Press.1"]
        scrollToElement(weight, in: app)
        weight.tap(); weight.typeText("45")
        let reps = app.textFields["fixed.reps.Incline DB Press.1"]
        reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.Incline DB Press.1"].tap()
        let complete = app.buttons["Complete Cluster 1"]
        scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        app.tabBars.buttons["Cycle"].tap()
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        let success = app.descendants(matching: .any).matching(identifier: "cycle.quadPhaseSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Quad phase succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v7"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let persisted = app.descendants(matching: .any).matching(identifier: "cycle.quadPhaseSuccess").firstMatch
        scrollToElement(persisted, in: app)
        XCTAssertTrue(persisted.exists)
    }
}
