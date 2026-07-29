import XCTest

// XCUITest parallelizes by class, not by file, so the suite is split into small
// classes balanced by measured runtime. Shared launch/scroll/readiness helpers live
// here on a common base. The classes used to share one file because the project listed
// test sources explicitly; the test targets are file-system synchronized groups now, so
// a new file compiles on its own and one class per file is free.
//
// Run with `-maximum-parallel-testing-workers 3`. Measured on the M4 (10 cores, 4 of
// them performance): 3 workers is green and fastest; 5 oversubscribes the performance
// cores and the resulting scroll lag makes scrollToElement flaky. Test plans cannot pin
// the worker count -- Xcode's test-plan schema has no such option -- so runs started
// from Xcode's GUI pick their own and can still hit that flake.
class OpenLiftUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func launchApp(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["OPENLIFT_UI_TESTING"] + extraArguments
        app.launch()
        return app
    }

    // Fixed Cycle gates the workout list behind a dated readiness observation. The
    // form opens pre-filled with the all-clear defaults, so submitting once is enough
    // to reach the exercise sections.
    func submitFixedReadiness(in app: XCUIApplication) {
        let submit = app.buttons["fixed.submitReadiness"]
        scrollToElement(submit, in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        // Asserting absence with `waitForExistence` can never return early, so it burned
        // the full timeout on every call. Wait on the predicate instead: it completes as
        // soon as the form is gone.
        let dismissed = XCTWaiter().wait(
            for: [
                expectation(
                    for: NSPredicate(format: "exists == false"),
                    evaluatedWith: submit
                )
            ],
            timeout: 5
        )
        XCTAssertEqual(dismissed, .completed)

        // The submit button sits below the per-muscle sections, so the list is left
        // scrolled down when the workout content replaces the readiness form.
        for _ in 0..<8 {
            app.swipeDown()
        }
    }

    func dismissExpectedICloudCycleAlertIfPresent(in app: XCUIApplication) {
        let alert = app.alerts["Cycle Error"]
        guard alert.waitForExistence(timeout: 2) else { return }
        XCTAssertTrue(alert.staticTexts["Could not access the OpenLift cycles folder in iCloud Drive."].exists)
        alert.buttons["OK"].tap()
    }

    func confirmTrainingMode(_ name: String, in app: XCUIApplication) {
        let mode = app.buttons[name]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let confirmation = app.buttons["Use \(name)"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

    // `for ... where` is a filter, not a break: the original form kept iterating and
    // re-evaluated `isHittable` all 32 times even once the element was on screen, and
    // each of those checks forces a full accessibility snapshot of the list.
    //
    // Those redundant checks were also acting as an accidental ~30s settle while a
    // screen transition finished. Breaking early removes that, so wait for existence
    // explicitly first. It returns immediately when the element is already present, and
    // genuinely off-screen rows in a lazy List still fall through to the scroll loops.
    func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 5), element.isHittable { return }
        for _ in 0..<16 {
            if element.isHittable { break }
            app.swipeUp()
        }
        for _ in 0..<16 {
            if element.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))

        // Parallel simulator clones contend for CPU, so a scroll can still be settling
        // once the swipe budget is spent — the loops above poll isHittable faster than
        // the animation lands. Give the layout a bounded chance to catch up instead of
        // failing on a transient state. Returns immediately when already hittable.
        if !element.isHittable {
            _ = XCTWaiter().wait(
                for: [
                    expectation(
                        for: NSPredicate(format: "isHittable == true"),
                        evaluatedWith: element
                    )
                ],
                timeout: 10
            )
        }
        XCTAssertTrue(element.isHittable)
    }
}
