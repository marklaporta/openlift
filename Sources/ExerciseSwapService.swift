import Foundation

enum ExerciseSwapService {
    static func initialMuscleSelection(
        currentExercise: Exercise?,
        slotMuscle: MuscleGroup
    ) -> MuscleGroup {
        currentExercise?.primaryMuscle ?? slotMuscle
    }

    static func swapCandidates(
        exercises: [Exercise],
        selectedMuscle: MuscleGroup,
        currentExerciseId: UUID
    ) -> [Exercise] {
        exercises
            .filter {
                $0.isActive &&
                $0.primaryMuscle == selectedMuscle &&
                $0.id != currentExerciseId
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
