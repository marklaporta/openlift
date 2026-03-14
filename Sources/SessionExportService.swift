import Foundation

enum SessionExportService {
    struct ExportSet: Codable {
        let set_index: Int
        let weight: Double
        let reps: Int
    }

    struct ExportExercise: Codable {
        let exercise_name: String
        let muscle: String
        let sets: [ExportSet]
    }

    struct ExportPayload: Codable {
        let session_id: String
        let cycle_name: String
        let cycle_day_index: Int
        let date: String
        let exercises: [ExportExercise]
    }

    struct ExerciseSnapshot: Sendable {
        let id: UUID
        let name: String
        let muscle: String
    }

    struct SetEntrySnapshot: Sendable {
        let exerciseId: UUID
        let setIndex: Int
        let weight: Double
        let reps: Int
    }

    struct DraftSnapshot: Sendable {
        let sessionId: UUID
        let cycleName: String
        let cycleDayIndex: Int
        let date: Date
        let exercises: [ExerciseSnapshot]
        let entries: [SetEntrySnapshot]
    }

    static func export(
        session: Session,
        cycleName: String,
        exercises: [Exercise],
        setEntries: [SetEntry]
    ) throws {
        let loggedEntries = setEntries.filter { $0.reps > 0 }
        let grouped = Dictionary(grouping: loggedEntries, by: { $0.exerciseId })

        let exportExercises: [ExportExercise] = grouped.compactMap { exerciseId, entries in
            guard let ex = exercises.first(where: { $0.id == exerciseId }) else { return nil }
            let sets = entries
                .sorted { $0.setIndex < $1.setIndex }
                .map { ExportSet(set_index: $0.setIndex, weight: $0.weight, reps: $0.reps) }
            return ExportExercise(exercise_name: ex.name, muscle: ex.primaryMuscle.rawValue, sets: sets)
        }
        .sorted { $0.exercise_name < $1.exercise_name }

        let payload = ExportPayload(
            session_id: session.id.uuidString,
            cycle_name: cycleName,
            cycle_day_index: session.cycleDayIndex,
            date: ISO8601DateFormatter().string(from: session.finishedAt ?? .now),
            exercises: exportExercises
        )

        let data = try JSONEncoder.pretty.encode(payload)
        let filename = "workout-\(filenameDateFormatter.string(from: session.finishedAt ?? .now)).json"
        try writeExportData(data: data, relativeSubdirectory: "exports", filename: filename)
    }

    static func exportDraftSnapshot(snapshot: DraftSnapshot) throws {
        let exerciseById = Dictionary(uniqueKeysWithValues: snapshot.exercises.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: snapshot.entries, by: \.exerciseId)

        let exportExercises: [ExportExercise] = grouped.compactMap { exerciseId, entries in
            guard let exercise = exerciseById[exerciseId] else { return nil }
            let sets = entries
                .sorted { $0.setIndex < $1.setIndex }
                .map { ExportSet(set_index: $0.setIndex, weight: $0.weight, reps: $0.reps) }
            return ExportExercise(
                exercise_name: exercise.name,
                muscle: exercise.muscle,
                sets: sets
            )
        }
        .sorted { $0.exercise_name < $1.exercise_name }

        let payload = ExportPayload(
            session_id: snapshot.sessionId.uuidString,
            cycle_name: snapshot.cycleName,
            cycle_day_index: snapshot.cycleDayIndex,
            date: ISO8601DateFormatter().string(from: snapshot.date),
            exercises: exportExercises
        )

        let data = try JSONEncoder.pretty.encode(payload)
        let filename = "draft-\(snapshot.sessionId.uuidString).json"
        try writeExportData(data: data, relativeSubdirectory: "exports/drafts", filename: filename)
    }

    private static func writeExportData(
        data: Data,
        relativeSubdirectory: String,
        filename: String
    ) throws {
        var iCloudWriteError: Error?
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            do {
                let exportDir = iCloudURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("OpenLift", isDirectory: true)
                    .appendingPathComponent(relativeSubdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
                try data.write(to: exportDir.appendingPathComponent(filename), options: [.atomic])
                return
            } catch {
                iCloudWriteError = error
            }
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fallbackDir = docs
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent(relativeSubdirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            try data.write(to: fallbackDir.appendingPathComponent(filename), options: [.atomic])
        } catch {
            if let iCloudWriteError {
                throw iCloudWriteError
            }
            throw error
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
