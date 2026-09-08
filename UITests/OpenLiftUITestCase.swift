import XCTest

// XCUITest parallelizes by class, not by file, so the suite is split into small
// classes balanced by measured runtime. Shared launch/scroll/readiness helpers live
// here on a common base. The classes used to share one file because the project listed
// test sources explicitly; the test targets are file-system synchronized groups now, so
// a new file compiles on its own and one class per file is free.
//
// scripts/test.py runs at most 3 UI simulators, with balanced, disjoint shards.
// Earlier M4 measurements found 3 workers stable and 5 oversubscribed performance
// cores, making scrolling flaky. This is a conservative known-good cap, not a
// universal optimum. Direct Xcode runs still choose their own class ordering.
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
        let draft = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", " · Draft session")
        ).firstMatch
        scrollToElement(draft, in: app, toward: .top)
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

    enum ScrollDestination {
        case top, bottom

        var opposite: Self { self == .top ? .bottom : .top }

        func swipe(in app: XCUIApplication) {
            switch self {
            case .top: app.swipeDown()
            case .bottom: app.swipeUp()
            }
        }
    }

    // A lazy List cannot realize an off-screen row merely by waiting for it to
    // exist. Start scrolling immediately; XCTest still synchronizes every query
    // and gesture, and the final existence/hittability safety waits are unchanged.
    // Callers returning to an earlier section can name the direction instead of
    // spending 16 gestures searching toward the wrong end of the list first.
    func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        toward destination: ScrollDestination = .bottom
    ) {
        for direction in [destination, destination.opposite] {
            for _ in 0..<16 {
                // isHittable alone retries a missing lazy node for several seconds.
                // exists is a nonwaiting query; only ask hittability once realized.
                if element.exists && element.isHittable { return }
                direction.swipe(in: app)
            }
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
