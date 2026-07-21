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
        let activeCycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let setEntries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        let adHocFeedback = try modelContext.fetch(FetchDescriptor<AdHocExerciseFeedback>())

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
                    requireICloudMirror: true,
                    adHocFeedback: adHocFeedback.filter { $0.sessionId == session.id }
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
            }
        }

        let adaptiveSuccessCount = try AdaptiveExportService.retryPendingExports(modelContext: modelContext)
        try modelContext.save()
        if (try? hasPendingCompletedSessionExports(modelContext: modelContext)) == true {
            scheduleBackgroundExportRetry()
        }
        return retryableSessions.filter { $0.exportStatus == .success }.count + adaptiveSuccessCount
    }

    @MainActor
    static func hasPendingCompletedSessionExports(modelContext: ModelContext) throws -> Bool {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let adaptiveSessions = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        return sessions.contains { $0.status == .completed && $0.exportStatus != .success }
            || adaptiveSessions.contains { $0.status == .completed && $0.exportStatus != .success }
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
        let volume_feedback: String?

        init(
            exercise_name: String,
            muscle: String,
            sets: [ExportSet],
            volume_feedback: String? = nil
        ) {
            self.exercise_name = exercise_name
            self.muscle = muscle
            self.sets = sets
            self.volume_feedback = volume_feedback
        }
    }

    struct ExportPayload: Codable {
        let session_id: String
        let cycle_name: String
        let cycle_day_index: Int
        let date: String
        let exercises: [ExportExercise]
        let workout_kind: String?

        init(
            session_id: String,
            cycle_name: String,
            cycle_day_index: Int,
            date: String,
            exercises: [ExportExercise],
            workout_kind: String? = nil
        ) {
            self.session_id = session_id
            self.cycle_name = cycle_name
            self.cycle_day_index = cycle_day_index
            self.date = date
            self.exercises = exercises
            self.workout_kind = workout_kind
        }
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
            exercises: normalizedExercises,
            workout_kind: "ad_hoc"
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
        requireICloudMirror: Bool = false,
        adHocFeedback: [AdHocExerciseFeedback] = []
    ) throws {
        let loggedEntries = setEntries.filter { $0.reps > 0 }
        let grouped = Dictionary(grouping: loggedEntries, by: { $0.exerciseId })

        let exportExercises: [ExportExercise] = grouped.compactMap { exerciseId, entries in
            guard let ex = exercises.first(where: { $0.id == exerciseId }) else { return nil }
            let sets = entries
                .sorted { $0.setIndex < $1.setIndex }
                .map { ExportSet(set_index: $0.setIndex, weight: $0.weight, reps: $0.reps) }
            return ExportExercise(
                exercise_name: ex.name,
                muscle: ex.primaryMuscle.rawValue,
                sets: sets,
                volume_feedback: adHocFeedback
                    .filter { $0.sessionId == session.id && $0.exerciseId == exerciseId }
                    .max(by: { $0.createdAt < $1.createdAt })?
                    .rating.rawValue
            )
        }
        .sorted { $0.exercise_name < $1.exercise_name }

        let payload = ExportPayload(
            session_id: session.id.uuidString,
            cycle_name: cycleName,
            cycle_day_index: session.cycleDayIndex,
            date: ISO8601DateFormatter().string(from: session.finishedAt ?? .now),
            exercises: exportExercises,
            workout_kind: session.dayLabelSnapshot == "Off-Schedule" ? "ad_hoc" : "rotation"
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
            exercises: exportExercises,
            workout_kind: "rotation"
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

    static func writeExportData(
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

enum AdaptiveExportService {
    struct ReadinessResponseV2: Codable, Equatable {
        let muscle: String
        let soreness: String
        let connective_tissue_pain: String
        let eagerness: String
    }

    struct ReadinessV2: Codable, Equatable {
        let check_id: String
        let local_date_key: String
        let time_zone_identifier: String
        let revision: Int
        let created_at: String
        let adaptive_program_id: String
        let adaptive_program_version: Int
        let responses: [ReadinessResponseV2]
    }

    struct SetV2: Codable, Equatable {
        let set_entry_id: String
        let set_index: Int
        let exercise_id: String
        let exercise_name: String
        let muscle: String
        let exercise_type: String
        let equipment: String
        let weight: Double
        let reps: Int
        let is_locked: Bool
    }

    struct ExerciseV2: Codable, Equatable {
        let snapshot_id: String
        let occurrence_id: String
        let position: Int
        let exercise_id: String
        let exercise_name: String
        let primary_muscle: String
        let secondary_muscle: String?
        let difficulty: String
        let prescribed_set_count: Int
        let sets: [SetV2]
    }

    struct ComplexV2: Codable, Equatable {
        let snapshot_id: String
        let definition_id: String
        let version: Int
        let position: Int
        let name: String
        let primary_muscle: String
        let reason_codes: [String]
        let exercises: [ExerciseV2]
    }

    struct PlanV2: Codable, Equatable {
        let plan_id: String
        let local_date_key: String
        let time_zone_identifier: String
        let created_at: String
        let frozen_at: String?
        let adaptive_program_id: String
        let adaptive_program_version: Int
        let readiness_check_id: String
        let planner_version: Int
        let reason_codes: [String]
        let complexes: [ComplexV2]
    }

    struct OverrideV2: Codable, Equatable {
        let override_id: String
        let planned_complex_id: String?
        let occurrence_id: String?
        let kind: String
        let muscle: String?
        let original_exercise_id: String?
        let replacement_exercise_id: String?
        let reason_code: String
        let created_at: String
    }

    struct FeedbackV2: Codable, Equatable {
        let feedback_id: String
        let planned_complex_id: String
        let rating: String
        let created_at: String
    }

    struct PayloadV2: Codable, Equatable {
        let schema_version: Int?
        let workout_kind: String?
        let session_id: String
        let date: String
        let readiness: ReadinessV2
        let plan: PlanV2
        let overrides: [OverrideV2]
        let feedback: [FeedbackV2]
    }

    static func makePayload(
        plan: GeneratedWorkoutPlan,
        session: AdaptiveWorkoutSession,
        readiness: DailyReadinessCheck,
        setEntries: [AdaptiveSetEntry],
        exercises: [Exercise],
        overrides: [AdaptiveOverrideEvent],
        feedback: [ComplexFeedback]
    ) -> PayloadV2 {
        let exerciseById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let iso = ISO8601DateFormatter()
        let complexes = plan.complexes.sorted { $0.position < $1.position }.map { complex in
            ComplexV2(
                snapshot_id: complex.id.uuidString,
                definition_id: complex.sourceDefinitionId.uuidString,
                version: complex.sourceVersion,
                position: complex.position,
                name: complex.name,
                primary_muscle: complex.primaryMuscle.rawValue,
                reason_codes: complex.reasonCodes,
                exercises: complex.exercises.sorted { $0.position < $1.position }.map { snapshot in
                    let rows = setEntries
                        .filter {
                            $0.adaptiveSessionId == session.id
                                && $0.occurrenceId == snapshot.occurrenceId
                                && $0.isLocked
                                && $0.reps > 0
                        }
                        .sorted { $0.setIndex < $1.setIndex }
                        .map { row -> SetV2 in
                            let actual = exerciseById[row.exerciseId]
                            return SetV2(
                                set_entry_id: row.id.uuidString,
                                set_index: row.setIndex,
                                exercise_id: row.exerciseId.uuidString,
                                exercise_name: actual?.name ?? snapshot.exerciseName,
                                muscle: (actual?.primaryMuscle ?? snapshot.primaryMuscle).rawValue,
                                exercise_type: (actual?.type ?? .isolation).rawValue,
                                equipment: (actual?.equipment ?? .cable).rawValue,
                                weight: row.weight,
                                reps: row.reps,
                                is_locked: row.isLocked
                            )
                        }
                    return ExerciseV2(
                        snapshot_id: snapshot.id.uuidString,
                        occurrence_id: snapshot.occurrenceId.uuidString,
                        position: snapshot.position,
                        exercise_id: snapshot.exerciseId.uuidString,
                        exercise_name: snapshot.exerciseName,
                        primary_muscle: snapshot.primaryMuscle.rawValue,
                        secondary_muscle: snapshot.secondaryMuscle?.rawValue,
                        difficulty: snapshot.difficulty.rawValue,
                        prescribed_set_count: snapshot.prescribedSetCount,
                        sets: rows
                    )
                }
            )
        }
        return PayloadV2(
            schema_version: 2,
            workout_kind: "adaptive",
            session_id: session.id.uuidString,
            date: iso.string(from: session.finishedAt ?? .now),
            readiness: ReadinessV2(
                check_id: readiness.id.uuidString,
                local_date_key: readiness.localDateKey,
                time_zone_identifier: readiness.timeZoneIdentifier,
                revision: readiness.revision,
                created_at: iso.string(from: readiness.createdAt),
                adaptive_program_id: readiness.adaptiveProgramId.uuidString,
                adaptive_program_version: readiness.adaptiveProgramVersion,
                responses: readiness.responses.sorted { $0.muscle.rawValue < $1.muscle.rawValue }.map {
                    ReadinessResponseV2(
                        muscle: $0.muscle.rawValue,
                        soreness: $0.soreness.rawValue,
                        connective_tissue_pain: $0.connectiveTissuePain.rawValue,
                        eagerness: $0.eagerness.rawValue
                    )
                }
            ),
            plan: PlanV2(
                plan_id: plan.id.uuidString,
                local_date_key: plan.localDateKey,
                time_zone_identifier: plan.timeZoneIdentifier,
                created_at: iso.string(from: plan.createdAt),
                frozen_at: plan.frozenAt.map(iso.string),
                adaptive_program_id: plan.adaptiveProgramId.uuidString,
                adaptive_program_version: plan.adaptiveProgramVersion,
                readiness_check_id: plan.readinessCheckId.uuidString,
                planner_version: plan.plannerVersion,
                reason_codes: plan.reasonCodes,
                complexes: complexes
            ),
            overrides: overrides.filter { $0.generatedPlanId == plan.id }.map {
                OverrideV2(
                    override_id: $0.id.uuidString,
                    planned_complex_id: $0.plannedComplexId?.uuidString,
                    occurrence_id: $0.occurrenceId?.uuidString,
                    kind: $0.kind.rawValue,
                    muscle: $0.muscle?.rawValue,
                    original_exercise_id: $0.originalExerciseId?.uuidString,
                    replacement_exercise_id: $0.replacementExerciseId?.uuidString,
                    reason_code: $0.reasonCode,
                    created_at: iso.string(from: $0.createdAt)
                )
            },
            feedback: feedback.filter { $0.generatedPlanId == plan.id }.map {
                FeedbackV2(
                    feedback_id: $0.id.uuidString,
                    planned_complex_id: $0.plannedComplexId.uuidString,
                    rating: $0.rating.rawValue,
                    created_at: iso.string(from: $0.createdAt)
                )
            }
        )
    }

    static func encode(_ payload: PayloadV2) throws -> Data {
        try JSONEncoder.pretty.encode(payload)
    }

    static func decode(_ data: Data) -> PayloadV2? {
        guard let payload = try? JSONDecoder().decode(PayloadV2.self, from: data),
              payload.schema_version == 2,
              payload.workout_kind == "adaptive" else { return nil }
        return payload
    }

    static func export(
        plan: GeneratedWorkoutPlan,
        session: AdaptiveWorkoutSession,
        readiness: DailyReadinessCheck,
        setEntries: [AdaptiveSetEntry],
        exercises: [Exercise],
        overrides: [AdaptiveOverrideEvent],
        feedback: [ComplexFeedback],
        requireICloudMirror: Bool = false
    ) throws {
        let payload = makePayload(
            plan: plan,
            session: session,
            readiness: readiness,
            setEntries: setEntries,
            exercises: exercises,
            overrides: overrides,
            feedback: feedback
        )
        let data = try encode(payload)
        let stamp = exportFilenameDateFormatter.string(from: session.finishedAt ?? .now)
        try SessionExportService.writeExportData(
            data: data,
            relativeSubdirectory: "exports",
            filename: "workout-\(stamp)-\(session.id.uuidString).json",
            requireICloudMirror: requireICloudMirror
        )
    }

    @MainActor
    static func retryPendingExports(modelContext: ModelContext) throws -> Int {
        let sessions = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
            .filter { $0.status == .completed && $0.exportStatus != .success }
        guard !sessions.isEmpty else { return 0 }
        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        let checks = try modelContext.fetch(FetchDescriptor<DailyReadinessCheck>())
        let entries = try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let overrides = try modelContext.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        let feedback = try modelContext.fetch(FetchDescriptor<ComplexFeedback>())
        for session in sessions {
            guard let plan = plans.first(where: { $0.id == session.generatedPlanId }),
                  let check = checks.first(where: { $0.id == plan.readinessCheckId }) else {
                session.exportStatus = .failed
                continue
            }
            do {
                try export(
                    plan: plan,
                    session: session,
                    readiness: check,
                    setEntries: entries,
                    exercises: exercises,
                    overrides: overrides,
                    feedback: feedback,
                    requireICloudMirror: true
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
            }
        }
        return sessions.filter { $0.exportStatus == .success }.count
    }

    static func loadPayloads() -> [PayloadV2] {
        let fileManager = FileManager.default
        var directories: [URL] = []
        if let iCloud = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/OpenLift/exports", isDirectory: true) {
            directories.append(iCloud)
        }
        if let local = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(local)
        }
        var found: [PayloadV2] = []
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("workout-") {
                guard let data = try? Data(contentsOf: file), let payload = decode(data) else { continue }
                found.append(payload)
            }
        }
        return Dictionary(grouping: found, by: \.session_id).compactMap { _, copies in copies.first }
    }

    @MainActor
    @discardableResult
    static func hydrateAvailableExports(modelContext: ModelContext) throws -> Int {
        var count = 0
        for payload in loadPayloads() {
            if try hydrate(payload, modelContext: modelContext) { count += 1 }
        }
        return count
    }

    @MainActor
    @discardableResult
    static func hydrate(
        _ payload: PayloadV2,
        modelContext: ModelContext
    ) throws -> Bool {
        guard let sessionId = UUID(uuidString: payload.session_id),
              let planId = UUID(uuidString: payload.plan.plan_id),
              let checkId = UUID(uuidString: payload.readiness.check_id),
              let programId = UUID(uuidString: payload.plan.adaptive_program_id),
              let finishedAt = SessionExportService.parseExportDate(payload.date) else { return false }
        let existing = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        guard !existing.contains(where: { $0.id == sessionId }) else { return false }

        let currentExercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        var exerciseById = Dictionary(uniqueKeysWithValues: currentExercises.map { ($0.id, $0) })
        var exerciseByName = Dictionary(uniqueKeysWithValues: currentExercises.map { ($0.name.lowercased(), $0) })
        func resolvedExercise(_ set: SetV2) -> Exercise? {
            guard let exportedId = UUID(uuidString: set.exercise_id),
                  let muscle = MuscleGroup(rawValue: set.muscle) else { return nil }
            if let found = exerciseById[exportedId] { return found }
            if let found = exerciseByName[set.exercise_name.lowercased()] { return found }
            let created = Exercise(
                id: exportedId,
                name: set.exercise_name,
                primaryMuscle: muscle,
                type: ExerciseType(rawValue: set.exercise_type) ?? .isolation,
                equipment: EquipmentType(rawValue: set.equipment) ?? .cable
            )
            modelContext.insert(created)
            exerciseById[created.id] = created
            exerciseByName[created.name.lowercased()] = created
            return created
        }

        let responses = payload.readiness.responses.compactMap { response -> AdaptiveReadinessResponse? in
            guard let muscle = MuscleGroup(rawValue: response.muscle),
                  let soreness = SorenessLevel(rawValue: response.soreness),
                  let pain = ConnectiveTissuePainLevel(rawValue: response.connective_tissue_pain),
                  let eagerness = EagernessLevel(rawValue: response.eagerness) else { return nil }
            return AdaptiveReadinessResponse(
                muscle: muscle,
                soreness: soreness,
                connectiveTissuePain: pain,
                eagerness: eagerness
            )
        }
        guard responses.count == payload.readiness.responses.count else { return false }
        let check = DailyReadinessCheck(
            id: checkId,
            localDateKey: payload.readiness.local_date_key,
            timeZoneIdentifier: payload.readiness.time_zone_identifier,
            revision: payload.readiness.revision,
            createdAt: SessionExportService.parseExportDate(payload.readiness.created_at) ?? finishedAt,
            adaptiveProgramId: UUID(uuidString: payload.readiness.adaptive_program_id) ?? programId,
            adaptiveProgramVersion: payload.readiness.adaptive_program_version,
            responses: responses
        )
        modelContext.insert(check)

        var recoveredEntries: [AdaptiveSetEntry] = []
        let complexes = payload.plan.complexes.sorted { $0.position < $1.position }.compactMap { item -> PlannedComplexSnapshot? in
            guard let snapshotId = UUID(uuidString: item.snapshot_id),
                  let definitionId = UUID(uuidString: item.definition_id),
                  let muscle = MuscleGroup(rawValue: item.primary_muscle) else { return nil }
            let exerciseSnapshots = item.exercises.sorted { $0.position < $1.position }.compactMap { exercise -> PlannedExerciseSnapshot? in
                guard let snapshotId = UUID(uuidString: exercise.snapshot_id),
                      let occurrenceId = UUID(uuidString: exercise.occurrence_id),
                      let exportedExerciseId = UUID(uuidString: exercise.exercise_id),
                      let primary = MuscleGroup(rawValue: exercise.primary_muscle),
                      let difficulty = MovementDifficulty(rawValue: exercise.difficulty) else { return nil }
                var localExerciseId = exerciseById[exportedExerciseId]?.id
                for row in exercise.sets {
                    guard let actual = resolvedExercise(row),
                          let rowId = UUID(uuidString: row.set_entry_id) else { continue }
                    localExerciseId = localExerciseId ?? actual.id
                    recoveredEntries.append(
                        AdaptiveSetEntry(
                            id: rowId,
                            adaptiveSessionId: sessionId,
                            occurrenceId: occurrenceId,
                            exerciseId: actual.id,
                            setIndex: row.set_index,
                            weight: row.weight,
                            reps: row.reps,
                            isLocked: row.is_locked
                        )
                    )
                }
                return PlannedExerciseSnapshot(
                    id: snapshotId,
                    occurrenceId: occurrenceId,
                    position: exercise.position,
                    exerciseId: localExerciseId ?? exportedExerciseId,
                    exerciseName: exercise.exercise_name,
                    primaryMuscle: primary,
                    secondaryMuscle: exercise.secondary_muscle.flatMap(MuscleGroup.init(rawValue:)),
                    difficulty: difficulty,
                    prescribedSetCount: exercise.prescribed_set_count
                )
            }
            guard exerciseSnapshots.count == item.exercises.count else { return nil }
            return PlannedComplexSnapshot(
                id: snapshotId,
                sourceDefinitionId: definitionId,
                sourceVersion: item.version,
                position: item.position,
                name: item.name,
                primaryMuscle: muscle,
                reasonCodes: item.reason_codes,
                exercises: exerciseSnapshots
            )
        }
        guard complexes.count == payload.plan.complexes.count else { return false }
        let plan = GeneratedWorkoutPlan(
            id: planId,
            localDateKey: payload.plan.local_date_key,
            timeZoneIdentifier: payload.plan.time_zone_identifier,
            createdAt: SessionExportService.parseExportDate(payload.plan.created_at) ?? finishedAt,
            frozenAt: payload.plan.frozen_at.flatMap(SessionExportService.parseExportDate),
            status: .completed,
            adaptiveProgramId: programId,
            adaptiveProgramVersion: payload.plan.adaptive_program_version,
            readinessCheckId: checkId,
            plannerVersion: payload.plan.planner_version,
            reasonCodes: payload.plan.reason_codes,
            sessionId: sessionId,
            complexes: complexes
        )
        modelContext.insert(plan)
        modelContext.insert(
            AdaptiveWorkoutSession(
                id: sessionId,
                generatedPlanId: planId,
                createdAt: SessionExportService.parseExportDate(payload.plan.created_at) ?? finishedAt,
                finishedAt: finishedAt,
                status: .completed,
                exportStatus: .success
            )
        )
        recoveredEntries.forEach(modelContext.insert)
        for item in payload.overrides {
            guard let id = UUID(uuidString: item.override_id),
                  let kind = AdaptiveOverrideKind(rawValue: item.kind) else { continue }
            modelContext.insert(
                AdaptiveOverrideEvent(
                    id: id,
                    generatedPlanId: planId,
                    plannedComplexId: item.planned_complex_id.flatMap(UUID.init(uuidString:)),
                    occurrenceId: item.occurrence_id.flatMap(UUID.init(uuidString:)),
                    kind: kind,
                    muscle: item.muscle.flatMap(MuscleGroup.init(rawValue:)),
                    originalExerciseId: item.original_exercise_id.flatMap(UUID.init(uuidString:)),
                    replacementExerciseId: item.replacement_exercise_id.flatMap(UUID.init(uuidString:)),
                    reasonCode: item.reason_code,
                    createdAt: SessionExportService.parseExportDate(item.created_at) ?? finishedAt
                )
            )
        }
        for item in payload.feedback {
            guard let id = UUID(uuidString: item.feedback_id),
                  let complexId = UUID(uuidString: item.planned_complex_id),
                  let rating = ComplexFeedbackRating(rawValue: item.rating) else { continue }
            modelContext.insert(
                ComplexFeedback(
                    id: id,
                    generatedPlanId: planId,
                    plannedComplexId: complexId,
                    rating: rating,
                    createdAt: SessionExportService.parseExportDate(item.created_at) ?? finishedAt
                )
            )
        }
        try modelContext.save()
        return true
    }

    private static let exportFilenameDateFormatter: DateFormatter = {
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
