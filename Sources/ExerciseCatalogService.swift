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

        if CSDBRowIdentity.resolve(id: nil, name: trimmedName, exercises: existingExercises) != nil {
            throw ExerciseCatalogError.duplicateName(CSDBRowIdentity.name)
        }
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

/// User-confirmed equivalents. Old catalog rows remain inactive so frozen
/// exports, occurrences, profiles and set IDs retain their original evidence.
enum CSDBRowIdentity {
    static let canonicalID = UUID(uuidString: "3122AC62-0E70-467F-AFA8-B890D6B334D1")!
    static let legacyIDs: Set<UUID> = [
        UUID(uuidString: "45F7D9A2-52D5-4172-ACE7-78AEB5BF2C6F")!,
        UUID(uuidString: "7C799565-C77C-4332-B5C8-F70EC9BC6B49")!
    ]
    static let name = "CS DB Row"
    static let marker = "exercise-consolidation-cs-db-row-2026-09-17"
    static let names = ["CS DB Row", "Helms Row", "Chest Supported Row", "Chest-Supported Dumbbell Row", "CS Dumbbell Row", "Chest Supported DB Row"]

    static func matches(_ name: String) -> Bool {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return names.contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == key }
    }

    static func canonical(in exercises: [Exercise]) -> Exercise? {
        exercises.first { $0.id == canonicalID && $0.name == name && $0.isActive }
    }

    static func resolve(id: UUID?, name: String?, exercises: [Exercise]) -> Exercise? {
        guard let canonical = canonical(in: exercises),
              id == canonicalID || id.map(legacyIDs.contains) == true || name.map(matches) == true else { return nil }
        return canonical
    }

    static func historicalIDs(for id: UUID, exercises: [Exercise]) -> Set<UUID> {
        guard canonical(in: exercises) != nil, id == canonicalID || legacyIDs.contains(id) else { return [id] }
        return legacyIDs.union([canonicalID])
    }
}
