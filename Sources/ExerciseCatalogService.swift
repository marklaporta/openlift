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

extension CSDBRowIdentity {
    /// Per-exercise history sheets keep each original identity/occurrence's
    /// rows and resistance profile separate while sharing the canonical title.
    static func historyEfforts(for exerciseID: UUID, exercises: [Exercise], sessions: [Session],
        entries: [SetEntry], adaptiveSessions: [AdaptiveWorkoutSession], adaptiveEntries: [AdaptiveSetEntry],
        profiles: [ExerciseResistanceProfile]
    ) -> [ExerciseEffort]? {
        guard resolve(id: exerciseID, name: nil, exercises: exercises) != nil else { return nil }
        let ids = historicalIDs(for: exerciseID, exercises: exercises)
        var result: [ExerciseEffort] = []
        for session in sessions where session.status == .completed || session.finishedAt != nil || session.exportStatus == .success {
            let groups = Dictionary(grouping: entries.filter { $0.sessionId == session.id && ids.contains($0.exerciseId) && $0.isLocked && $0.reps > 0 }, by: \.exerciseId)
            for (id, rows) in groups {
                result.append(ExerciseEffort(id: "\(session.id.uuidString)|\(id.uuidString)",
                    date: session.finishedAt ?? session.createdAt, cycleName: session.cycleNameSnapshot ?? "Rotation",
                    dayLabel: session.dayLabelSnapshot ?? "Workout",
                    resistanceProfile: profiles.first { $0.sessionId == session.id && $0.exerciseId == id }.flatMap(ResistanceProfileService.value),
                    sets: rows.sorted { $0.setIndex < $1.setIndex }.map { ExerciseEffortSet(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps) }))
            }
        }
        for session in adaptiveSessions where session.status == .completed {
            let groups = Dictionary(grouping: adaptiveEntries.filter { $0.adaptiveSessionId == session.id && ids.contains($0.exerciseId) && $0.isLocked && $0.reps > 0 }, by: \.occurrenceId)
            for (occurrenceID, rows) in groups {
                guard let id = rows.first?.exerciseId else { continue }
                result.append(ExerciseEffort(id: "\(session.id.uuidString)|\(occurrenceID.uuidString)",
                    date: session.finishedAt ?? session.createdAt, cycleName: "Adaptive Floating", dayLabel: "Workout",
                    resistanceProfile: profiles.first { $0.sessionId == session.id && $0.exerciseId == id && $0.occurrenceId == occurrenceID }.flatMap(ResistanceProfileService.value),
                    sets: rows.sorted { $0.setIndex < $1.setIndex }.map { ExerciseEffortSet(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps) }))
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
