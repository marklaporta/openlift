import BackgroundTasks
import Foundation
import SwiftData

enum SessionExportService {
    static let backgroundRefreshIdentifier = "com.mark.openlift.export-retry"

    enum ExportWriteError: LocalizedError {
        case missingICloudMirror(filename: String)
        case noWritableDestination(filename: String, errors: [String])

        var errorDescription: String? {
            switch self {
            case .missingICloudMirror(let filename):
                return "Saved locally, but the iCloud export mirror was not written: \(filename)"
            case .noWritableDestination(let filename, let errors):
                let detail = errors.isEmpty ? "No destination was available." : errors.joined(separator: "; ")
                return "Could not write export \(filename). \(detail)"
            }
        }
    }

    @MainActor
    @discardableResult
    static func retryPendingCompletedSessionExports(modelContext: ModelContext) throws -> Int {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let retryableSessions = sessions
            .filter { $0.status == .completed && $0.exportStatus != .success }
            .sorted { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }
        guard !retryableSessions.isEmpty else { return 0 }

        let activeCycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let setEntries = try modelContext.fetch(FetchDescriptor<SetEntry>())

        for session in retryableSessions {
            let cycleName = exportCycleName(
                for: session,
                activeCycles: activeCycles,
                templates: templates
            )
            do {
                try export(
                    session: session,
                    cycleName: cycleName,
                    exercises: exercises,
                    setEntries: setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked },
                    requireICloudMirror: true
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
            }
        }

        try modelContext.save()
        if retryableSessions.contains(where: { $0.exportStatus != .success }) {
            scheduleBackgroundExportRetry()
        }
        return retryableSessions.filter { $0.exportStatus == .success }.count
    }

    @MainActor
    static func hasPendingCompletedSessionExports(modelContext: ModelContext) throws -> Bool {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        return sessions.contains { $0.status == .completed && $0.exportStatus != .success }
    }

    @MainActor
    static func runBackgroundExportRetry(modelContainer: ModelContainer) async {
        let modelContext = ModelContext(modelContainer)
        _ = try? retryPendingCompletedSessionExports(modelContext: modelContext)
        if (try? hasPendingCompletedSessionExports(modelContext: modelContext)) == true {
            scheduleBackgroundExportRetry()
        }
    }

