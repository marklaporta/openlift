import XCTest
@testable import OpenLift

final class ExerciseSwapServiceTests: XCTestCase {
    func testInitialMuscleSelectionUsesCurrentExerciseMuscleWhenAvailable() {
        let currentExercise = Exercise(
            name: "Cable Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .cable
        )

        let selected = ExerciseSwapService.initialMuscleSelection(
            currentExercise: currentExercise,
            slotMuscle: .back
        )

        XCTAssertEqual(selected, .biceps)
    }

    func testInitialMuscleSelectionFallsBackToSlotMuscle() {
        let selected = ExerciseSwapService.initialMuscleSelection(
            currentExercise: nil,
            slotMuscle: .triceps
        )

        XCTAssertEqual(selected, .triceps)
    }

    func testSwapCandidatesFiltersBySelectedMuscleAndExcludesInactiveAndCurrentExercise() {
        let currentExercise = Exercise(
            name: "Barbell Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .barbell
        )
        let matching = Exercise(
            name: "Chest-Supported Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .machine
        )
        let inactive = Exercise(
            name: "Old Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .machine,
            isActive: false
        )
        let otherMuscle = Exercise(
            name: "Leg Extension",
            primaryMuscle: .quads,
            type: .isolation,
            equipment: .machine
        )

        let candidates = ExerciseSwapService.swapCandidates(
            exercises: [otherMuscle, inactive, matching, currentExercise],
            selectedMuscle: .back,
            currentExerciseId: currentExercise.id
        )

        XCTAssertEqual(candidates.map(\.name), ["Chest-Supported Row"])
    }

    func testSwapCandidatesSortsNamesCaseInsensitively() {
        let currentExercise = Exercise(
            name: "Barbell Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .barbell
        )
        let zExercise = Exercise(
            name: "zottman Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .dumbbell
        )
        let aExercise = Exercise(
            name: "Alternating Dumbbell Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .dumbbell
        )

        let candidates = ExerciseSwapService.swapCandidates(
            exercises: [zExercise, currentExercise, aExercise],
            selectedMuscle: .biceps,
            currentExerciseId: currentExercise.id
        )

        XCTAssertEqual(candidates.map(\.name), ["Alternating Dumbbell Curl", "zottman Curl"])
    }
}
