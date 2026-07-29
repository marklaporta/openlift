import XCTest

final class AdaptiveProposalUITests: OpenLiftUITestCase {
    func testAdaptiveCycleSurfaceOpensProfileEditorAndLoadsExplicitStarter() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Log"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(app.buttons["Log Workout"].exists)
        XCTAssertTrue(app.tabBars.buttons["Cycle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Import"].exists)
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)

        confirmTrainingMode("Adaptive Floating", in: app)
        XCTAssertTrue(app.staticTexts["Adaptive Profile"].waitForExistence(timeout: 5))

        let selection = app.buttons["adaptive.exerciseSelection"]
        scrollToElement(selection, in: app)
        selection.tap()
        XCTAssertTrue(app.navigationBars["Exercise Selection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternate recent"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pinned exercise"].firstMatch.exists)
        app.buttons["Cancel"].tap()

        let createProfile = app.buttons["New Adaptive Profile"]
        XCTAssertTrue(createProfile.waitForExistence(timeout: 5))
        createProfile.tap()
        XCTAssertTrue(app.navigationBars["New Adaptive Profile"].waitForExistence(timeout: 5))

        let profileName = app.textFields["adaptive.profileName"]
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        XCTAssertEqual(profileName.value as? String, "New Adaptive Profile")
        XCTAssertTrue(app.staticTexts["Maximum muscle groups: 5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Maximum exercises: 7"].exists)
        XCTAssertTrue(app.staticTexts["Exercises per muscle: 2"].exists)
        XCTAssertTrue(app.staticTexts["Maximum working sets: 15"].exists)

        let loadDemo = app.buttons["adaptive.loadDemo"]
        XCTAssertTrue(loadDemo.waitForExistence(timeout: 5))
        loadDemo.tap()
        XCTAssertEqual(profileName.value as? String, "Adaptive Starter — Review Required")
    }

    func testAdaptiveProposalUsesHistoryForSelectionAndPrefill() throws {
        let app = launchApp([
            "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW",
            "OPENLIFT_UI_TESTING_ADAPTIVE_HISTORY"
        ])

        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)

        app.tabBars.buttons["Workout"].tap()
        let generatePlan = app.buttons["adaptive.generatePlan"]
        scrollToElement(generatePlan, in: app)
        generatePlan.tap()

        let proposedPlan = app.staticTexts["2 · Design"]
        for _ in 0..<4 {
            if proposedPlan.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(proposedPlan.waitForExistence(timeout: 5))
        for exercise in ["Flat Dumbbell Press", "Cable Row"] {
            let plannedExercise = app.staticTexts[exercise]
            scrollToElement(plannedExercise, in: app)
            XCTAssertTrue(plannedExercise.exists)
        }

        let splitDose = app.staticTexts["2 sets"].firstMatch
        scrollToElement(splitDose, in: app)
        XCTAssertTrue(splitDose.exists)
        let priorPerformance = app.staticTexts["adaptive.previous.Flat Dumbbell Press"]
        scrollToElement(priorPerformance, in: app)
        XCTAssertEqual(priorPerformance.label, "Previous: 60.0 x 9")

        let useWorkout = app.buttons["adaptive.useWorkout"]
        scrollToElement(useWorkout, in: app)
        useWorkout.tap()

        let firstWeight = app.textFields["adaptive.weight.Flat Dumbbell Press.1"]
        scrollToElement(firstWeight, in: app)
        XCTAssertEqual(firstWeight.value as? String, "60")
        let firstReps = app.textFields["adaptive.reps.Flat Dumbbell Press.1"]
        XCTAssertEqual(firstReps.value as? String, "9")
    }
}
