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
    func testSeparateCardsAllowInterleavedLoggingAndShareCompletion() throws {
        let app = legacyAdministrationApp()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT", "OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION"]
        app.launchEnvironment["OPENLIFT_SIDE_DELT_UI_ID"] = UUID().uuidString
        for key in ["OPENLIFT_CHEST_BACK_UI", "OPENLIFT_ROW_PAIRING_UI", "OPENLIFT_BALANCED_UI", "OPENLIFT_QUAD_PHASE_UI", "OPENLIFT_SYNCED_ARMS_UI", "OPENLIFT_SYNCED_ARMS_ROWS_UI"] { app.launchEnvironment[key] = "1" }
        app.launch()
        app.tabBars.buttons["Workout"].tap()
        submitFixedReadiness(in: app)

        func record(_ exercise: String, set: Int = 1, toward direction: ScrollDestination = .bottom) {
            let weight = app.textFields["fixed.weight.\(exercise).\(set)"]
            scrollToElement(weight, in: app, toward: direction)
            XCTAssertTrue(weight.isEnabled)
            weight.tap(); weight.typeText("25")
            let reps = app.textFields["fixed.reps.\(exercise).\(set)"]
            reps.tap(); reps.typeText("10")
            app.buttons["fixed.lock.\(exercise).\(set)"].tap()
        }
        let torso = app.staticTexts["workout.group.cluster-1.torso"]
        scrollToElement(torso, in: app)
        XCTAssertTrue(torso.label.localizedCaseInsensitiveContains("Torso"))
        XCTAssertFalse(app.buttons["Complete Cluster 1"].exists)
        record("Incline DB Flye")
        let legs = app.staticTexts["workout.group.cluster-2"]
        scrollToElement(legs, in: app)
        record("Stiff-Leg Deadlift")
        let arms = app.staticTexts["workout.group.cluster-1.arms"]
        scrollToElement(arms, in: app)
        XCTAssertTrue(arms.label.localizedCaseInsensitiveContains("Arms"))
        let armCard = XCTAttachment(screenshot: app.screenshot())
        armCard.name = "Separate Arms card after legs"; armCard.lifetime = .keepAlways; add(armCard)
        let note = app.staticTexts["workout.singleArmOverheadLoggingNote"]
        scrollToElement(note, in: app)
        XCTAssertTrue(note.isHittable)
        let cableProfile = app.buttons["fixed.resistanceProfile.Overhead SA Cable Extension"]
        scrollToElement(cableProfile, in: app); cableProfile.tap()
        XCTAssertTrue(app.navigationBars["Cable Resistance"].waitForExistence(timeout: 5))
        app.buttons["Weight Stack"].tap()
        app.buttons["Save"].tap()
        record("Overhead SA Cable Extension")
        let setup = app.buttons["exercise.notes.Seated DB Hammer Curl"]
        scrollToElement(setup, in: app)
        XCTAssertTrue((setup.value as? String ?? "").contains("nearly upright back support"))
        let setupImage = XCTAttachment(screenshot: app.screenshot())
        setupImage.name = "Arm setup instructions beside reachable sets"; setupImage.lifetime = .keepAlways; add(setupImage)
        record("Seated DB Hammer Curl")
        // No active-exercise gate: return to legs, then torso, after arm work.
        record("Stiff-Leg Deadlift", set: 2, toward: .top)
        record("Incline DB Flye", set: 2, toward: .top)
        let untouchedArmRows = app.textFields["fixed.reps.Seated DB Hammer Curl.2"]
        scrollToElement(untouchedArmRows, in: app)
        XCTAssertTrue(untouchedArmRows.isEnabled)
        XCTAssertEqual(untouchedArmRows.value as? String, "Reps")
        let third = app.staticTexts["workout.group.cluster-3"]
        scrollToElement(third, in: app)
        XCTAssertTrue(third.isHittable, "The rest of the workout remains reachable")
        let accessorySet = app.textFields["fixed.weight.Super ROM DB Lateral Raise.1"]
        scrollToElement(accessorySet, in: app)
        XCTAssertTrue(accessorySet.isEnabled)
        let complete = app.buttons["Complete Torso + Arms"]
        scrollToElement(complete, in: app, toward: .top); complete.tap()
        let armState = app.staticTexts["workout.clusterState.cluster-1.arms"]
        scrollToElement(armState, in: app, toward: .top)
        XCTAssertTrue(armState.label.contains("Completed"))
        XCTAssertTrue(armState.label.contains("2 completed sets"))
        let torsoState = app.staticTexts["workout.clusterState.cluster-1"]
        scrollToElement(torsoState, in: app, toward: .top)
        XCTAssertTrue(torsoState.label.contains("Completed"))
        XCTAssertTrue(torsoState.label.contains("2 completed sets"))
        let finish = app.buttons["Finish Workout"]
        scrollToElement(finish, in: app); finish.tap()
        let review = app.alerts.buttons["Review Cluster 2"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        XCTAssertTrue(app.staticTexts["workout.clusterState.cluster-2"].isHittable)
        let completeLegs = app.buttons["Complete Cluster 2"]
        scrollToElement(completeLegs, in: app); completeLegs.tap()
        scrollToElement(finish, in: app); finish.tap()
        let recap = app.staticTexts["fixed.completedToday.recap"]
        scrollToElement(recap, in: app, toward: .top)
        XCTAssertTrue(recap.label.contains("6 completed sets"))
        let next = app.descendants(matching: .any).matching(identifier: "fixed.nextCluster.cluster-1").firstMatch
        scrollToElement(next, in: app)
        XCTAssertTrue(next.label.contains("Advanced"))
        XCTAssertTrue(next.label.contains("Next: A"))
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
