import XCTest

// Separate scheduling unit: profile editing must not serialize behind the long
// clustered completion flow when XCUITest distributes classes across workers.
final class ResistanceProfileUITests: OpenLiftUITestCase {
    func testVOLTRAModifiersAcceptIndependentPoundsAndPercentInputs() throws {
        let app = launchApp()
        submitFixedReadiness(in: app)
        XCTAssertTrue(app.staticTexts["Upper A · Draft session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["fixed.resistanceProfile.Flat Dumbbell Press"].exists)
        let profile = app.buttons["fixed.resistanceProfile.Cable Crossover Lateral Raise"]
        scrollToElement(profile, in: app)
        let weight = app.textFields["fixed.weight.Cable Crossover Lateral Raise.1"]
        scrollToElement(weight, in: app)
        weight.tap()
        weight.typeText("130")
        profile.tap()
        app.buttons["VOLTRA"].tap()
        let chainUnit = app.segmentedControls["voltraChainUnit"]
        XCTAssertTrue(chainUnit.waitForExistence(timeout: 5))
        XCTAssertEqual(app.steppers.count, 0)
        chainUnit.buttons["lb"].tap()
        app.segmentedControls["voltraEccentricUnit"].buttons["lb"].tap()
        for id in ["voltraChainAmount", "voltraEccentricAmount"] {
            let field = app.textFields[id]
            field.tap()
            let existing = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "35")
        }
        XCTAssertTrue(app.staticTexts["voltraChainEquivalent.130.0"].label.contains("≈26.9% at 130 lb base"))
        XCTAssertTrue(app.staticTexts["voltraEccentricEquivalent.130.0"].label.contains("≈26.9%"))
        // Reopen the saved sheet to capture both equivalent rows without the keypad.
        app.buttons["Save"].tap()
        profile.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "VOLTRA whole-number pounds with live equivalents"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Save"].tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertTrue(profile.label.contains("35 lb"))
        profile.tap()
        XCTAssertTrue(chainUnit.buttons["lb"].isSelected)
        XCTAssertEqual(app.textFields["voltraChainAmount"].value as? String, "35")
        app.segmentedControls["voltraEccentricUnit"].buttons["%"].tap()
        XCTAssertTrue(chainUnit.buttons["lb"].isSelected)
        let eccentric = app.textFields["voltraEccentricAmount"]
        eccentric.tap()
        eccentric.typeText(XCUIKeyboardKey.delete.rawValue + "30")
        XCTAssertTrue(app.staticTexts["voltraEccentricEquivalent.130.0"].label.contains("=39 lb at 130 lb base"))
        app.buttons["Save"].tap()
        // Changing resistance profiles intentionally clears unlocked set loads.
        // Supply the new profile's base before taking its persisted preview.
        scrollToElement(weight, in: app)
        weight.tap()
        let currentWeight = weight.value as? String ?? ""
        weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentWeight.count) + "130")
        profile.tap()
        XCTAssertTrue(app.staticTexts["voltraEccentricEquivalent.130.0"].label.contains("=39 lb"))
        let mixedShot = XCTAttachment(screenshot: app.screenshot())
        mixedShot.name = "VOLTRA mixed units with reciprocal equivalents"
        mixedShot.lifetime = .keepAlways
        add(mixedShot)
        app.buttons["Save"].tap()
        XCTAssertTrue(profile.label.contains("Inverse Chains 35 lb"))
        XCTAssertTrue(profile.label.contains("Eccentric 30%"))
    }
}