    static func scheduleBackgroundExportRetry(after interval: TimeInterval = 15 * 60) {
        guard !AppRuntime.isUITesting else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseExportDate(_ value: String) -> Date? {
        iso8601Formatter.date(from: value) ?? fractionalISO8601Formatter.date(from: value)
    }

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

    struct OffScheduleImportSet: Codable {
        let set_index: Int?
        let weight: Double
        let reps: Int
    }

    struct OffScheduleImportExercise: Codable {
        let exercise_name: String?
        let name: String?
        let muscle: String?
        let sets: [OffScheduleImportSet]
    }

    struct OffScheduleImportPayload: Codable {
        let session_id: String?
        let cycle_name: String?
        let cycle_day_index: Int?
        let date: String
        let exercises: [OffScheduleImportExercise]
    }

    static func decodeExportPayload(data: Data, fileURL: URL? = nil) -> ExportPayload? {
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(ExportPayload.self, from: data) {
            return payload
        }

        guard let importPayload = try? decoder.decode(OffScheduleImportPayload.self, from: data) else {
            return nil
        }

        let normalizedExercises: [ExportExercise] = importPayload.exercises.compactMap { exercise in
            let name = (exercise.exercise_name ?? exercise.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let sets = exercise.sets.enumerated().compactMap { index, set -> ExportSet? in
                guard set.reps > 0, set.weight >= 0 else { return nil }
                return ExportSet(set_index: set.set_index ?? index + 1, weight: set.weight, reps: set.reps)
            }
            guard !sets.isEmpty else { return nil }
            return ExportExercise(
                exercise_name: name,
                muscle: exercise.muscle ?? "unknown",
                sets: sets
            )
        }

        guard !normalizedExercises.isEmpty else { return nil }

        let seed = fileURL?.lastPathComponent ?? importPayload.date + normalizedExercises.map(\.exercise_name).joined(separator: "|")
        return ExportPayload(
            session_id: importPayload.session_id ?? deterministicUUIDString(seed: seed),
            cycle_name: importPayload.cycle_name ?? "Off-Schedule",
            cycle_day_index: max(importPayload.cycle_day_index ?? 0, 0),
            date: importPayload.date,
            exercises: normalizedExercises
        )
    }

    private static func deterministicUUIDString(seed: String) -> String {
        var bytes = Array<UInt8>(repeating: 0, count: 16)
        for (index, byte) in seed.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
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
        setEntries: [SetEntry],
        requireICloudMirror: Bool = false
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
        try writeExportData(
            data: data,
            relativeSubdirectory: "exports",
            filename: filename,
            requireICloudMirror: requireICloudMirror
        )
    }

    static func deleteDraftSnapshot(sessionId: UUID) {
        let filename = "draft-\(sessionId.uuidString).json"
        let candidates: [URL] = [
            iCloudContainerURL().map {
                $0.appendingPathComponent("Documents/OpenLift/exports/drafts/\(filename)")
            },
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.map {
                $0.appendingPathComponent("OpenLift/exports/drafts/\(filename)")
            }
        ].compactMap { $0 }
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
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
        try writeExportData(
            data: data,
            relativeSubdirectory: "exports/drafts",
            filename: filename,
            requireICloudMirror: false
        )
    }

    private static func writeExportData(
        data: Data,
        relativeSubdirectory: String,
        filename: String,
        requireICloudMirror: Bool
    ) throws {
        var writeErrors: [String] = []
        var didWriteICloud = false
        var didWriteLocal = false

        if let iCloudURL = iCloudContainerURL() {
            do {
                let exportDir = iCloudURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("OpenLift", isDirectory: true)
                    .appendingPathComponent(relativeSubdirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
                let destination = exportDir.appendingPathComponent(filename)
                try coordinatedWrite(data: data, to: destination)
                guard FileManager.default.fileExists(atPath: destination.path),
                      (try? Data(contentsOf: destination)) == data else {
                    throw CocoaError(.fileNoSuchFile)
                }
                didWriteICloud = true
            } catch {
                writeErrors.append("iCloud: \(error.localizedDescription)")
            }
        } else {
            writeErrors.append("iCloud: container unavailable")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localDocumentsDir = docs
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent(relativeSubdirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: localDocumentsDir, withIntermediateDirectories: true)
            let destination = localDocumentsDir.appendingPathComponent(filename)
            try data.write(to: destination, options: [.atomic])
            guard FileManager.default.fileExists(atPath: destination.path),
                  (try? Data(contentsOf: destination)) == data else {
                throw CocoaError(.fileNoSuchFile)
            }
            didWriteLocal = true
        } catch {
            writeErrors.append("local documents: \(error.localizedDescription)")
        }

        if requireICloudMirror && !didWriteICloud {
            throw ExportWriteError.missingICloudMirror(filename: filename)
        }

        if !didWriteICloud && !didWriteLocal {
            throw ExportWriteError.noWritableDestination(filename: filename, errors: writeErrors)
        }
    }

    private static func iCloudContainerURL() -> URL? {
        if let configuredIdentifier = Bundle.main.object(forInfoDictionaryKey: "OpenLiftICloudContainerIdentifier") as? String,
           !configuredIdentifier.isEmpty,
           !configuredIdentifier.contains("$("),
           let configuredURL = FileManager.default.url(forUbiquityContainerIdentifier: configuredIdentifier) {
            return configuredURL
        }
        return FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    private static func coordinatedWrite(data: Data, to destination: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }

        if let writeError {
            throw writeError
        }
        if let coordinatorError {
            throw coordinatorError
        }
    }

    private static func exportCycleName(
        for session: Session,
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate]
    ) -> String {
        if let snapshot = session.cycleNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snapshot.isEmpty {
            return snapshot
        }
        if let cycle = activeCycles.first(where: { $0.id == session.cycleInstanceId }),
           let template = templates.first(where: { $0.id == cycle.templateId }) {
            return template.name
        }
        return "OpenLift"
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
