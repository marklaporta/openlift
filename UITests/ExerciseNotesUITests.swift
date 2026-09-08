import XCTest

final class ExerciseNotesUITests: OpenLiftUITestCase {
    func testFixedNoteSaveReopenCancelAndClearSharedWithAdHocLogging() throws {
        let app = launchApp()
        submitFixedReadiness(in: app)
        let note = app.buttons["exercise.notes.Flat Dumbbell Press"]
        scrollToElement(note, in: app)
        XCTAssertEqual(note.value as? String, "No note")
        note.tap()
        let editor = app.textViews["exercise.notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Bench position: 3")
        app.buttons["exercise.notes.save"].tap()
        XCTAssertEqual(note.value as? String, "Bench position: 3")

        note.tap()
        XCTAssertEqual(editor.value as? String, "Bench position: 3")
        app.buttons["exercise.notes.clear"].tap()
        app.buttons["exercise.notes.cancel"].tap()
        XCTAssertEqual(note.value as? String, "Bench position: 3")

        app.tabBars.buttons["Log"].tap()
        app.buttons["log.exercisePicker"].firstMatch.tap()
        let selected = app.buttons["Flat Dumbbell Press"].firstMatch
        scrollToElement(selected, in: app)
        selected.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.value as? String, "Bench position: 3")
        note.tap()
        app.buttons["exercise.notes.clear"].tap()
        editor.tap()
        editor.typeText("Bench position: 4")
        app.buttons["exercise.notes.save"].tap()

        app.tabBars.buttons["Workout"].tap()
        scrollToElement(note, in: app)
        XCTAssertEqual(note.value as? String, "Bench position: 4")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Exercise note visible above set logging"
        attachment.lifetime = .keepAlways
        add(attachment)
        note.tap()
        app.buttons["exercise.notes.clear"].tap()
        app.buttons["exercise.notes.save"].tap()
        XCTAssertEqual(note.value as? String, "No note")
        note.tap()
        XCTAssertEqual(editor.value as? String, "")
        app.buttons["exercise.notes.cancel"].tap()
    }

    func testAdaptiveExerciseNoteCanBeSavedDuringExecution() throws {
        let app = launchApp(["OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"])
        app.tabBars.buttons["Cycle"].tap()
        dismissExpectedICloudCycleAlertIfPresent(in: app)
        confirmTrainingMode("Adaptive Floating", in: app)
        app.tabBars.buttons["Workout"].tap()
        let generate = app.buttons["adaptive.generatePlan"]
        scrollToElement(generate, in: app)
        generate.tap()
        let useWorkout = app.buttons["adaptive.useWorkout"]
        scrollToElement(useWorkout, in: app)
        useWorkout.tap()
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exercise.notes.")).firstMatch
        scrollToElement(note, in: app, toward: .top)
        note.tap()
        let editor = app.textViews["exercise.notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Seat: 2")
        app.buttons["exercise.notes.save"].tap()
        XCTAssertEqual(note.value as? String, "Seat: 2")
        note.tap()
        XCTAssertEqual(editor.value as? String, "Seat: 2")
        app.buttons["exercise.notes.cancel"].tap()
    }
}
