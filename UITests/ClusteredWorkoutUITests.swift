import XCTest

final class ClusteredWorkoutUITests: OpenLiftUITestCase {
    func testCycleTabSwapsSquatsOnlyAfterFinishingWorkout() throws {
        let app = launchApp(["OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SHRUG_ACTIVATION",
                             "OPENLIFT_ADD_CLUSTERED_SHRUGS_2026_09_08"])
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.swapSquats"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cycle.squatSwapSuccess").firstMatch.exists)
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
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cycle.squatSwapSuccess").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v3"].firstMatch.exists)
    }

    func testCycleTabAddsAlternatingShrugsOnlyAfterCurrentWorkoutIsFinished() throws {
        let app = launchApp(["OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SHRUG_ACTIVATION"])
        app.tabBars.buttons["Cycle"].tap()
        let apply = app.buttons["cycle.addAlternatingShrugs"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["cycle.shrugDraftBlocker"].exists)
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
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cycle.shrugUpdateSuccess").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.exists)
        XCTAssertTrue(app.staticTexts["Clustered Hypertrophy v3"].firstMatch.exists)
        app.tabBars.buttons["Workout"].tap()
        let nextFirst = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-1").firstMatch
        scrollToElement(nextFirst, in: app)
        XCTAssertTrue(nextFirst.label.contains("Next: B"))
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Unchanged"))
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        XCTAssertTrue(nextThird.label.contains("Seated Dumbbell Shrugs"))
    }

    func testAlternatingShrugRevisionStartsBlankAndAdvancesOnlyCompletedThirdCluster() throws {
        let app = launchApp(["OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_ADD_CLUSTERED_SHRUGS_2026_09_08"])
        submitFixedReadiness(in: app)
        let target = app.staticTexts["workout.shrugRepTarget"]
        scrollToElement(target, in: app)
        XCTAssertTrue(target.exists)
        XCTAssertEqual(target.label, "Target: 12–16 reps")
        let weight = app.textFields["fixed.weight.Seated Dumbbell Shrugs.1"]
        scrollToElement(weight, in: app)
        XCTAssertTrue(weight.exists)
        XCTAssertEqual(weight.value as? String, "Weight")
        let second = app.textFields["fixed.weight.Seated Dumbbell Shrugs.2"]
        XCTAssertTrue(second.exists)
        XCTAssertFalse(app.textFields["fixed.weight.Seated Dumbbell Shrugs.3"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "fixed.resistanceProfile.Seated Dumbbell Shrugs").firstMatch.exists)
        weight.tap(); weight.typeText("45")
        let reps = app.textFields["fixed.reps.Seated Dumbbell Shrugs.1"]
        reps.tap(); reps.typeText("14")
        app.buttons["fixed.lock.Seated Dumbbell Shrugs.1"].tap()
        let complete = app.buttons["Complete Cluster 3"]
        scrollToElement(complete, in: app); complete.tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        let nextFirst = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-1").firstMatch
        scrollToElement(nextFirst, in: app)
        XCTAssertTrue(nextFirst.label.contains("Unchanged"))
        XCTAssertTrue(nextFirst.label.contains("Next: A"))
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Advanced"))
        XCTAssertTrue(nextThird.label.contains("Next: B"))
        XCTAssertFalse(nextThird.label.contains("Shrug"), "The next forearm variant must remain shrug-free")
    }

    func testClusteredGoingForwardSwapKeepsRowsEditableAndRequiresClusterCompletion() throws {
        let app = assertClusteredReplacementRowsAreEditable(
            scopeButton: "This Rotation Slot Going Forward"
        )
        let state = app.descendants(matching: .any).matching(identifier: "workout.clusterState.cluster-1").firstMatch
        scrollToElement(state, in: app, toward: .top)
        XCTAssertTrue(state.label.contains("Not started"))
        let lock = app.buttons["fixed.lock.Flat Dumbbell Press.1"]
        scrollToElement(lock, in: app)
        lock.tap()
        scrollToElement(state, in: app, toward: .top)
        XCTAssertTrue(state.label.contains("In progress"))
        XCTAssertTrue(state.label.contains("1 completed set"))
        let started = XCTAttachment(screenshot: app.screenshot())
        started.name = "Cluster in progress"; started.lifetime = .keepAlways; add(started)

        let completeCluster = app.buttons["Complete Cluster 1"]
        scrollToElement(completeCluster, in: app)
        completeCluster.tap()
        scrollToElement(state, in: app, toward: .top)
        XCTAssertTrue(state.label.contains("Completed"))
        XCTAssertTrue(state.label.contains("1 completed set"))

        // Finishing must name the exact other cluster with confirmed work and
        // take us back to it, without silently dropping that work.
        let weight = app.textFields["fixed.weight.Belt Squat.1"]
        scrollToElement(weight, in: app)
        weight.tap(); weight.typeText("50")
        let reps = app.textFields["fixed.reps.Belt Squat.1"]
        reps.tap(); reps.typeText("10")
        app.buttons["fixed.lock.Belt Squat.1"].tap()
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        let review = app.alerts.buttons["Review Cluster 2"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let reviewedState = app.staticTexts["workout.clusterState.cluster-2"]
        XCTAssertTrue(reviewedState.waitForExistence(timeout: 5))
        XCTAssertTrue(reviewedState.isHittable)
        let completeSecond = app.buttons["Complete Cluster 2"]
        scrollToElement(completeSecond, in: app); completeSecond.tap()
        scrollToElement(finish, in: app); finish.tap()
        scrollToElement(app.staticTexts["fixed.completedToday"], in: app, toward: .top)
        XCTAssertTrue(app.staticTexts["fixed.completedToday.recap"].label.contains("2 completed sets"))
        let saved = app.descendants(matching: .any).matching(identifier: "workout.save.local").firstMatch
        scrollToElement(saved, in: app)
        XCTAssertTrue(saved.label.contains("saved on this device"))
        XCTAssertTrue(app.staticTexts["workout.save.cloud"].exists)
        let recap = XCTAttachment(screenshot: app.screenshot())
        recap.name = "Completion and honest backup status"; recap.lifetime = .keepAlways; add(recap)
        let nextFirst = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-1").firstMatch
        scrollToElement(nextFirst, in: app)
        XCTAssertTrue(nextFirst.label.contains("Advanced"))
        XCTAssertTrue(nextFirst.label.contains("Next: B"))
        let nextThird = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-3").firstMatch
        scrollToElement(nextThird, in: app)
        XCTAssertTrue(nextThird.label.contains("Unchanged"))
        XCTAssertTrue(nextThird.label.contains("Next: A"))
        let rotations = XCTAttachment(screenshot: app.screenshot())
        rotations.name = "Independent next rotations"; rotations.lifetime = .keepAlways; add(rotations)
    }

    func testClusteredWorkoutOnlySwapKeepsRowsEditableAndCanReset() throws {
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
