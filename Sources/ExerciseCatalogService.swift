import Foundation

enum ExerciseCatalogError: LocalizedError, Equatable {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return "An exercise named ‘\(name)’ already exists. Select the existing exercise instead."
        }
    }
}

enum ExerciseCatalogService {
    static func makeExercise(
        name: String,
        primaryMuscle: MuscleGroup,
        type: ExerciseType,
        equipment: EquipmentType,
        existingExercises: [Exercise]
    ) throws -> Exercise {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = normalizedExerciseName(trimmedName)

        if existingExercises.contains(where: { normalizedExerciseName($0.name) == normalizedName }) {
            throw ExerciseCatalogError.duplicateName(trimmedName)
        }

        let exercise = Exercise(
            name: trimmedName,
            primaryMuscle: primaryMuscle,
            type: type,
            equipment: equipment
        )
        try exercise.validate()
        return exercise
    }

    static func normalizedExerciseName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
