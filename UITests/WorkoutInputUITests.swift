import XCTest

final class WorkoutInputUITests: OpenLiftUITestCase {
    func testTypingResponsivenessProbe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING", "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT"]
        app.launchEnvironment["OPENLIFT_INPUT_PROBE"] = "1"
        app.launch()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Incline DB Press.1"]
        scrollToElement(weight, in: app)
        for iteration in 1...3 {
            weight.tap()
            let current = weight.value as? String ?? ""
            if current != "Weight" { weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
            let sequence = "123.5" + String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5)
            weight.typeText(String(repeating: sequence, count: 6) + "45.5")
            app.buttons["Done"].firstMatch.tap()
            let report = app.staticTexts["input.probe"].label
            print("INPUT_PROBE iteration=\(iteration) \(report)")
            XCTAssertEqual(weight.value as? String, "45.5")
        }
    }
    func testPreviousWeightAssumedDirectReplacementAndKeyboardCompletion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING"]
        app.launchEnvironment["OPENLIFT_INPUT_HISTORY_UI"] = "1"
        app.launch()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Flat DB Press.1"]
        let reps = app.textFields["fixed.reps.Flat DB Press.1"]
        scrollToElement(weight, in: app)
        XCTAssertEqual(weight.value as? String, "45")
        XCTAssertEqual(reps.value as? String, "Reps", "New rows must not treat prior reps as performed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Previous:")).firstMatch.exists)
        reps.tap(); reps.typeText("12")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let keyboardShot = XCTAttachment(screenshot: app.screenshot())
        keyboardShot.name = "Complete Set reachable with keyboard open"; keyboardShot.lifetime = .keepAlways; add(keyboardShot)
        app.buttons["fixed.keyboard.complete"].tap()
        XCTAssertFalse(reps.isEnabled)
        XCTAssertEqual(reps.value as? String, "12")
        XCTAssertEqual(weight.value as? String, "45", "Untouched previous weight is accepted without a reuse tap")

        let secondWeight = app.textFields["fixed.weight.Flat DB Press.2"]
        let secondReps = app.textFields["fixed.reps.Flat DB Press.2"]
        secondWeight.tap(); secondWeight.typeText("47.")
        XCTAssertEqual(secondWeight.value as? String, "47.", "Partial decimal survives idle saving")
        secondWeight.typeText("5")
        secondReps.tap(); secondReps.typeText("14")
        app.buttons["fixed.keyboard.complete"].tap()
        XCTAssertEqual(secondWeight.value as? String, "47.5", "Typing replaces prefilled 45 without deleting")
        XCTAssertEqual(secondReps.value as? String, "14")
        XCTAssertFalse(secondReps.isEnabled)
        let thirdWeight = app.textFields["fixed.weight.Flat DB Press.3"]
        scrollToElement(thirdWeight, in: app)
        XCTAssertEqual(thirdWeight.value as? String, "47.5", "Within-session weight reuse is preserved")
        app.buttons["fixed.lock.Flat DB Press.3"].tap()
        XCTAssertTrue(app.alerts["Workout Needs Attention"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(thirdWeight.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Input rows retain full workout and previous reference"; shot.lifetime = .keepAlways; add(shot)
    }

    func testExistingDraftRepsSurviveAndCanBeReplacedWithoutDeleting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING"]
        app.launchEnvironment["OPENLIFT_INPUT_HISTORY_UI"] = "1"
        app.launchEnvironment["OPENLIFT_INPUT_EXISTING_DRAFT_UI"] = "1"
        app.launch()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Flat DB Press.1"]
        let reps = app.textFields["fixed.reps.Flat DB Press.1"]
        scrollToElement(weight, in: app)
        XCTAssertEqual(weight.value as? String, "47.5")
        XCTAssertEqual(reps.value as? String, "11")
        reps.tap(); reps.typeText("13")
        app.buttons["fixed.keyboard.complete"].tap()
        XCTAssertEqual(reps.value as? String, "13")
        XCTAssertFalse(reps.isEnabled)
        app.buttons["fixed.lock.Flat DB Press.1"].tap()
        XCTAssertTrue(reps.isEnabled)
        reps.tap(); reps.typeText("15")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(reps.value as? String, "15", "Background flush retains latest raw draft edit")
    }

    func testInvalidReplacementCannotCompleteOldWeightAndCanBeCorrected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["OPENLIFT_UI_TESTING"]
        app.launchEnvironment["OPENLIFT_INPUT_HISTORY_UI"] = "1"
        app.launch()
        submitFixedReadiness(in: app)
        let weight = app.textFields["fixed.weight.Flat DB Press.1"]
        let reps = app.textFields["fixed.reps.Flat DB Press.1"]
        scrollToElement(weight, in: app)
        reps.tap(); reps.typeText("12")
        weight.tap(); weight.typeText("1..5")
        app.buttons["fixed.keyboard.complete"].tap()
        let alert = app.alerts["Workout Needs Attention"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["OK"].tap()
        XCTAssertTrue(weight.isEnabled)
        XCTAssertEqual(weight.value as? String, "1..5", "Invalid input is not replaced by the old assumed weight")
        // This field can remain focused after an alert. Explicitly correct the
        // invalid text; type-to-replace on a fresh focus is tested separately.
        weight.tap()
        let invalid = weight.value as? String ?? ""
        weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: invalid.count) + "50")
        app.buttons["fixed.keyboard.complete"].tap()
        XCTAssertFalse(weight.isEnabled)
        XCTAssertEqual(weight.value as? String, "50")
        XCTAssertEqual(reps.value as? String, "12")
    }

}
