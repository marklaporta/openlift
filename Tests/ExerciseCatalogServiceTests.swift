import XCTest
@testable import OpenLift

final class ExerciseCatalogServiceTests: XCTestCase {
    func testMakeExerciseTrimsNameAndPreservesSelectedMetadata() throws {
        let exercise = try ExerciseCatalogService.makeExercise(
            name: "  Belt Squat  ",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine,
            existingExercises: []
        )

        XCTAssertEqual(exercise.name, "Belt Squat")
        XCTAssertEqual(exercise.primaryMuscle, .quads)
        XCTAssertEqual(exercise.type, .compound)
        XCTAssertEqual(exercise.equipment, .machine)
        XCTAssertTrue(exercise.isActive)
    }

    func testMakeExerciseRejectsCaseAndWhitespaceEquivalentDuplicate() {
        let existing = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )

        XCTAssertThrowsError(
            try ExerciseCatalogService.makeExercise(
                name: "  incline   DUMBBELL press ",
                primaryMuscle: .chest,
                type: .compound,
                equipment: .dumbbell,
                existingExercises: [existing]
            )
        ) { error in
            XCTAssertEqual(
                error as? ExerciseCatalogError,
                .duplicateName("incline   DUMBBELL press")
            )
        }
    }

    func testMakeExerciseRejectsEmptyNameThroughProductionValidator() {
        XCTAssertThrowsError(
            try ExerciseCatalogService.makeExercise(
                name: "   ",
                primaryMuscle: .back,
                type: .isolation,
                equipment: .cable,
                existingExercises: []
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenLiftValidationError,
                .emptyName(entity: "Exercise")
            )
        }
    }
}
