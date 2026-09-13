import XCTest

final class SideDeltRevisionUITests: OpenLiftUITestCase {
    private func launchSideDeltFixture(rows: Bool = false, order: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT",
            "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        if order { app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ORDER"] = "1" }
        if rows { app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ROWS"] = "1" }
        app.launch()
        return app
    }

    func testActualActivationButtonBlocksDraftThenPersistsThroughColdLaunch() throws {
        let app = launchSideDeltFixture()
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.addThirdSideDelt"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["cycle.sideDeltDraftBlocker"].exists)
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.sideDeltSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Third side-delt activation succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v4"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Super ROM Dumbbell Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated Dumbbell Shrugs"))
    }

    func testPermanentOrderButtonBlocksDraftThenPersistsThroughColdLaunch() throws {
        let app = launchSideDeltFixture(order: true)
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.reorderSideDelts"]
        scrollToElement(apply, in: app)
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["cycle.sideDeltOrderDraftBlocker"].exists)
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
        let success = app.descendants(matching: .any).matching(identifier: "cycle.sideDeltOrderSuccess").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "Third side-delt activation succeeded"; receipt.lifetime = .keepAlways; add(receipt)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Cycle"].tap()
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v5"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Incline Side-Lying Dumbbell Lateral Raise"))
        XCTAssertTrue(nextThird.label.contains("Seated Dumbbell Shrugs"))
    }

    func testNewMovementStartsWithTwoBlankRowsAndPerSideLoggingNote() throws {
        let app = launchSideDeltFixture(rows: true)
        submitFixedReadiness(in: app)
        let note = app.staticTexts["workout.sideDeltLoggingNote"]
        scrollToElement(note, in: app)
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("one set on each side"))
        let name = "Incline Side-Lying Dumbbell Lateral Raise"
        let weight = app.textFields["fixed.weight.\(name).1"]
        scrollToElement(weight, in: app)
        XCTAssertEqual(weight.value as? String, "Weight")
        XCTAssertEqual(app.textFields["fixed.reps.\(name).1"].value as? String, "Reps")
        XCTAssertTrue(app.textFields["fixed.weight.\(name).2"].exists)
        XCTAssertFalse(app.textFields["fixed.weight.\(name).3"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "fixed.resistanceProfile.\(name)").firstMatch.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "New side-delt blank rows"; receipt.lifetime = .keepAlways; add(receipt)
        weight.tap(); weight.typeText("10")
        let reps = app.textFields["fixed.reps.\(name).1"]
        reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.\(name).1"].tap()
        let complete = app.buttons["Complete Cluster 3"]
        scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        let third = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(third, in: app)
        XCTAssertTrue(third.label.contains("Next: C"))
        XCTAssertTrue(third.label.contains("Cable Lateral Raise"))
        XCTAssertTrue(third.label.contains("Seated Dumbbell Shrugs"))
    }
    func testReorderedInclineStartsBlankAndAdvancesToSuperROM() throws {
        let app = launchSideDeltFixture(rows: true, order: true)
        submitFixedReadiness(in: app)
        let note = app.staticTexts["workout.sideDeltLoggingNote"]
        scrollToElement(note, in: app)
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("one set on each side"))
        let name = "Incline Side-Lying Dumbbell Lateral Raise"
        let weight = app.textFields["fixed.weight.\(name).1"]
        scrollToElement(weight, in: app)
        XCTAssertEqual(weight.value as? String, "Weight")
        XCTAssertEqual(app.textFields["fixed.reps.\(name).1"].value as? String, "Reps")
        XCTAssertTrue(app.textFields["fixed.weight.\(name).2"].exists)
        XCTAssertFalse(app.textFields["fixed.weight.\(name).3"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "fixed.resistanceProfile.\(name)").firstMatch.exists)
        let receipt = XCTAttachment(screenshot: app.screenshot())
        receipt.name = "New side-delt blank rows"; receipt.lifetime = .keepAlways; add(receipt)
        weight.tap(); weight.typeText("10")
        let reps = app.textFields["fixed.reps.\(name).1"]
        reps.tap(); reps.typeText("12")
        app.buttons["fixed.lock.\(name).1"].tap()
        let complete = app.buttons["Complete Cluster 3"]
        scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        let third = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(third, in: app)
        XCTAssertTrue(third.label.contains("Next: B"))
        XCTAssertTrue(third.label.contains("Super ROM Dumbbell Lateral Raise"))

    }
}
