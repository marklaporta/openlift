import XCTest

final class FixedCycleWorkoutUITests: OpenLiftUITestCase {
    func testAppOpensOnWorkoutTab() throws {
        let app = launchApp()

        // Unique coverage here is the default landing tab and the armed readiness gate.
        // Submitting readiness and asserting the draft header is exercised by five other
        // tests, so this one stops before that expensive sequence.
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 · Readiness"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Log Workout"].exists)
    }

    func testResistanceProfilesAppearOnlyForCableMovements() throws {
        let app = launchApp()

        submitFixedReadiness(in: app)
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["fixed.resistanceProfile.Flat Dumbbell Press"].exists)

        let cableProfile = app.buttons[
            "fixed.resistanceProfile.Cable Crossover Lateral Raise"
        ]
        scrollToElement(cableProfile, in: app)
        XCTAssertTrue(cableProfile.exists)
    }

    func testRotationWorkoutFinishShowsRecapAndNonEditableTomorrowPreview() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))

        let weight = app.textFields["fixed.weight.Flat Dumbbell Press.1"]
        scrollToElement(weight, in: app)
        weight.tap()
        weight.typeText("45")
        let reps = app.textFields["fixed.reps.Flat Dumbbell Press.1"]
        reps.tap()
        reps.typeText("10")
        app.buttons["fixed.lock.Flat Dumbbell Press.1"].tap()

        let finishButton = app.buttons["Finish Workout"]
        for _ in 0..<8 {
            if finishButton.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        finishButton.tap()

        scrollToElement(app.staticTexts["fixed.completedToday"], in: app)
        XCTAssertEqual(app.staticTexts["fixed.completedToday"].label, "Upper A complete")
        XCTAssertTrue(app.staticTexts["fixed.completedToday.recap"].label.contains("1 completed set"))

        scrollToElement(app.staticTexts["fixed.nextWorkoutPreview"], in: app)
        XCTAssertEqual(app.staticTexts["fixed.nextWorkoutPreview"].label, "Lower A")
        XCTAssertFalse(app.buttons["fixed.submitReadiness"].exists)
        XCTAssertFalse(app.textFields["fixed.weight.Leg Press.1"].exists)
    }

    func testClusteredWorkoutCanPersistentlySwapOneExactRotationSlot() throws {
        let app = assertClusteredReplacementRowsAreEditable(
            scopeButton: "This Rotation Slot Going Forward"
        )

        let lock = app.buttons["fixed.lock.Flat Dumbbell Press.1"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()

        let completeCluster = app.buttons["Complete Cluster 1"]
        scrollToElement(completeCluster, in: app)
        completeCluster.tap()

        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app)
        finish.tap()
        XCTAssertTrue(app.staticTexts["fixed.completedToday"].waitForExistence(timeout: 5))
    }

    func testClusteredWorkoutCanSwapOneSlotForThisWorkoutOnly() throws {
        let app = assertClusteredReplacementRowsAreEditable(scopeButton: "This Workout Only")

        let more = app.buttons["workout.more.cluster-1.0.0"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let reset = app.buttons["Reset to Program Default"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()

        let canonicalWeight = app.textFields["fixed.weight.Incline Dumbbell Press.1"]
        scrollToElement(canonicalWeight, in: app)
        XCTAssertTrue(canonicalWeight.exists)
        XCTAssertTrue(canonicalWeight.isEnabled)
        XCTAssertFalse(app.textFields["fixed.weight.Flat Dumbbell Press.1"].exists)
    }

    private func assertClusteredReplacementRowsAreEditable(scopeButton: String) -> XCUIApplication {
        let app = launchApp(["OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT"])

        submitFixedReadiness(in: app)

        let swap = app.buttons["workout.swap.cluster-1.0.0"]
        scrollToElement(swap, in: app)
        swap.tap()

        XCTAssertTrue(app.navigationBars["Replace Exercise in Cluster 1 · A"].waitForExistence(timeout: 5))
        let replacement = app.buttons["swap.candidate.Flat Dumbbell Press"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.tap()

        let scope = app.buttons[scopeButton]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()

        scrollToElement(app.staticTexts["Flat Dumbbell Press"], in: app)
        XCTAssertTrue(app.staticTexts["Flat Dumbbell Press"].exists)
        XCTAssertTrue(app.buttons["workout.swap.cluster-1.0.0"].exists)

        let weight = app.textFields["fixed.weight.Flat Dumbbell Press.1"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertTrue(weight.isEnabled)
        weight.tap()
        weight.typeText("35")

        let reps = app.textFields["fixed.reps.Flat Dumbbell Press.1"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        XCTAssertTrue(reps.isEnabled)
        reps.tap()
        reps.typeText("8")

        XCTAssertEqual(weight.value as? String, "35")
        XCTAssertEqual(reps.value as? String, "8")
        return app
    }
}
