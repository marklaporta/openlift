import Foundation
import SwiftData

enum BootstrapDataService {
    enum August16PullACompletionRepairError: LocalizedError, Equatable {
        case targetSessionNotFound
        case pushAStateMissing
        case unexpectedSessionState
        case unexpectedExistingSets
        case completedRepairStateMissing

        var errorDescription: String? {
            switch self {
            case .targetSessionNotFound:
                return "The completed August 16 Pull A session was not found."
            case .pushAStateMissing:
                return "The marked Push/Pull A/B cycle is not currently advanced to Push A. Refusing to alter workout history."
            case .unexpectedSessionState:
                return "The target Pull A session does not match the reviewed completion state. Refusing to alter it."
            case .unexpectedExistingSets:
                return "The target Pull A set rows do not match the reviewed 12-set manifest. Refusing to alter workout history."
            case .completedRepairStateMissing:
                return "The August 16 completion-date repair is marked complete, but its exact repaired state is missing."
            }
        }
    }

    struct August16PullACompletionRepairResult: Equatable {
        let sessionId: UUID
        let didApply: Bool
    }

    enum July27AdaptiveInclineCurlRepairError: LocalizedError, Equatable {
        case backupConfirmationRequired
        case pushAStateMissing
        case targetSessionNotFound
        case ambiguousTargetSessions(count: Int)
        case inclineCurlExerciseMissing
        case inclineCurlOccurrenceNotFound
        case ambiguousInclineCurlOccurrences(count: Int)
        case unexpectedExistingSets
        case completedRepairStateMissing

        var errorDescription: String? {
            switch self {
            case .backupConfirmationRequired:
                return "A verified backup of the live SQLite store and its WAL/SHM sidecars must be confirmed before repairing the July 27 Adaptive Incline Curl sets."
            case .pushAStateMissing:
                return "The marked Push/Pull A/B Fixed Cycle is not currently active on Push A. Refusing to run the live-data repair."
            case .targetSessionNotFound:
                return "No completed Adaptive session for 2026-07-27 was found."
            case .ambiguousTargetSessions(let count):
                return "Found \(count) completed Adaptive sessions for 2026-07-27. Refusing to choose one."
            case .inclineCurlExerciseMissing:
                return "The Incline Curl exercise is missing or ambiguous in the exercise catalog."
            case .inclineCurlOccurrenceNotFound:
                return "The July 27 Adaptive plan does not contain an Incline Curl occurrence."
            case .ambiguousInclineCurlOccurrences(let count):
                return "The July 27 Adaptive plan contains \(count) Incline Curl occurrences. Refusing to choose one."
            case .unexpectedExistingSets:
                return "The July 27 Incline Curl rows do not match either the known single saved set (20 lb × 13) or the completed repaired state. Refusing to overwrite unexpected workout data."
            case .completedRepairStateMissing:
                return "The one-time July 27 Incline Curl repair is marked complete, but its repaired session or exact set state is missing."
            }
        }
    }

    struct July27AdaptiveInclineCurlRepairResult: Equatable {
        let sessionId: UUID
        let didApply: Bool
    }

    enum PushPullRolloutError: LocalizedError, Equatable {
        case nonEmptyDraft(sessionId: UUID)
        case requiredExerciseMissing(String)
        case completedRolloutStateMissing

        var errorDescription: String? {
            switch self {
            case .nonEmptyDraft(let sessionId):
                return "The current draft \(sessionId.uuidString) contains entered or locked work. Preserve it and resolve that draft before activating Push/Pull A/B."
            case .requiredExerciseMissing(let name):
                return "Required Push/Pull exercise '\(name)' is missing from the catalog."
            case .completedRolloutStateMissing:
                return "The Push/Pull A/B rollout is already marked complete, but its template or cycle is missing. Refusing to recreate it or reset a pointer automatically."
            }
        }
    }

    struct PushPullRolloutResult: Equatable {
        let templateId: UUID
        let cycleId: UUID
        let didApply: Bool
    }

    enum ClusteredProgramRolloutError: LocalizedError, Equatable {
        case nonEmptyDraft(sessionId: UUID)
        case existingTemplateConflict
        case existingRotationStateConflict
        case completedRolloutStateMissing

        var errorDescription: String? {
            switch self {
            case .nonEmptyDraft(let sessionId):
                return "The current draft \(sessionId.uuidString) contains entered or locked work. Resolve it before activating the clustered program."
            case .existingTemplateConflict:
                return "A template named Clustered Hypertrophy v1 already exists with a different structure. Refusing to overwrite it."
            case .existingRotationStateConflict:
                return "Clustered-program recovery contains only part of the three-pointer state. Refusing to guess or replace it."
            case .completedRolloutStateMissing:
                return "The clustered-program rollout marker exists, but its template, cycle, or three independent pointers are incomplete."
            }
        }
    }

    enum ClusteredProgramRecoveryError: LocalizedError, Equatable {
        case occurrenceGap(cycleId: UUID, clusterID: String)
        case occurrenceConflict(cycleId: UUID, clusterID: String, absoluteStep: Int)

        var errorDescription: String? {
            switch self {
            case .occurrenceGap(let cycleId, let clusterID):
                return "Clustered recovery for \(cycleId.uuidString) / \(clusterID) has missing completion evidence. Refusing to guess or rewind its pointer."
            case .occurrenceConflict(let cycleId, let clusterID, let absoluteStep):
                return "Clustered recovery has conflicting completion evidence for \(cycleId.uuidString) / \(clusterID) step \(absoluteStep)."
            }
        }
    }

    struct ClusteredProgramRolloutResult: Equatable {
        let templateId: UUID
        let cycleId: UUID
        let didApply: Bool
    }

    struct WorkoutImportResult {
        var imported = 0
        var skippedExisting = 0
        var skippedUnknownExercises = 0
    }

    private struct ImportedSetKey: Hashable {
        let sessionId: UUID
        let exerciseId: UUID
        let setIndex: Int
    }

    private struct ImportedFeedbackKey: Hashable {
        let sessionId: UUID
        let exerciseId: UUID
    }

    struct DebugSnapshot {
        let exerciseCount: Int
        let templateCount: Int
        let activeCycleCount: Int
        let sessionCount: Int
        let completedSessionCount: Int
        let draftSessionCount: Int
        let latestCompletedDayIndex: Int?
        let latestExportDayIndex: Int?
        let inferredNextDayIndex: Int

        var summary: String {
            """
            exercises=\(exerciseCount), templates=\(templateCount), activeCycles=\(activeCycleCount), sessions=\(sessionCount), completed=\(completedSessionCount), draft=\(draftSessionCount), latestCompletedDay=\(latestCompletedDayIndex.map(String.init) ?? "nil"), latestExportDay=\(latestExportDayIndex.map(String.init) ?? "nil"), inferredNextDay=\(inferredNextDayIndex)
            """
        }
    }

    static func ensureExerciseCatalog(
        modelContext: ModelContext,
        saveChanges: Bool = true
    ) throws -> [Exercise] {
        var currentExercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let currentNames = Set(currentExercises.map { $0.name.lowercased() })
        let defaultsByName = Dictionary(
            uniqueKeysWithValues: defaultExerciseCatalog.map { ($0.0.lowercased(), $0) }
        )

        var changed = false
        for exercise in currentExercises {
            guard let canonical = defaultsByName[exercise.name.lowercased()] else { continue }
            if exercise.primaryMuscle != canonical.1 {
                exercise.primaryMuscle = canonical.1
                changed = true
            }
            if exercise.type != canonical.2 {
                exercise.type = canonical.2
                changed = true
            }
            if exercise.name.caseInsensitiveCompare("Lat Pulldown") == .orderedSame,
               exercise.equipment == .machine {
                exercise.equipment = .cable
                changed = true
            }
        }
        for entry in defaultExerciseCatalog where
            !currentNames.contains(entry.0.lowercased())
                && !currentExercises.contains(where: { satisfiesCatalogAlias($0, for: entry.0) }) {
            let exercise = Exercise(name: entry.0, primaryMuscle: entry.1, type: entry.2, equipment: entry.3)
            modelContext.insert(exercise)
            currentExercises.append(exercise)
            changed = true
        }

        if changed, saveChanges {
            try modelContext.save()
            currentExercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        }

        return currentExercises
    }

    private static func satisfiesCatalogAlias(_ exercise: Exercise, for defaultName: String) -> Bool {
        switch defaultName {
        case "Incline Dumbbell Press-Flye":
            return exercise.name.caseInsensitiveCompare("Incline Press-Flye") == .orderedSame
                && exercise.primaryMuscle == .chest
                && exercise.equipment == .dumbbell
        case "Captains of Crush":
            return exercise.name.caseInsensitiveCompare("Captain of Crush") == .orderedSame
                && exercise.primaryMuscle == .forearms
        default:
            return false
        }
    }

    static func importPreferredPublishedTemplateIfNeeded(
        modelContext: ModelContext,
        existingTemplates: [CycleTemplate],
        exercises: [Exercise]
    ) throws -> CycleTemplate? {
        if AppRuntime.isUITesting { return nil }
        if !existingTemplates.isEmpty { return nil }

        let published = try PublishedCycleService.listPublishedCycles()
        guard !published.isEmpty else { return nil }

        guard let preferred = preferredPublishedCycle(from: published) else { return nil }
        let draft = try PublishedCycleService.parseTemplate(at: preferred.url, exercises: exercises)
        let template = CycleTemplate(name: draft.name, days: draft.days, rotationPools: draft.rotationPools)

        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        try template.validate(exercisesById: exercisesById)

        modelContext.insert(template)
        try modelContext.save()
        return template
    }

    static func ensureDefaultStarterTemplateIfNeeded(
        modelContext: ModelContext,
        existingTemplates: [CycleTemplate],
        exercises: [Exercise]
    ) throws -> CycleTemplate? {
        if !existingTemplates.isEmpty { return nil }

        let template = try defaultStarterTemplate(exercises: exercises)
        modelContext.insert(template)
        try modelContext.save()
        return template
    }

    static func importPublishedTemplateIfNeeded(
        named templateName: String,
        modelContext: ModelContext,
        existingTemplates: [CycleTemplate],
        exercises: [Exercise]
    ) throws -> CycleTemplate? {
        if AppRuntime.isUITesting { return nil }
        if let existing = matchingTemplate(named: templateName, in: existingTemplates) {
            return existing
        }

        let published = try PublishedCycleService.listPublishedCycles()
        guard let match = matchingPublishedCycle(named: templateName, from: published) else { return nil }

        let draft = try PublishedCycleService.parseTemplate(at: match.url, exercises: exercises)
        let template = CycleTemplate(name: draft.name, days: draft.days, rotationPools: draft.rotationPools)
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        try template.validate(exercisesById: exercisesById)

        modelContext.insert(template)
        try modelContext.save()
        return template
    }

    static func preferredPublishedCycle(from published: [PublishedCycleFile]) -> PublishedCycleFile? {
        guard !published.isEmpty else { return nil }

        if let preferredName = UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateName") {
            let preferredCanonical = canonical(preferredName)
            if let matched = published.first(where: { canonical($0.name) == preferredCanonical || canonical($0.name).contains(preferredCanonical) || preferredCanonical.contains(canonical($0.name)) }) {
                return matched
            }
        }
        return published.first(where: { canonical($0.name).contains("fb2d") }) ?? published[0]
    }

    static func recentCycleName(
        sessions: [Session],
        latestExport: SessionExportService.ExportPayload?
    ) -> String? {
        if let latestCompletedName = sessions
            .filter({ $0.status == .completed && $0.dayLabelSnapshot != "Off-Schedule" })
            .sorted(by: { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) })
            .compactMap({ normalizedNonEmptyName($0.cycleNameSnapshot) })
            .first {
            return latestCompletedName
        }

        guard latestExport?.workout_kind != "ad_hoc" else { return nil }
        return normalizedNonEmptyName(latestExport?.cycle_name)
    }

    static func inferredNextDayIndex(
        dayCount: Int,
        sessions: [Session],
        latestExportCycleDayIndex: Int?
    ) -> Int {
        guard dayCount > 0 else { return 0 }
        if let latestCompleted = sessions
            .filter({ $0.status == .completed })
            .sorted(by: { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) })
            .first {
            return (latestCompleted.cycleDayIndex + 1) % dayCount
        }
        if let latestExportCycleDayIndex {
            return (latestExportCycleDayIndex + 1) % dayCount
        }
        return 0
    }

    static func inferredNextDayIndex(
        dayCount: Int,
        sessions: [Session],
        targetCycleName: String,
        latestExport: SessionExportService.ExportPayload?
    ) -> Int {
        let canonicalTarget = canonical(targetCycleName)
        let matchingSessions = sessions.filter { session in
            guard session.dayLabelSnapshot != "Off-Schedule" else { return false }
            guard let name = normalizedNonEmptyName(session.cycleNameSnapshot) else { return false }
            return canonical(name) == canonicalTarget
        }

        let exportDayIndex: Int?
        if let latestExport,
           latestExport.workout_kind != "ad_hoc",
           canonical(latestExport.cycle_name) == canonicalTarget {
            exportDayIndex = latestExport.cycle_day_index
        } else {
            exportDayIndex = nil
        }

        return inferredNextDayIndex(
            dayCount: dayCount,
            sessions: matchingSessions,
            latestExportCycleDayIndex: exportDayIndex
        )
    }

    static func matchingTemplate(named templateName: String, in templates: [CycleTemplate]) -> CycleTemplate? {
        let target = canonical(templateName)
        return templates.first(where: { candidate in
            let candidateName = canonical(candidate.name)
            return candidateName == target || candidateName.contains(target) || target.contains(candidateName)
        })
    }

    static func latestExportSummary() -> SessionExportService.ExportPayload? {
        allExportSummaries().first
    }

    static func allExportSummaries() -> [SessionExportService.ExportPayload] {
        if AppRuntime.isUITesting { return [] }
        let fileManager = FileManager.default
        var directories: [URL] = []

        if let iCloudDir = SessionExportService.iCloudContainerURL()?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(iCloudDir)
        }
        if let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(docsDir)
        }

        var parsed: [(payload: SessionExportService.ExportPayload, date: Date)] = []

        for directory in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in urls where fileURL.pathExtension == "json" && fileURL.lastPathComponent.hasPrefix("workout-") {
                guard let data = try? Data(contentsOf: fileURL),
                      let payload = SessionExportService.decodeExportPayload(data: data, fileURL: fileURL),
                      let date = SessionExportService.parseExportDate(payload.date) else { continue }
                parsed.append((payload: payload, date: date))
            }
        }

        // Keep newest file per session_id when local and iCloud mirrors both exist.
        let deduped = Dictionary(grouping: parsed, by: { $0.payload.session_id }).compactMap { _, grouped in
            grouped.max(by: { $0.date < $1.date })
        }

        return deduped
            .sorted(by: { $0.date > $1.date })
            .map(\.payload)
    }

    @discardableResult
    static func reconcileWorkoutExports(
        _ exports: [SessionExportService.ExportPayload],
        cycle: ActiveCycleInstance,
        modelContext: ModelContext
    ) throws -> WorkoutImportResult {
        let catalog = try ensureExerciseCatalog(modelContext: modelContext)
        let exercisesByName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0) })
        let exercisesById = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var sessionsById: [UUID: Session] = [:]
        for session in try modelContext.fetch(FetchDescriptor<Session>()) {
            sessionsById[session.id] = session
        }
        let availableCycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let availableTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let templatesByID = Dictionary(
            uniqueKeysWithValues: availableTemplates.map { ($0.id, $0) }
        )
        var entriesByKey: [ImportedSetKey: SetEntry] = [:]
        for entry in try modelContext.fetch(FetchDescriptor<SetEntry>()) {
            let key = ImportedSetKey(
                sessionId: entry.sessionId,
                exerciseId: entry.exerciseId,
                setIndex: entry.setIndex
            )
            entriesByKey[key] = entriesByKey[key] ?? entry
        }
        var feedbackByKey: [ImportedFeedbackKey: AdHocExerciseFeedback] = [:]
        for feedback in try modelContext.fetch(FetchDescriptor<AdHocExerciseFeedback>()) {
            let key = ImportedFeedbackKey(sessionId: feedback.sessionId, exerciseId: feedback.exerciseId)
            if feedbackByKey[key] == nil || feedback.createdAt > feedbackByKey[key]!.createdAt {
                feedbackByKey[key] = feedback
            }
        }
        var resistanceProfileKeys = Set(
            try modelContext.fetch(FetchDescriptor<ExerciseResistanceProfile>()).map {
                "\($0.workoutKind.rawValue)|\($0.sessionId.uuidString)|\($0.exerciseId.uuidString)|\($0.occurrenceId?.uuidString ?? "")"
            }
        )

        var result = WorkoutImportResult()
        var readinessIds = Set(
            try modelContext.fetch(FetchDescriptor<FixedCycleReadinessObservation>()).map(\.id)
        )
        var fixedOverrideIds = Set(
            try modelContext.fetch(FetchDescriptor<FixedCycleOccurrenceOverride>()).map(\.id)
        )
        var fixedSnapshotKeys = Set(
            try modelContext.fetch(FetchDescriptor<FixedCycleExerciseSnapshot>()).map {
                "\($0.sessionId.uuidString)|\($0.position)|\($0.exerciseId.uuidString)"
            }
        )
        var clusterOccurrenceIDs = Set(
            try modelContext.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>()).map(\.id)
        )
        var fixedContextKeys = Set(
            try modelContext.fetch(FetchDescriptor<FixedCycleSessionContext>()).map(\.key)
        )
        var rotationStatesByKey = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<FixedCycleClusterPointer>()).map {
                ($0.key, $0)
            }
        )
        let pointerKeysBeforeRecovery = Set(rotationStatesByKey.keys)

        for export in exports {
            guard let sessionId = UUID(uuidString: export.session_id),
                  let finishedAt = SessionExportService.parseExportDate(export.date) else { continue }

            let isClusteredV4 = export.fixed_cycle.map {
                $0.schema_version == 4
                    && $0.program_identifier == FixedCycleClusterProgramService.programIdentifier
                    && $0.program_version == FixedCycleClusterProgramService.structureVersion
            } ?? false
            let destinationCycle: ActiveCycleInstance
            if isClusteredV4 {
                let exactProgramCycles = availableCycles.filter {
                    FixedCycleClusterProgramService.isProgramTemplate(
                        templatesByID[$0.templateId]
                    )
                }
                let exportedCycleID = export.fixed_cycle?.cycle_instance_id
                    .flatMap(UUID.init(uuidString:))
                destinationCycle = exactProgramCycles.first(where: {
                    $0.id == exportedCycleID
                }) ?? exactProgramCycles.first(where: {
                    $0.id == cycle.id
                }) ?? exactProgramCycles.sorted {
                    $0.id.uuidString < $1.id.uuidString
                }.first ?? cycle
            } else {
                destinationCycle = export.fixed_cycle
                    .flatMap { UUID(uuidString: $0.template_id) }
                    .flatMap { templateId in
                        availableCycles.first(where: { $0.templateId == templateId })
                    } ?? cycle
            }
            let canHydrateClusterState = isClusteredV4
                && FixedCycleClusterProgramService.isProgramTemplate(
                    templatesByID[destinationCycle.templateId]
                )
            let session: Session
            if let existing = sessionsById[sessionId] {
                session = existing
                result.skippedExisting += 1
            } else {
                session = Session(
                    id: sessionId,
                    cycleInstanceId: destinationCycle.id,
                    cycleDayIndex: export.cycle_day_index,
                    cycleNameSnapshot: export.cycle_name,
                    dayLabelSnapshot: export.workout_kind == "ad_hoc"
                        ? "Off-Schedule"
                        : "Day \(export.cycle_day_index + 1)",
                    createdAt: finishedAt.addingTimeInterval(-60),
                    finishedAt: finishedAt,
                    status: .completed,
                    // The import may have come from the local recovery mirror.
                    // Upload success is established only by the ubiquitous item metadata.
                    exportStatus: .pending
                )
                try session.validate()
                modelContext.insert(session)
                sessionsById[sessionId] = session
                result.imported += 1
            }

            if export.workout_kind == "ad_hoc" {
                session.cycleNameSnapshot = export.cycle_name
                session.dayLabelSnapshot = "Off-Schedule"
            } else if canHydrateClusterState {
                session.cycleInstanceId = destinationCycle.id
            }

            for exportExercise in export.exercises {
                let orderedMetadata = export.fixed_cycle?.ordered_exercises ?? []
                let metadataExerciseId = orderedMetadata.first(where: {
                    $0.exercise_name.caseInsensitiveCompare(exportExercise.exercise_name)
                        == .orderedSame
                }).flatMap { UUID(uuidString: $0.exercise_id) }
                guard let exercise = resolveImportedExercise(
                    id: exportExercise.exercise_id.flatMap(UUID.init(uuidString:))
                        ?? metadataExerciseId,
                    name: exportExercise.exercise_name,
                    byId: exercisesById,
                    byName: exercisesByName
                ) else {
                    result.skippedUnknownExercises += 1
                    continue
                }

                for exportedSet in exportExercise.sets where exportedSet.reps > 0 {
                    let key = ImportedSetKey(
                        sessionId: session.id,
                        exerciseId: exercise.id,
                        setIndex: exportedSet.set_index
                    )
                    if entriesByKey[key] == nil {
                        let entry = SetEntry(
                            sessionId: session.id,
                            exerciseId: exercise.id,
                            setIndex: exportedSet.set_index,
                            weight: exportedSet.weight,
                            reps: exportedSet.reps,
                            isLocked: true,
                            lockedAt: exportedSet.locked_at.flatMap(
                                SessionExportService.parseExportDate
                            )
                        )
                        try entry.validate()
                        modelContext.insert(entry)
                        entriesByKey[key] = entry
                    }
                }

                if let value = exportExercise.resistance_profile?.value {
                    let kind: ResistanceProfileWorkoutKind = export.workout_kind == "ad_hoc"
                        ? .adHoc
                        : .fixed
                    let profileKey = "\(kind.rawValue)|\(session.id.uuidString)|\(exercise.id.uuidString)|"
                    if resistanceProfileKeys.insert(profileKey).inserted {
                        modelContext.insert(
                            ExerciseResistanceProfile(
                                workoutKind: kind,
                                sessionId: session.id,
                                exerciseId: exercise.id,
                                resistanceSource: value.resistanceSource,
                                chainType: value.chainType,
                                chainPercent: value.chainPercent,
                                eccentricPercent: value.eccentricPercent,
                                frozenAt: finishedAt,
                                createdAt: finishedAt,
                                updatedAt: finishedAt
                            )
                        )
                    }
                }

                if let rawFeedback = exportExercise.volume_feedback,
                   let rating = ComplexFeedbackRating(rawValue: rawFeedback) {
                    let key = ImportedFeedbackKey(sessionId: session.id, exerciseId: exercise.id)
                    if let existing = feedbackByKey[key] {
                        existing.rating = rating
                        existing.createdAt = finishedAt
                    } else {
                        let feedback = AdHocExerciseFeedback(
                            sessionId: session.id,
                            exerciseId: exercise.id,
                            rating: rating,
                            createdAt: finishedAt
                        )
                        modelContext.insert(feedback)
                        feedbackByKey[key] = feedback
                    }
                }
            }

            if let metadata = export.fixed_cycle {
                session.dayLabelSnapshot = metadata.day_label
                for statePayload in metadata.cluster_rotation_states ?? [] where
                    canHydrateClusterState
                        && metadata.schema_version == 4
                        && metadata.program_identifier == FixedCycleClusterProgramService.programIdentifier
                        && metadata.program_version == FixedCycleClusterProgramService.structureVersion {
                    guard statePayload.position_index >= 0,
                          !statePayload.program_version_id.isEmpty,
                          !statePayload.cluster_id.isEmpty else { continue }
                    let key = FixedCycleClusterPointer.key(
                        cycleInstanceId: session.cycleInstanceId,
                        programVersionID: statePayload.program_version_id,
                        clusterID: statePayload.cluster_id
                    )
                    let exportedUpdatedAt = SessionExportService.parseExportDate(
                        statePayload.updated_at
                    ) ?? finishedAt
                    if let existing = rotationStatesByKey[key] {
                        if existing.isDerived,
                           !statePayload.is_derived,
                           exportedUpdatedAt >= existing.updatedAt {
                            existing.positionIndex = statePayload.position_index
                            existing.updatedAt = exportedUpdatedAt
                            existing.lastCompletedOccurrenceID = statePayload
                                .last_completed_occurrence_id
                                .flatMap(UUID.init(uuidString:))
                            existing.isDerived = false
                        }
                    } else {
                        let state = FixedCycleClusterPointer(
                            cycleInstanceId: session.cycleInstanceId,
                            templateId: destinationCycle.templateId,
                            programVersionID: statePayload.program_version_id,
                            clusterID: statePayload.cluster_id,
                            completedCount: statePayload.position_index,
                            updatedAt: exportedUpdatedAt,
                            lastCompletedOccurrenceID: statePayload.last_completed_occurrence_id.flatMap(UUID.init(uuidString:)),
                            isDerived: statePayload.is_derived
                        )
                        modelContext.insert(state)
                        rotationStatesByKey[key] = state
                    }
                }
                for occurrencePayload in metadata.cluster_occurrences ?? [] where
                    canHydrateClusterState
                        && metadata.schema_version == 4
                        && metadata.program_identifier == FixedCycleClusterProgramService.programIdentifier
                        && metadata.program_version == FixedCycleClusterProgramService.structureVersion {
                    guard let occurrenceID = UUID(uuidString: occurrencePayload.occurrence_id),
                          clusterOccurrenceIDs.insert(occurrenceID).inserted,
                          occurrencePayload.position_index >= 0 else { continue }
                    let occurrenceSnapshots = occurrencePayload.exercises.compactMap {
                        payload -> FixedCycleProgressionSnapshot? in
                        guard let exportedID = UUID(uuidString: payload.exercise_id),
                              let exercise = resolveImportedExercise(
                                  id: exportedID,
                                  name: payload.exercise_name,
                                  byId: exercisesById,
                                  byName: exercisesByName
                              ),
                              let muscle = MuscleGroup(rawValue: payload.muscle),
                              let status = FixedCycleProgressionStatus(rawValue: payload.completion_status),
                              !payload.progression_key.isEmpty else { return nil }
                        return FixedCycleProgressionSnapshot(
                            position: payload.position,
                            exerciseId: exercise.id,
                            exerciseName: payload.exercise_name,
                            muscle: muscle,
                            prescribedSetCount: payload.prescribed_set_count,
                            progressionKey: payload.progression_key,
                            resistanceProfile: payload.resistance_profile?.value,
                            completionStatus: status
                        )
                    }
                    guard occurrenceSnapshots.count == occurrencePayload.exercises.count,
                          let occurrence = try? FixedCycleProgressionOccurrence(
                              id: occurrenceID,
                              sessionId: session.id,
                              cycleInstanceId: session.cycleInstanceId,
                              templateId: destinationCycle.templateId,
                              programVersionID: occurrencePayload.program_version_id,
                              clusterID: occurrencePayload.cluster_id,
                              absoluteStep: occurrencePayload.position_index,
                              templateDayPosition: occurrencePayload.template_day_position
                                  ?? FixedCycleClusterProgramService.Cluster(
                                      rawValue: occurrencePayload.cluster_id
                                  ).map {
                                      $0.templateBasePosition
                                          + occurrencePayload.position_index % $0.rotationLength
                                  } ?? export.cycle_day_index,
                              dayLabel: occurrencePayload.day_label ?? metadata.day_label,
                              completedAt: SessionExportService.parseExportDate(occurrencePayload.completed_at) ?? finishedAt,
                              exerciseSnapshots: occurrenceSnapshots
                          ) else {
                        clusterOccurrenceIDs.remove(occurrenceID)
                        continue
                    }
                    modelContext.insert(occurrence)
                    let contextKey = FixedCycleSessionContext.key(
                        sessionId: session.id,
                        clusterID: occurrence.clusterID
                    )
                    if fixedContextKeys.insert(contextKey).inserted,
                       let frozenContext = try? FixedCycleSessionContext(
                           sessionId: session.id,
                           cycleInstanceId: occurrence.cycleInstanceId,
                           templateId: occurrence.templateId,
                           programVersionID: occurrence.programVersionID,
                           clusterID: occurrence.clusterID,
                           absoluteStep: occurrence.absoluteStep,
                           templateDayPosition: occurrence.templateDayPosition,
                           dayLabel: occurrence.dayLabel,
                           exerciseSnapshots: occurrence.exerciseSnapshots,
                           createdAt: occurrence.completedAt
                       ) {
                        modelContext.insert(frozenContext)
                    }
                }
                for payload in metadata.readiness {
                    guard let id = UUID(uuidString: payload.observation_id),
                          !readinessIds.contains(id) else { continue }
                    let systemicEagerness = payload.systemic_eagerness.flatMap(
                        EagernessLevel.init(rawValue:)
                    )
                    guard payload.systemic_eagerness == nil || systemicEagerness != nil else {
                        continue
                    }
                    let responses = payload.responses.compactMap { response -> FixedCycleReadinessResponse? in
                        guard let muscle = MuscleGroup(rawValue: response.muscle),
                              let soreness = SorenessLevel.decodeStoredOrExportedValue(response.soreness),
                              let pain = ConnectiveTissuePainLevel(rawValue: response.connective_tissue_pain) else {
                            return nil
                        }
                        let eagerness = response.eagerness.flatMap(EagernessLevel.init(rawValue:))
                        guard response.eagerness == nil || eagerness != nil else { return nil }
                        return FixedCycleReadinessResponse(
                            muscle: muscle,
                            soreness: soreness,
                            connectiveTissuePain: pain,
                            eagerness: eagerness
                        )
                    }
                    guard responses.count == payload.responses.count else { continue }
                    modelContext.insert(
                        FixedCycleReadinessObservation(
                            id: id,
                            sessionId: session.id,
                            localDateKey: payload.local_date_key,
                            timeZoneIdentifier: payload.time_zone_identifier,
                            revision: payload.revision,
                            createdAt: SessionExportService.parseExportDate(payload.created_at) ?? finishedAt,
                            systemicEagerness: systemicEagerness,
                            responses: responses
                        )
                    )
                    readinessIds.insert(id)
                }
                for payload in metadata.skips {
                    guard let id = UUID(uuidString: payload.override_id),
                          !fixedOverrideIds.contains(id),
                          let kind = FixedCycleOccurrenceOverrideKind(rawValue: payload.kind) else {
                        continue
                    }
                    modelContext.insert(
                        FixedCycleOccurrenceOverride(
                            id: id,
                            sessionId: session.id,
                            kind: kind,
                            slotPosition: payload.slot_position,
                            exerciseId: payload.exercise_id.flatMap(UUID.init(uuidString:)),
                            muscle: payload.muscle.flatMap(MuscleGroup.init(rawValue:)),
                            reasonCode: payload.reason,
                            createdAt: SessionExportService.parseExportDate(payload.created_at) ?? finishedAt
                        )
                    )
                    fixedOverrideIds.insert(id)
                }
                for payload in metadata.ordered_exercises {
                    guard let exerciseId = UUID(uuidString: payload.exercise_id),
                          let muscle = MuscleGroup(rawValue: payload.muscle) else {
                        continue
                    }
                    let key = "\(session.id.uuidString)|\(payload.position)|\(exerciseId.uuidString)"
                    guard !fixedSnapshotKeys.contains(key) else { continue }
                    modelContext.insert(
                        FixedCycleExerciseSnapshot(
                            sessionId: session.id,
                            position: payload.position,
                            exerciseId: exerciseId,
                            exerciseName: payload.exercise_name,
                            muscle: muscle,
                            statusRawValue: payload.status,
                            skipReason: payload.skip_reason
                        )
                    )
                    fixedSnapshotKeys.insert(key)
                }
            }
        }

        let recoveredOccurrences = try modelContext.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>())
            .filter { $0.programVersionID == FixedCycleClusterProgramService.programVersionID }
        for (cycleID, cycleOccurrences) in Dictionary(
            grouping: recoveredOccurrences,
            by: \.cycleInstanceId
        ) {
            for cluster in FixedCycleClusterProgramService.Cluster.allCases {
                let key = FixedCycleClusterPointer.key(
                    cycleInstanceId: cycleID,
                    programVersionID: FixedCycleClusterProgramService.programVersionID,
                    clusterID: cluster.rawValue
                )
                let candidates = cycleOccurrences.filter { $0.clusterID == cluster.rawValue }
                guard let latest = candidates.max(by: {
                    $0.positionIndex < $1.positionIndex
                }) else {
                    if !pointerKeysBeforeRecovery.contains(key),
                       let imported = rotationStatesByKey[key],
                       imported.positionIndex > 0 {
                        throw ClusteredProgramRecoveryError.occurrenceGap(
                            cycleId: cycleID,
                            clusterID: cluster.rawValue
                        )
                    }
                    continue
                }
                let groupedByStep = Dictionary(grouping: candidates, by: \.positionIndex)
                if let conflict = groupedByStep.first(where: { $0.value.count > 1 }) {
                    throw ClusteredProgramRecoveryError.occurrenceConflict(
                        cycleId: cycleID,
                        clusterID: cluster.rawValue,
                        absoluteStep: conflict.key
                    )
                }
                let recoveredSteps = groupedByStep.keys.sorted()
                guard recoveredSteps == Array(0...latest.positionIndex) else {
                    throw ClusteredProgramRecoveryError.occurrenceGap(
                        cycleId: cycleID,
                        clusterID: cluster.rawValue
                    )
                }
                let recoveredCount = latest.positionIndex + 1
                if let existing = rotationStatesByKey[key] {
                    if !pointerKeysBeforeRecovery.contains(key),
                       existing.positionIndex > recoveredCount {
                        throw ClusteredProgramRecoveryError.occurrenceGap(
                            cycleId: cycleID,
                            clusterID: cluster.rawValue
                        )
                    }
                    if recoveredCount > existing.positionIndex {
                        existing.positionIndex = recoveredCount
                        existing.updatedAt = latest.completedAt
                        existing.lastCompletedOccurrenceID = latest.id
                        existing.isDerived = true
                    }
                    continue
                }
                let derived = FixedCycleClusterPointer(
                    cycleInstanceId: cycleID,
                    templateId: latest.templateId,
                    programVersionID: FixedCycleClusterProgramService.programVersionID,
                    clusterID: cluster.rawValue,
                    completedCount: recoveredCount,
                    updatedAt: latest.completedAt,
                    lastCompletedOccurrenceID: latest.id,
                    isDerived: true
                )
                modelContext.insert(derived)
                rotationStatesByKey[key] = derived
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        return result
    }

    static func resolveImportedExercise(
        id: UUID?,
        name: String,
        byId: [UUID: Exercise],
        byName: [String: Exercise]
    ) -> Exercise? {
        if let id, let exact = byId[id] {
            return exact
        }
        if let exact = byName[name.lowercased()] {
            return exact
        }
        let canonicalCatalog = Dictionary(
            byName.values.map { (canonicalExerciseName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let canonical = canonicalExerciseName(name)
        if let exact = canonicalCatalog[canonical] {
            return exact
        }
        for alias in safeExerciseAliases(for: canonical) {
            if let match = canonicalCatalog[alias] {
                return match
            }
        }
        return nil
    }

    private static func canonicalExerciseName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "dumbell", with: "dumbbell")
            .replacingOccurrences(of: "ez-bar", with: "ez bar")
            .replacingOccurrences(of: "ezbar", with: "ez bar")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func safeExerciseAliases(for canonical: String) -> [String] {
        switch canonical {
        case "stifflegdeadlift", "stiffleggedeadlift", "sldl":
            return ["stifflegdeadlift", "stiffleggedeadlift", "sldl"]
        case "singlearmdumbbellrow", "singlearmdumbellrow", "singlearmdbrow":
            return ["singlearmdumbbellrow", "singlearmdumbellrow", "singlearmdbrow"]
        case "dumbbellpreachercurl", "dumbellpreachercurl", "dbpreachercurl":
            return ["dumbbellpreachercurl", "dumbellpreachercurl", "dbpreachercurl"]
        case "overheadezbarextension", "overheadezextension", "ezbaroverheadextension":
            return ["overheadezbarextension", "overheadezextension", "ezbaroverheadextension"]
        default:
            return []
        }
    }

    /// Performs the one-time, explicit device rollout requested by the user:
    /// recover available workout exports, create a conservative starting
    /// Adaptive profile if one does not exist, and select Adaptive mode. The
    /// newest ad-hoc workout date becomes the profile's start date so restored
    /// work immediately participates in load/recovery accounting.
    @discardableResult
    static func prepareAdaptiveRollout(
        exports: [SessionExportService.ExportPayload],
        cycle: ActiveCycleInstance,
        modelContext: ModelContext
    ) throws -> WorkoutImportResult {
        let result = try reconcileWorkoutExports(exports, cycle: cycle, modelContext: modelContext)
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())

        if let activeProgram = AdaptiveProgramService.activeProgram(from: programs) {
            // This explicit rollout preference correction preserves the original
            // profile identity and start date while updating planner semantics.
            activeProgram.globalMaxMovements = 4
            activeProgram.maxDifficultyCost = 60
            try modelContext.save()
        } else {
            var draft = AdaptiveProgramService.demoDraft(exercises: exercises)
            draft.name = "Adaptive Floating — Initial"
            draft.isReviewedForUse = true

            let startDate = exports
                .filter { $0.workout_kind == "ad_hoc" }
                .compactMap { SessionExportService.parseExportDate($0.date) }
                .max() ?? .now

            _ = try AdaptiveProgramService.saveVersion(
                draft: draft,
                replacing: nil,
                allPrograms: programs,
                exercises: exercises,
                modelContext: modelContext,
                now: startDate
            )
        }

        let preferences = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
        _ = try TrainingModeService.setMode(
            .adaptive,
            preferences: preferences,
            modelContext: modelContext
        )
        return result
    }

    /// Explicit, one-time rollout path. Callers are responsible for quiescing
    /// and backing up the live store before invoking this mutation.
    ///
    /// A successfully active Push/Pull cycle is the durable idempotency
    /// predicate. Re-running this function never rewinds its pointer.
    @discardableResult
    static func preparePushPullABRollout(
        modelContext: ModelContext,
        archivedDraftsConfirmed: Bool = false
    ) throws -> PushPullRolloutResult {
        do {
            return try preparePushPullABRolloutTransaction(
                modelContext: modelContext,
                archivedDraftsConfirmed: archivedDraftsConfirmed
            )
        } catch {
            // The caller may continue normal startup work after reporting a
            // blocked rollout. Do not leave unsaved migration mutations in the
            // context where an unrelated later save could commit them.
            modelContext.rollback()
            throw error
        }
    }

    private static func preparePushPullABRolloutTransaction(
        modelContext: ModelContext,
        archivedDraftsConfirmed: Bool
    ) throws -> PushPullRolloutResult {
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let entries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        let adaptiveSessions = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        let adaptiveEntries = try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let generatedPlans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        let preferences = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
        let adaptivePrograms = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        if let marker = preferences.first(where: { $0.key == pushPullRolloutMarkerKey }) {
            guard let templateId = UUID(uuidString: marker.modeRawValue),
                  let template = templates.first(where: { $0.id == templateId }),
                  let cycle = cycles.first(where: { $0.templateId == template.id }) else {
                throw PushPullRolloutError.completedRolloutStateMissing
            }
            return PushPullRolloutResult(
                templateId: template.id,
                cycleId: cycle.id,
                didApply: false
            )
        }
        let preferredTemplateId = UserDefaults.standard
            .string(forKey: "openlift.lastActivatedTemplateId")
            .flatMap(UUID.init(uuidString:))

        let activeCycle = OpenLiftStateResolver.activeCycle(
            activeCycles: cycles,
            templates: templates,
            sessions: sessions,
            latestExport: nil,
            preferredTemplateId: preferredTemplateId
        )
        let activeTemplate = activeCycle.flatMap { cycle in
            templates.first(where: { $0.id == cycle.templateId })
        }
        let activeDrafts = sessions.filter {
            $0.status == .draft && (activeCycle == nil || $0.cycleInstanceId == activeCycle?.id)
        }
        for draft in activeDrafts {
            let draftEntries = entries.filter { $0.sessionId == draft.id }
            let containsLockedWork = draftEntries.contains(where: \.isLocked)
            let containsEnteredWork = draftEntries.contains(where: {
                $0.weight != 0 || $0.reps != 0
            })
            if containsLockedWork || (containsEnteredWork && !archivedDraftsConfirmed) {
                throw PushPullRolloutError.nonEmptyDraft(sessionId: draft.id)
            }
        }
        for draft in adaptiveSessions where draft.status == .draft {
            let draftEntries = adaptiveEntries.filter { $0.adaptiveSessionId == draft.id }
            let containsEnteredWork = draftEntries.contains(where: {
                $0.isLocked || $0.weight != 0 || $0.reps != 0
            })
            guard containsEnteredWork else { continue }
            guard archivedDraftsConfirmed,
                  draftEntries.contains(where: { $0.isLocked && $0.reps > 0 }),
                  !draftEntries.contains(where: { $0.isLocked && $0.reps <= 0 }),
                  let plan = generatedPlans.first(where: {
                      $0.id == draft.generatedPlanId
                  }) else {
                throw PushPullRolloutError.nonEmptyDraft(sessionId: draft.id)
            }
            // The archived live-container backup protects the original draft.
            // Preserve completed work in live history and drop only editable
            // autofill rows, matching normal Adaptive completion semantics.
            for entry in draftEntries where !entry.isLocked || entry.reps <= 0 {
                modelContext.delete(entry)
            }
            draft.status = .completed
            draft.finishedAt = .now
            plan.status = .completed
        }

        let exercises = try ensureExerciseCatalog(modelContext: modelContext)
        let template: CycleTemplate
        if let existing = templates.first(where: {
            canonical($0.name) == canonical(pushPullABTemplateName)
        }) {
            // Never overwrite a previously seeded, user-edited template.
            template = existing
        } else {
            template = try pushPullABTemplate(
                exercises: exercises,
                sourceTemplate: activeTemplate,
                sourceAdaptiveProgram: TrainingModeService.resolvedMode(preferences: preferences)
                    == .adaptive
                    ? AdaptiveProgramService.activeProgram(from: adaptivePrograms)
                    : nil
            )
            modelContext.insert(template)
        }

        for draft in activeDrafts {
            for entry in entries where entry.sessionId == draft.id {
                modelContext.delete(entry)
            }
            for override in try modelContext.fetch(FetchDescriptor<SessionSlotOverride>())
            where override.sessionId == draft.id {
                modelContext.delete(override)
            }
            modelContext.delete(draft)
        }

        let cycle = cycles.first(where: { $0.templateId == template.id })
            ?? ActiveCycleInstance(
                templateId: template.id,
                currentDayIndex: pushPullRolloutStartingDayIndex
            )
        if cycle.modelContext == nil {
            modelContext.insert(cycle)
        }
        cycle.currentDayIndex = pushPullRolloutStartingDayIndex
        try cycle.validate(template: template)
        let modeRows = preferences.filter { $0.key == TrainingModeService.activeModeKey }
        if let mode = modeRows.first {
            mode.modeRawValue = TrainingMode.rotation.rawValue
            for duplicate in modeRows.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            modelContext.insert(
                TrainingPreference(modeRawValue: TrainingMode.rotation.rawValue)
            )
        }
        modelContext.insert(
            TrainingPreference(
                key: pushPullRolloutMarkerKey,
                modeRawValue: template.id.uuidString
            )
        )
        try modelContext.save()

        UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
        UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
        return PushPullRolloutResult(
            templateId: template.id,
            cycleId: cycle.id,
            didApply: true
        )
    }

    static let pushPullABTemplateName = "Push/Pull A/B"
    static let pushPullRolloutMarkerKey = "push-pull-ab-fixed-cycle-rollout-v1"
    static let pushPullRolloutStartingDayIndex = 1
    static let clusteredProgramRolloutMarkerKey = "clustered-hypertrophy-fixed-cycle-rollout-v1"
    static let july27AdaptiveInclineCurlRepairMarkerKey =
        "repair-2026-07-27-adaptive-incline-curl-v1"
    static let july27AdaptiveInclineCurlSessionId =
        UUID(uuidString: "08476AD8-9550-4A33-94DF-55B12E6161F2")!
    static let july27AdaptiveInclineCurlExerciseId =
        UUID(uuidString: "96C071BF-05E2-467C-8357-CFE375C5C162")!
    static let august16PullACompletionRepairMarkerKey =
        "repair-2026-08-16-pull-a-completion-date-v1"
    static let august16PullASessionId =
        UUID(uuidString: "46A246F9-1B51-47D7-BCC0-C754ECBD9C59")!
    static let august16PullACycleId =
        UUID(uuidString: "D5E65036-2701-4320-A02E-1AF0C5865E9A")!
    static let august16PullATemplateId =
        UUID(uuidString: "A7B6B453-39EF-42BF-B798-5FED3224F1E1")!
    static let august16PullAOriginalCompletion = Date(timeIntervalSince1970: 1_786_982_773)
    static let august16PullARepairedCompletion = Date(timeIntervalSince1970: 1_786_908_126)

    private struct August16PullASetManifestItem: Hashable {
        let exerciseId: UUID
        let setIndex: Int
        let weight: Double
        let reps: Int
    }

    /// One-time, fail-closed repair for Pull A work performed on August 16 but
    /// submitted the following morning. The direct and iCloud export supplied
    /// the exact session, cycle, exercise, and set manifest used below.
    ///
    /// Completion had already advanced the cycle to Push A. This operation
    /// changes only the completed session timestamp, marks that session for a
    /// fresh export, and records an idempotence marker. It never moves a cycle
    /// pointer, creates a draft, or changes a set row.
    @discardableResult
    static func repairAugust16PullACompletionDate(
        modelContext: ModelContext
    ) throws -> August16PullACompletionRepairResult {
        do {
            return try repairAugust16PullACompletionDateTransaction(modelContext: modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func repairAugust16PullACompletionDateTransaction(
        modelContext: ModelContext
    ) throws -> August16PullACompletionRepairResult {
        let preferences = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let entries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())

        guard let session = sessions.first(where: { $0.id == august16PullASessionId }) else {
            throw August16PullACompletionRepairError.targetSessionNotFound
        }
        guard TrainingModeService.resolvedMode(preferences: preferences) == .rotation,
              preferences.contains(where: {
                  $0.key == pushPullRolloutMarkerKey
                      && $0.modeRawValue == august16PullATemplateId.uuidString
              }),
              let template = templates.first(where: { $0.id == august16PullATemplateId }),
              let cycle = cycles.first(where: {
                  $0.id == august16PullACycleId
                      && $0.templateId == august16PullATemplateId
              }) else {
            throw August16PullACompletionRepairError.pushAStateMissing
        }
        let days = CycleOrdering.sortedDays(template.days)
        guard days.indices.contains(cycle.currentDayIndex),
              days[cycle.currentDayIndex].label.caseInsensitiveCompare("Push A") == .orderedSame else {
            throw August16PullACompletionRepairError.pushAStateMissing
        }

        let markerExists = preferences.contains(where: {
            $0.key == august16PullACompletionRepairMarkerKey
                && $0.modeRawValue == august16PullASessionId.uuidString
        })
        if markerExists {
            guard hasExactAugust16PullASessionState(
                session,
                expectedCompletion: august16PullARepairedCompletion
            ), hasExactAugust16PullASetManifest(entries, sessionId: session.id) else {
                throw August16PullACompletionRepairError.completedRepairStateMissing
            }
            return August16PullACompletionRepairResult(sessionId: session.id, didApply: false)
        }

        guard hasExactAugust16PullASessionState(
            session,
            expectedCompletion: august16PullAOriginalCompletion
        ) else {
            throw August16PullACompletionRepairError.unexpectedSessionState
        }
        guard hasExactAugust16PullASetManifest(entries, sessionId: session.id) else {
            throw August16PullACompletionRepairError.unexpectedExistingSets
        }

        session.finishedAt = august16PullARepairedCompletion
        session.exportStatus = .pending
        modelContext.insert(
            TrainingPreference(
                key: august16PullACompletionRepairMarkerKey,
                modeRawValue: session.id.uuidString
            )
        )
        try modelContext.save()
        return August16PullACompletionRepairResult(sessionId: session.id, didApply: true)
    }

    private static func hasExactAugust16PullASessionState(
        _ session: Session,
        expectedCompletion: Date
    ) -> Bool {
        guard session.cycleInstanceId == august16PullACycleId,
              session.cycleDayIndex == 0,
              session.cycleNameSnapshot == pushPullABTemplateName,
              session.dayLabelSnapshot == "Pull A",
              session.status == .completed,
              let finishedAt = session.finishedAt else { return false }
        return abs(finishedAt.timeIntervalSince(expectedCompletion)) < 2
    }

    private static func hasExactAugust16PullASetManifest(
        _ entries: [SetEntry],
        sessionId: UUID
    ) -> Bool {
        let actual: Set<August16PullASetManifestItem> = Set(
            entries.filter { $0.sessionId == sessionId }.compactMap { entry in
                guard entry.isLocked else { return nil }
                return August16PullASetManifestItem(
                    exerciseId: entry.exerciseId,
                    setIndex: entry.setIndex,
                    weight: entry.weight,
                    reps: entry.reps
                )
            }
        )
        let targetEntries = entries.filter { $0.sessionId == sessionId }
        return targetEntries.count == august16PullASetManifest.count
            && actual == august16PullASetManifest
    }

    private static let august16PullASetManifest: Set<August16PullASetManifestItem> = [
        .init(exerciseId: UUID(uuidString: "54214942-679D-4CBB-9B27-F78601897BA2")!, setIndex: 1, weight: 95, reps: 14),
        .init(exerciseId: UUID(uuidString: "54214942-679D-4CBB-9B27-F78601897BA2")!, setIndex: 2, weight: 95, reps: 11),
        .init(exerciseId: UUID(uuidString: "921ADA85-9DED-412E-B74B-DF4CB6661284")!, setIndex: 1, weight: 35, reps: 16),
        .init(exerciseId: UUID(uuidString: "921ADA85-9DED-412E-B74B-DF4CB6661284")!, setIndex: 2, weight: 35, reps: 13),
        .init(exerciseId: UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, setIndex: 1, weight: 28, reps: 16),
        .init(exerciseId: UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, setIndex: 2, weight: 28, reps: 11),
        .init(exerciseId: UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, setIndex: 3, weight: 28, reps: 10),
        .init(exerciseId: UUID(uuidString: "55B44E05-2ADC-4680-AB4B-FA10592ECF49")!, setIndex: 1, weight: 135, reps: 12),
        .init(exerciseId: UUID(uuidString: "55B44E05-2ADC-4680-AB4B-FA10592ECF49")!, setIndex: 2, weight: 135, reps: 12),
        .init(exerciseId: UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, setIndex: 1, weight: 30, reps: 6),
        .init(exerciseId: UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, setIndex: 2, weight: 25, reps: 7),
        .init(exerciseId: UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, setIndex: 3, weight: 20, reps: 8),
    ]

    /// Explicit, backup-gated repair for the completed July 27 Adaptive
    /// workout archived during the Push/Pull rollout.
    ///
    /// The live precondition is deliberately narrow: Fixed Cycle must still be
    /// on the marked Push A rollout state, and Incline Curl must contain either
    /// the known single saved 20 x 13 row or the exact repaired rows. The
    /// repair touches no cycle, template, plan, or unrelated workout row.
    @discardableResult
    static func repairJuly27AdaptiveInclineCurl(
        modelContext: ModelContext,
        backupConfirmed: Bool = false
    ) throws -> July27AdaptiveInclineCurlRepairResult {
        guard backupConfirmed else {
            throw July27AdaptiveInclineCurlRepairError.backupConfirmationRequired
        }
        do {
            return try repairJuly27AdaptiveInclineCurlTransaction(modelContext: modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func repairJuly27AdaptiveInclineCurlTransaction(
        modelContext: ModelContext
    ) throws -> July27AdaptiveInclineCurlRepairResult {
        let preferences = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        guard TrainingModeService.resolvedMode(preferences: preferences) == .rotation,
              let rolloutMarker = preferences.first(where: {
                  $0.key == pushPullRolloutMarkerKey
              }),
              let templateId = UUID(uuidString: rolloutMarker.modeRawValue),
              let template = templates.first(where: { $0.id == templateId }),
              let cycle = cycles.first(where: { $0.templateId == templateId }) else {
            throw July27AdaptiveInclineCurlRepairError.pushAStateMissing
        }
        let days = CycleOrdering.sortedDays(template.days)
        guard days.indices.contains(cycle.currentDayIndex),
              days[cycle.currentDayIndex].label.caseInsensitiveCompare("Push A") == .orderedSame else {
            throw July27AdaptiveInclineCurlRepairError.pushAStateMissing
        }

        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        let sessions = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        let entries = try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let repairMarker = preferences.first(where: {
            $0.key == july27AdaptiveInclineCurlRepairMarkerKey
        })

        if let repairMarker {
            guard let markedSessionId = UUID(uuidString: repairMarker.modeRawValue),
                  markedSessionId == july27AdaptiveInclineCurlSessionId,
                  let markedSession = sessions.first(where: {
                      $0.id == markedSessionId && $0.status == .completed
                  }),
                  let markedPlan = plans.first(where: {
                      $0.id == markedSession.generatedPlanId
                          && $0.localDateKey == "2026-07-27"
                  }),
                  let target = try resolveJuly27InclineCurlTarget(
                      plan: markedPlan,
                      session: markedSession,
                      entries: entries,
                      exercises: exercises
                  ),
                  hasExactJuly27InclineCurlSets(
                      target.entries,
                      exerciseId: target.exerciseId
                  ) else {
                throw July27AdaptiveInclineCurlRepairError.completedRepairStateMissing
            }
            return July27AdaptiveInclineCurlRepairResult(
                sessionId: markedSession.id,
                didApply: false
            )
        }

        guard let session = sessions.first(where: {
            $0.id == july27AdaptiveInclineCurlSessionId
                && $0.status == .completed
        }) else {
            throw July27AdaptiveInclineCurlRepairError.targetSessionNotFound
        }
        guard let plan = plans.first(where: {
                  $0.id == session.generatedPlanId
                      && $0.localDateKey == "2026-07-27"
              }),
              let target = try resolveJuly27InclineCurlTarget(
                  plan: plan,
                  session: session,
                  entries: entries,
                  exercises: exercises
              ) else {
            throw July27AdaptiveInclineCurlRepairError.inclineCurlOccurrenceNotFound
        }

        if !hasExactJuly27InclineCurlSets(
            target.entries,
            exerciseId: target.exerciseId
        ) {
            guard target.entries.count == 1,
                  let saved = target.entries.first,
                  saved.exerciseId == target.exerciseId,
                  saved.setIndex == 1,
                  saved.weight == 20,
                  saved.reps == 13,
                  saved.isLocked else {
                throw July27AdaptiveInclineCurlRepairError.unexpectedExistingSets
            }
            modelContext.insert(
                AdaptiveSetEntry(
                    adaptiveSessionId: session.id,
                    occurrenceId: target.occurrenceId,
                    exerciseId: target.exerciseId,
                    setIndex: 2,
                    weight: 20,
                    reps: 9,
                    isLocked: true
                )
            )
            modelContext.insert(
                AdaptiveSetEntry(
                    adaptiveSessionId: session.id,
                    occurrenceId: target.occurrenceId,
                    exerciseId: target.exerciseId,
                    setIndex: 3,
                    weight: 20,
                    reps: 7,
                    isLocked: true
                )
            )
        }

        // Force the normal Adaptive exporter to replace the canonical file
        // for this completed session with a payload built from repaired rows.
        session.exportStatus = .pending
        modelContext.insert(
            TrainingPreference(
                key: july27AdaptiveInclineCurlRepairMarkerKey,
                modeRawValue: session.id.uuidString
            )
        )
        try modelContext.save()
        return July27AdaptiveInclineCurlRepairResult(
            sessionId: session.id,
            didApply: true
        )
    }

    private struct July27InclineCurlTarget {
        let occurrenceId: UUID
        let exerciseId: UUID
        let entries: [AdaptiveSetEntry]
    }

    private static func resolveJuly27InclineCurlTarget(
        plan: GeneratedWorkoutPlan,
        session: AdaptiveWorkoutSession,
        entries: [AdaptiveSetEntry],
        exercises: [Exercise]
    ) throws -> July27InclineCurlTarget? {
        guard let exercise = exercises.first(where: {
            $0.id == july27AdaptiveInclineCurlExerciseId
                && canonical($0.name) == canonical("Incline Curl")
        }) else {
            throw July27AdaptiveInclineCurlRepairError.inclineCurlExerciseMissing
        }
        let snapshots = plan.complexes
            .flatMap(\.exercises)
            .filter { $0.exerciseId == july27AdaptiveInclineCurlExerciseId }
        guard !snapshots.isEmpty else { return nil }
        guard snapshots.count == 1, let snapshot = snapshots.first else {
            throw July27AdaptiveInclineCurlRepairError.ambiguousInclineCurlOccurrences(
                count: snapshots.count
            )
        }
        let targetEntries = entries
            .filter {
                $0.adaptiveSessionId == session.id
                    && $0.occurrenceId == snapshot.occurrenceId
            }
            .sorted { lhs, rhs in
                if lhs.setIndex != rhs.setIndex { return lhs.setIndex < rhs.setIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return July27InclineCurlTarget(
            occurrenceId: snapshot.occurrenceId,
            exerciseId: exercise.id,
            entries: targetEntries
        )
    }

    private static func hasExactJuly27InclineCurlSets(
        _ entries: [AdaptiveSetEntry],
        exerciseId: UUID
    ) -> Bool {
        guard entries.count == 3 else { return false }
        return zip(entries, [13, 9, 7]).enumerated().allSatisfy { index, pair in
            let (entry, reps) = pair
            return entry.exerciseId == exerciseId
                && entry.setIndex == index + 1
                && entry.weight == 20
                && entry.reps == reps
                && entry.isLocked
        }
    }

    /// Explicit rollout only. Schema migration never assigns legacy history a
    /// new progression key and normal startup never selects this program.
    @discardableResult
    static func prepareClusteredProgramRollout(
        modelContext: ModelContext
    ) throws -> ClusteredProgramRolloutResult {
        do {
            let preferences = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<FixedCycleClusterPointer>())
            if let marker = preferences.first(where: { $0.key == clusteredProgramRolloutMarkerKey }) {
                let identifiers = marker.modeRawValue.split(separator: "|", omittingEmptySubsequences: false)
                guard identifiers.count == 2,
                      let templateId = UUID(uuidString: String(identifiers[0])),
                      let cycleId = UUID(uuidString: String(identifiers[1])),
                      let template = templates.first(where: { $0.id == templateId }),
                      FixedCycleClusterProgramService.isProgramTemplate(template),
                      let cycle = cycles.first(where: {
                          $0.id == cycleId && $0.templateId == template.id
                      }),
                      Set(states.filter {
                          $0.cycleInstanceId == cycle.id
                              && $0.templateId == template.id
                              && $0.programVersionID == FixedCycleClusterProgramService.programVersionID
                      }.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)) else {
                    throw ClusteredProgramRolloutError.completedRolloutStateMissing
                }
                return ClusteredProgramRolloutResult(
                    templateId: template.id,
                    cycleId: cycle.id,
                    didApply: false
                )
            }
            let recoveredProgramStates = states.filter {
                $0.programVersionID == FixedCycleClusterProgramService.programVersionID
            }
            let expectedClusterIDs = Set(
                FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)
            )
            let recoveredGroups = Dictionary(
                grouping: recoveredProgramStates,
                by: \.cycleInstanceId
            )
            guard recoveredProgramStates.isEmpty
                    || (recoveredGroups.count == 1
                        && Set(recoveredProgramStates.map(\.clusterID)) == expectedClusterIDs
                        && Set(recoveredProgramStates.map(\.templateId)).count == 1) else {
                throw ClusteredProgramRolloutError.existingRotationStateConflict
            }

            let sessions = try modelContext.fetch(FetchDescriptor<Session>())
            let entries = try modelContext.fetch(FetchDescriptor<SetEntry>())
            let clusterOccurrences = try modelContext.fetch(
                FetchDescriptor<FixedCycleProgressionOccurrence>()
            )
            for draft in sessions where draft.status == .draft {
                let draftEntries = entries.filter { $0.sessionId == draft.id }
                if draftEntries.contains(where: { $0.isLocked || $0.weight != 0 || $0.reps != 0 })
                    || clusterOccurrences.contains(where: { $0.sessionId == draft.id }) {
                    throw ClusteredProgramRolloutError.nonEmptyDraft(sessionId: draft.id)
                }
            }
            let adaptiveSessions = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
            let adaptiveEntries = try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
            for draft in adaptiveSessions where draft.status == .draft {
                if adaptiveEntries.contains(where: {
                    $0.adaptiveSessionId == draft.id
                        && ($0.isLocked || $0.weight != 0 || $0.reps != 0)
                }) {
                    throw ClusteredProgramRolloutError.nonEmptyDraft(sessionId: draft.id)
                }
            }

            // Keep catalog additions in the rollout transaction. If later
            // validation fails, rollback must remove every proposed change.
            let exercises = try ensureExerciseCatalog(
                modelContext: modelContext,
                saveChanges: false
            )
            let expected = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises)
            let template: CycleTemplate
            if let existing = templates.first(where: {
                $0.name.caseInsensitiveCompare(FixedCycleClusterProgramService.templateName) == .orderedSame
            }) {
                guard FixedCycleClusterProgramService.isProgramTemplate(existing),
                      clusteredTemplateStructure(existing) == clusteredTemplateStructure(expected) else {
                    throw ClusteredProgramRolloutError.existingTemplateConflict
                }
                template = existing
            } else {
                template = expected
                modelContext.insert(template)
            }

            let draftIds = Set(sessions.filter { $0.status == .draft }.map(\.id))
            for entry in entries where draftIds.contains(entry.sessionId) { modelContext.delete(entry) }
            for override in try modelContext.fetch(FetchDescriptor<SessionSlotOverride>())
            where draftIds.contains(override.sessionId) { modelContext.delete(override) }
            for override in try modelContext.fetch(FetchDescriptor<FixedCycleOccurrenceOverride>())
            where draftIds.contains(override.sessionId) { modelContext.delete(override) }
            for snapshot in try modelContext.fetch(FetchDescriptor<FixedCycleExerciseSnapshot>())
            where draftIds.contains(snapshot.sessionId) { modelContext.delete(snapshot) }
            for occurrence in clusterOccurrences
            where draftIds.contains(occurrence.sessionId) { modelContext.delete(occurrence) }
            for draft in sessions where draftIds.contains(draft.id) { modelContext.delete(draft) }

            let cycle: ActiveCycleInstance
            if let recovered = recoveredProgramStates.first,
               recovered.templateId == template.id,
               let existingCycle = cycles.first(where: {
                   $0.id == recovered.cycleInstanceId && $0.templateId == template.id
               }) {
                cycle = existingCycle
            } else if recoveredProgramStates.isEmpty {
                cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)
                modelContext.insert(cycle)
                for state in FixedCycleClusterProgramService.makeRotationStates(
                    cycleInstanceId: cycle.id,
                    templateId: template.id
                ) {
                    modelContext.insert(state)
                }
            } else {
                throw ClusteredProgramRolloutError.existingRotationStateConflict
            }
            let modeRows = preferences.filter { $0.key == TrainingModeService.activeModeKey }
            if let first = modeRows.first {
                first.modeRawValue = TrainingMode.rotation.rawValue
                for duplicate in modeRows.dropFirst() { modelContext.delete(duplicate) }
            } else {
                modelContext.insert(TrainingPreference(modeRawValue: TrainingMode.rotation.rawValue))
            }
            modelContext.insert(
                TrainingPreference(
                    key: clusteredProgramRolloutMarkerKey,
                    modeRawValue: "\(template.id.uuidString)|\(cycle.id.uuidString)"
                )
            )
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return ClusteredProgramRolloutResult(
                templateId: template.id,
                cycleId: cycle.id,
                didApply: true
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func clusteredTemplateStructure(_ template: CycleTemplate) -> [String] {
        CycleOrdering.sortedDays(template.days).flatMap { day in
            ["day|\(day.position)|\(day.label)"] + CycleOrdering.sortedSlots(day.slots).map {
                "slot|\($0.position)|\($0.muscle.rawValue)|\($0.exerciseId.uuidString)|\($0.defaultSetCount)"
            }
        }
    }

    static func pushPullABTemplate(
        exercises: [Exercise],
        sourceTemplate: CycleTemplate?,
        sourceAdaptiveProgram: AdaptiveProgram? = nil
    ) throws -> CycleTemplate {
        let byName = Dictionary(uniqueKeysWithValues: exercises.map {
            ($0.name.lowercased(), $0)
        })
        func required(_ name: String) throws -> Exercise {
            guard let value = byName[name.lowercased()] else {
                throw PushPullRolloutError.requiredExerciseMissing(name)
            }
            return value
        }

        let sourceDays = sourceTemplate.map { CycleOrdering.sortedDays($0.days) } ?? []
        func sourceSlots(_ muscle: MuscleGroup, variant: Int) -> [CycleSlot] {
            let adaptiveCandidates = sourceAdaptiveProgram?.complexes
                .filter(\.isEnabled)
                .sorted { $0.position < $1.position }
                .flatMap { complex in
                    complex.components.sorted { $0.position < $1.position }
                }
                .filter { component in
                    component.primaryMuscle == muscle
                        && exercises.contains(where: { $0.id == component.exerciseId })
                }
                .reduce(into: [AdaptiveComplexComponent]()) { result, component in
                    guard !result.contains(where: { $0.exerciseId == component.exerciseId }) else {
                        return
                    }
                    result.append(component)
                } ?? []
            if !adaptiveCandidates.isEmpty {
                return adaptiveCandidates.map {
                    CycleSlot(
                        muscle: muscle,
                        exerciseId: $0.exerciseId,
                        defaultSetCount: min(3, max(1, $0.prescribedSetCount))
                    )
                }
            }
            let suffix = variant % 2 == 0 ? "a" : "b"
            let variantDays = sourceDays.filter {
                canonical($0.label).hasSuffix(suffix)
            }
            let candidates = (variantDays.isEmpty ? sourceDays : variantDays)
                .flatMap { CycleOrdering.sortedSlots($0.slots) }
                .filter { $0.muscle == muscle }
            let unique = candidates.reduce(into: [CycleSlot]()) { result, slot in
                guard !result.contains(where: { $0.exerciseId == slot.exerciseId }) else { return }
                result.append(slot)
            }
            if !unique.isEmpty { return unique }
            guard let fallback = exercises
                .filter({ $0.isActive && $0.primaryMuscle == muscle })
                .sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
                .first else {
                return []
            }
            return [CycleSlot(muscle: muscle, exerciseId: fallback.id)]
        }

        func copied(
            _ muscle: MuscleGroup,
            variant: Int,
            position: inout Int
        ) -> [CycleSlot] {
            sourceSlots(muscle, variant: variant).map { source in
                defer { position += 1 }
                return CycleSlot(
                    position: position,
                    muscle: muscle,
                    exerciseId: source.exerciseId,
                    defaultSetCount: source.defaultSetCount
                )
            }
        }

        func pullDay(label: String, variant: Int, reversedBack: Bool) throws -> CycleDay {
            let pulldown = try required("Lat Pulldown")
            let cableRow = try required("Chest-Supported Cable Row")
            let back = reversedBack ? [cableRow, pulldown] : [pulldown, cableRow]
            var position = 0
            var slots = back.map { exercise -> CycleSlot in
                defer { position += 1 }
                return CycleSlot(position: position, muscle: .back, exerciseId: exercise.id)
            }
            slots += copied(.biceps, variant: variant, position: &position)
            slots += copied(.hamstrings, variant: variant, position: &position)
            slots += copied(.forearms, variant: variant, position: &position)
            return CycleDay(label: label, slots: slots)
        }

        func pushDay(label: String, variant: Int) throws -> CycleDay {
            let chest = variant == 0
                ? [try required("Incline Dumbbell Press"), try required("Flat Cable Flye")]
                : [try required("Flat Dumbbell Press"), try required("Incline Cable Flye")]
            var position = 0
            var slots = chest.map { exercise -> CycleSlot in
                defer { position += 1 }
                return CycleSlot(position: position, muscle: .chest, exerciseId: exercise.id)
            }
            slots += copied(.triceps, variant: variant, position: &position)
            slots += copied(.quads, variant: variant, position: &position)
            slots += copied(.sideDelts, variant: variant, position: &position)
            slots += copied(.calves, variant: variant, position: &position)
            return CycleDay(label: label, slots: slots)
        }

        let days = [
            try pullDay(label: "Pull A", variant: 0, reversedBack: false),
            try pushDay(label: "Push A", variant: 0),
            try pullDay(label: "Pull B", variant: 1, reversedBack: true),
            try pushDay(label: "Push B", variant: 1)
        ]
        for (index, day) in days.enumerated() { day.position = index }
        let template = CycleTemplate(
            name: pushPullABTemplateName,
            days: days,
            // Pools are copied intact. Slots remain day-scoped direct choices,
            // so later edits cannot leak into another day through a shared pool.
            rotationPools: sourceTemplate?.rotationPools.map { pool in
                RotationPool(
                    key: pool.key,
                    entries: pool.entries.map { RotationPoolEntry(exerciseId: $0.exerciseId) }
                )
            } ?? []
        )
        try template.validate(
            exercisesById: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        )
        return template
    }

    static func defaultStarterTemplate(exercises: [Exercise]) throws -> CycleTemplate {
        let exercisesByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name.lowercased(), $0) })

        func exercise(named name: String) throws -> Exercise {
            guard let exercise = exercisesByName[name.lowercased()] else {
                throw NSError(
                    domain: "OpenLiftBootstrapDataService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Starter template exercise '\(name)' not found."]
                )
            }
            return exercise
        }

        let upperA = CycleDay(
            label: "Upper A",
            slots: [
                CycleSlot(position: 0, muscle: .chest, exerciseId: try exercise(named: "Flat Dumbbell Press").id),
                CycleSlot(position: 1, muscle: .back, exerciseId: try exercise(named: "Single-Arm Dumbbell Row").id),
                CycleSlot(position: 2, muscle: .back, exerciseId: try exercise(named: "Assisted Pull-Up").id),
                CycleSlot(position: 3, muscle: .sideDelts, exerciseId: try exercise(named: "Cable Crossover Lateral Raise").id),
                CycleSlot(position: 4, muscle: .triceps, exerciseId: try exercise(named: "Assisted Dips").id),
                CycleSlot(position: 5, muscle: .biceps, exerciseId: try exercise(named: "Incline Curl").id)
            ],
            position: 0
        )
        let lowerA = CycleDay(
            label: "Lower A",
            slots: [
                CycleSlot(position: 0, muscle: .quads, exerciseId: try exercise(named: "Pendulum Squat").id),
                CycleSlot(position: 1, muscle: .hamstrings, exerciseId: try exercise(named: "Stiff-Leg Deadlift").id),
                CycleSlot(position: 2, muscle: .quads, exerciseId: try exercise(named: "Leg Press").id),
                CycleSlot(position: 3, muscle: .hamstrings, exerciseId: try exercise(named: "Leg Curl").id)
            ],
            position: 1
        )
        let upperB = CycleDay(
            label: "Upper B",
            slots: [
                CycleSlot(position: 0, muscle: .chest, exerciseId: try exercise(named: "Incline Dumbbell Press").id),
                CycleSlot(position: 1, muscle: .back, exerciseId: try exercise(named: "Chest Supported Row").id),
                CycleSlot(position: 2, muscle: .back, exerciseId: try exercise(named: "Lat Pulldown").id),
                CycleSlot(position: 3, muscle: .sideDelts, exerciseId: try exercise(named: "Dumbbell Lateral Raise").id),
                CycleSlot(position: 4, muscle: .triceps, exerciseId: try exercise(named: "Dumbbell Skullcrusher").id),
                CycleSlot(position: 5, muscle: .biceps, exerciseId: try exercise(named: "EZ Bar Curl").id)
            ],
            position: 2
        )
        let lowerB = CycleDay(
            label: "Lower B",
            slots: [
                CycleSlot(position: 0, muscle: .quads, exerciseId: try exercise(named: "Hack Squat").id),
                CycleSlot(position: 1, muscle: .hamstrings, exerciseId: try exercise(named: "Romanian Deadlift").id),
                CycleSlot(position: 2, muscle: .quads, exerciseId: try exercise(named: "Bulgarian Split Squat").id),
                CycleSlot(position: 3, muscle: .hamstrings, exerciseId: try exercise(named: "Lying Leg Curl").id)
            ],
            position: 3
        )

        let template = CycleTemplate(
            name: "4D Upper/Lower",
            days: [upperA, lowerA, upperB, lowerB],
            rotationPools: []
        )
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        try template.validate(exercisesById: exercisesById)
        return template
    }

    static func buildDebugSnapshot(
        exercises: [Exercise],
        templates: [CycleTemplate],
        activeCycles: [ActiveCycleInstance],
        sessions: [Session],
        latestExportCycleDayIndex: Int?
    ) -> DebugSnapshot {
        let completed = sessions.filter { $0.status == .completed }
        let draft = sessions.filter { $0.status == .draft }
        let latestCompletedDay = completed
            .sorted(by: { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) })
            .first?
            .cycleDayIndex
        let dayCount = max(templates.first?.days.count ?? 1, 1)
        let inferred = inferredNextDayIndex(
            dayCount: dayCount,
            sessions: sessions,
            latestExportCycleDayIndex: latestExportCycleDayIndex
        )

        return DebugSnapshot(
            exerciseCount: exercises.count,
            templateCount: templates.count,
            activeCycleCount: activeCycles.count,
            sessionCount: sessions.count,
            completedSessionCount: completed.count,
            draftSessionCount: draft.count,
            latestCompletedDayIndex: latestCompletedDay,
            latestExportDayIndex: latestExportCycleDayIndex,
            inferredNextDayIndex: inferred
        )
    }

    private static func canonical(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func matchingPublishedCycle(
        named templateName: String,
        from published: [PublishedCycleFile]
    ) -> PublishedCycleFile? {
        let target = canonical(templateName)
        return published.first(where: { candidate in
            let candidateName = canonical(candidate.name)
            return candidateName == target || candidateName.contains(target) || target.contains(candidateName)
        })
    }

    private static func normalizedNonEmptyName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static let defaultExerciseCatalog: [(String, MuscleGroup, ExerciseType, EquipmentType)] = [
        ("Machine Chest Press", .chest, .compound, .machine),
        ("Incline Dumbbell Press", .chest, .compound, .dumbbell),
        ("Flat Dumbbell Press", .chest, .compound, .dumbbell),
        ("Cable Fly", .chest, .isolation, .cable),
        ("Flat Cable Flye", .chest, .isolation, .cable),
        ("Incline Cable Flye", .chest, .isolation, .cable),
        ("Incline Dumbbell Press-Flye", .chest, .compound, .dumbbell),
        ("Cable Row", .back, .compound, .cable),
        ("Lat Pulldown", .back, .compound, .cable),
        ("Chest Supported Row", .back, .compound, .machine),
        ("Chest-Supported Cable Row", .back, .compound, .cable),
        ("Helms Row", .back, .compound, .dumbbell),
        ("Single-Arm Dumbbell Row", .back, .compound, .dumbbell),
        ("Assisted Pull-Up", .back, .compound, .machine),
        ("Lat Prayer", .back, .isolation, .cable),
        ("Hack Squat", .quads, .compound, .machine),
        ("Leg Press", .quads, .compound, .machine),
        ("Safety Squat Bar Squat", .quads, .compound, .barbell),
        ("Leg Extension", .quads, .isolation, .machine),
        ("Bulgarian Split Squat", .quads, .compound, .dumbbell),
        ("Pendulum Squat", .quads, .compound, .machine),
        ("Belt Squat", .quads, .compound, .machine),
        ("Sumo Belt Squat", .quads, .compound, .machine),
        ("Seated Leg Curl", .hamstrings, .isolation, .machine),
        ("Leg Curl", .hamstrings, .isolation, .machine),
        ("Romanian Deadlift", .hamstrings, .compound, .barbell),
        ("Stiff-Leg Deadlift", .hamstrings, .compound, .barbell),
        ("Glute-Ham Raise", .hamstrings, .compound, .bodyweight),
        ("Reverse Hyper", .hamstrings, .isolation, .machine),
        ("Lying Leg Curl", .hamstrings, .isolation, .machine),
        ("Back Extension", .hamstrings, .compound, .bodyweight),
        ("Dumbbell Curl", .biceps, .isolation, .dumbbell),
        ("Incline Curl", .biceps, .isolation, .dumbbell),
        ("Dumbbell Preacher Curl", .biceps, .isolation, .dumbbell),
        ("Cable Curl", .biceps, .isolation, .cable),
        ("Bayesian Curl", .biceps, .isolation, .cable),
        ("EZ Bar Curl", .biceps, .isolation, .barbell),
        ("Cable Pushdown", .triceps, .isolation, .cable),
        ("Assisted Dips", .triceps, .compound, .machine),
        ("Dumbbell Skullcrusher", .triceps, .isolation, .dumbbell),
        ("Overhead Dumbbell Extension", .triceps, .isolation, .dumbbell),
        ("Overhead EZ Bar Extension", .triceps, .isolation, .barbell),
        ("Overhead Cable Extension", .triceps, .isolation, .cable),
        ("Skull Crusher", .triceps, .isolation, .barbell),
        ("Cable Lateral Raise", .sideDelts, .isolation, .cable),
        ("Cable Crossover Lateral Raise", .sideDelts, .isolation, .cable),
        ("Super ROM Dumbbell Lateral Raise", .sideDelts, .isolation, .dumbbell),
        ("Arnold Lateral Raise", .sideDelts, .isolation, .dumbbell),
        ("Dumbbell Lateral Raise", .sideDelts, .isolation, .dumbbell),
        ("Machine Lateral Raise", .sideDelts, .isolation, .machine),
        ("Reverse Curl", .forearms, .isolation, .barbell),
        ("Bench-Supported Cable Wrist Curl (Supinated)", .forearms, .isolation, .cable),
        ("Bench-Supported Cable Wrist Extension (Pronated)", .forearms, .isolation, .cable),
        ("Captains of Crush", .forearms, .isolation, .bodyweight),
        ("Hip Thrust", .glutes, .compound, .barbell),
        ("Standing Calf Raise", .calves, .isolation, .machine),
        ("Stair Calves", .calves, .isolation, .bodyweight)
    ]
}

enum FixedCycleClusterProgramService {
    enum Cluster: String, CaseIterable, Hashable {
        case cluster1 = "cluster-1"
        case cluster2 = "cluster-2"
        case cluster3 = "cluster-3"

        var displayName: String {
            switch self {
            case .cluster1: return "Cluster 1"
            case .cluster2: return "Cluster 2"
            case .cluster3: return "Cluster 3"
            }
        }

        var rotationLength: Int {
            switch self {
            case .cluster1: return 3
            case .cluster2, .cluster3: return 6
            }
        }

        var templateBasePosition: Int {
            switch self {
            case .cluster1: return 0
            case .cluster2: return 3
            case .cluster3: return 9
            }
        }
    }

    enum ProgramError: LocalizedError, Equatable {
        case requiredExerciseMissing(String)
        case missingClusterPointer(Cluster)
        case invalidClusterContext

        var errorDescription: String? {
            switch self {
            case .requiredExerciseMissing(let name):
                return "Required clustered-program exercise '\(name)' is missing from the catalog."
            case .missingClusterPointer(let cluster):
                return "The independent pointer for \(cluster.displayName) is missing."
            case .invalidClusterContext:
                return "The workout's versioned cluster context is invalid."
            }
        }
    }

    struct Selection: Identifiable {
        let cluster: Cluster
        let cycleInstanceId: UUID
        let templateId: UUID
        let absoluteStep: Int
        let effectiveStep: Int
        let day: CycleDay

        var id: String { cluster.rawValue }
    }

    struct ActivationCleanupPlan: Equatable {
        let pointerIDs: Set<UUID>
        let contextIDs: Set<UUID>
    }

    static let programIdentifier = "openlift.clustered-hypertrophy"
    static let structureVersion = 1
    static let programVersionID = "\(programIdentifier).v\(structureVersion)"
    static let templateName = "Clustered Hypertrophy v1"
    static let templateIdentityKey = RotationPoolKey.clusteredHypertrophyV1.rawValue

    static func activationCleanupPlan(
        existingCycles: [ActiveCycleInstance],
        pointers: [FixedCycleClusterPointer],
        contexts: [FixedCycleSessionContext],
        sessions: [Session]
    ) -> ActivationCleanupPlan {
        let removedCycleIDs = Set(existingCycles.map(\.id))
        let knownSessionIDs = Set(sessions.map(\.id))
        let draftSessionIDs = Set(sessions.filter { $0.status == .draft }.map(\.id))
        return ActivationCleanupPlan(
            pointerIDs: Set(pointers.compactMap {
                removedCycleIDs.contains($0.cycleInstanceId) ? $0.id : nil
            }),
            contextIDs: Set(contexts.compactMap {
                draftSessionIDs.contains($0.sessionId)
                    || !knownSessionIDs.contains($0.sessionId) ? $0.id : nil
            })
        )
    }

    static func defaultResistanceProfile(
        forExerciseNamed exerciseName: String
    ) -> ResistanceProfileValue? {
        guard exerciseName == "Bench-Supported Cable Wrist Extension (Pronated)" else {
            return nil
        }
        return .voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
    }

    static func isProgramTemplate(_ template: CycleTemplate?) -> Bool {
        guard let template,
              template.rotationPools.contains(where: {
                  $0.key == templateIdentityKey && $0.entries.isEmpty
              }) else { return false }
        let expectedDays: [(Int, String, [(Int, MuscleGroup)])] = [
            (0, "Cluster 1 · A", [(0, .chest), (1, .back)]),
            (1, "Cluster 1 · B", [(0, .chest), (1, .back)]),
            (2, "Cluster 1 · C", [(0, .chest), (1, .back)]),
            (3, "Cluster 2 · A", [(0, .quads), (1, .triceps), (2, .biceps)]),
            (4, "Cluster 2 · B", [(0, .hamstrings), (1, .triceps), (2, .biceps)]),
            (5, "Cluster 2 · C", [(0, .quads), (1, .triceps), (2, .biceps)]),
            (6, "Cluster 2 · D", [(0, .hamstrings), (1, .triceps), (2, .biceps)]),
            (7, "Cluster 2 · E", [(0, .quads), (1, .triceps), (2, .biceps)]),
            (8, "Cluster 2 · F", [(0, .hamstrings), (1, .triceps), (2, .biceps)]),
            (9, "Cluster 3 · A", [(0, .sideDelts), (1, .calves)]),
            (10, "Cluster 3 · B", [(0, .sideDelts), (1, .forearms)]),
            (11, "Cluster 3 · C", [(0, .sideDelts), (1, .calves)]),
            (12, "Cluster 3 · D", [(0, .sideDelts), (1, .forearms)]),
            (13, "Cluster 3 · E", [(0, .sideDelts), (1, .calves)]),
            (14, "Cluster 3 · F", [(0, .sideDelts), (1, .forearms)])
        ]
        let actualDays = CycleOrdering.sortedDays(template.days)
        guard actualDays.count == expectedDays.count else { return false }
        return zip(actualDays, expectedDays).allSatisfy { day, expected in
            let slots = CycleOrdering.sortedSlots(day.slots)
            return day.position == expected.0
                && day.label == expected.1
                && slots.count == expected.2.count
                && zip(slots, expected.2).allSatisfy { slot, role in
                    slot.position == role.0
                        && slot.muscle == role.1
                        && slot.defaultSetCount == 3
                }
        }
    }

    static func makeTemplate(exercises: [Exercise]) throws -> CycleTemplate {
        let byName = Dictionary(exercises.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func required(_ candidates: [String]) throws -> Exercise {
            for candidate in candidates {
                if let exercise = byName[candidate.lowercased()] { return exercise }
            }
            throw ProgramError.requiredExerciseMissing(candidates[0])
        }
        func slot(_ position: Int, _ muscle: MuscleGroup, _ candidates: [String]) throws -> CycleSlot {
            CycleSlot(
                position: position,
                muscle: muscle,
                exerciseId: try required(candidates).id,
                defaultSetCount: 3
            )
        }
        func day(_ cluster: Cluster, _ step: Int, _ slots: [CycleSlot]) -> CycleDay {
            CycleDay(
                label: "\(cluster.displayName) · \(variantLabel(step))",
                slots: slots,
                position: cluster.templateBasePosition + step
            )
        }

        let cluster1 = try [
            day(.cluster1, 0, [
                slot(0, .chest, ["Incline Dumbbell Press"]),
                slot(1, .back, ["Lat Pulldown"])
            ]),
            day(.cluster1, 1, [
                slot(0, .chest, ["Flat Dumbbell Press"]),
                slot(1, .back, ["Lat Prayer"])
            ]),
            day(.cluster1, 2, [
                slot(0, .chest, ["Incline Press-Flye", "Incline Dumbbell Press-Flye"]),
                slot(1, .back, ["Chest Supported Row", "Chest-Supported Cable Row"])
            ])
        ]
        let cluster2 = try [
            day(.cluster2, 0, [
                slot(0, .quads, ["Belt Squat"]),
                slot(1, .triceps, ["Overhead Cable Extension", "Overhead Single-Arm Cable Extension"]),
                slot(2, .biceps, ["Incline Curl"])
            ]),
            day(.cluster2, 1, [
                slot(0, .hamstrings, ["Stiff-Leg Deadlift"]),
                slot(1, .triceps, ["Cable Pushdown"]),
                slot(2, .biceps, ["Dumbbell Preacher Curl"])
            ]),
            day(.cluster2, 2, [
                slot(0, .quads, ["Sumo Belt Squat"]),
                slot(1, .triceps, ["Dumbbell Skullcrusher"]),
                slot(2, .biceps, ["Bayesian Curl"])
            ]),
            day(.cluster2, 3, [
                slot(0, .hamstrings, ["Back Extension"]),
                slot(1, .triceps, ["Overhead Cable Extension", "Overhead Single-Arm Cable Extension"]),
                slot(2, .biceps, ["Incline Curl"])
            ]),
            day(.cluster2, 4, [
                slot(0, .quads, ["Bulgarian Split Squat"]),
                slot(1, .triceps, ["Cable Pushdown"]),
                slot(2, .biceps, ["Dumbbell Preacher Curl"])
            ]),
            day(.cluster2, 5, [
                slot(0, .hamstrings, ["Leg Curl"]),
                slot(1, .triceps, ["Dumbbell Skullcrusher"]),
                slot(2, .biceps, ["Bayesian Curl"])
            ])
        ]
        let cluster3 = try [
            day(.cluster3, 0, [
                slot(0, .sideDelts, ["Super ROM Dumbbell Lateral Raise"]),
                slot(1, .calves, ["Stair Calves"])
            ]),
            day(.cluster3, 1, [
                slot(0, .sideDelts, ["Cable Lateral Raise"]),
                slot(1, .forearms, ["Bench-Supported Cable Wrist Curl (Supinated)"])
            ]),
            day(.cluster3, 2, [
                slot(0, .sideDelts, ["Super ROM Dumbbell Lateral Raise"]),
                slot(1, .calves, ["Stair Calves"])
            ]),
            day(.cluster3, 3, [
                slot(0, .sideDelts, ["Cable Lateral Raise"]),
                slot(1, .forearms, ["Bench-Supported Cable Wrist Extension (Pronated)"])
            ]),
            day(.cluster3, 4, [
                slot(0, .sideDelts, ["Super ROM Dumbbell Lateral Raise"]),
                slot(1, .calves, ["Stair Calves"])
            ]),
            day(.cluster3, 5, [
                slot(0, .sideDelts, ["Cable Lateral Raise"]),
                slot(1, .forearms, ["Captain of Crush", "Captains of Crush"])
            ])
        ]
        let template = CycleTemplate(
            name: templateName,
            days: cluster1 + cluster2 + cluster3,
            rotationPools: [RotationPool(key: templateIdentityKey, entries: [])]
        )
        try template.validate(
            exercisesById: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        )
        return template
    }

    static func makeRotationStates(
        cycleInstanceId: UUID,
        templateId: UUID
    ) -> [FixedCycleClusterPointer] {
        Cluster.allCases.map {
            FixedCycleClusterPointer(
                cycleInstanceId: cycleInstanceId,
                templateId: templateId,
                programVersionID: programVersionID,
                clusterID: $0.rawValue,
                completedCount: 0
            )
        }
    }

    static func selections(
        template: CycleTemplate,
        cycleInstanceId: UUID,
        states: [FixedCycleClusterPointer]
    ) throws -> [Selection] {
        guard isProgramTemplate(template) else { return [] }
        return try Cluster.allCases.map {
            try selection(
                cluster: $0,
                template: template,
                cycleInstanceId: cycleInstanceId,
                states: states
            )
        }
    }

    static func selection(
        cluster: Cluster,
        template: CycleTemplate,
        cycleInstanceId: UUID,
        states: [FixedCycleClusterPointer]
    ) throws -> Selection {
        guard isProgramTemplate(template),
              let state = states.first(where: {
                  $0.cycleInstanceId == cycleInstanceId
                      && $0.templateId == template.id
                      && $0.programVersionID == programVersionID
                      && $0.clusterID == cluster.rawValue
              }) else { throw ProgramError.missingClusterPointer(cluster) }
        let absoluteStep = max(0, state.positionIndex)
        let effectiveStep = absoluteStep % cluster.rotationLength
        let position = cluster.templateBasePosition + effectiveStep
        guard let day = template.days.first(where: { $0.position == position }) else {
            throw ProgramError.invalidClusterContext
        }
        return Selection(
            cluster: cluster,
            cycleInstanceId: cycleInstanceId,
            templateId: template.id,
            absoluteStep: absoluteStep,
            effectiveStep: effectiveStep,
            day: day
        )
    }

    static func makeSessionContext(
        session: Session,
        selection: Selection,
        exercises: [Exercise]
    ) throws -> FixedCycleSessionContext {
        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let snapshots = try CycleOrdering.sortedSlots(selection.day.slots).map { slot in
            guard let exercise = byID[slot.exerciseId] else {
                throw ProgramError.invalidClusterContext
            }
            return FixedCycleProgressionSnapshot(
                position: slot.position,
                exerciseId: exercise.id,
                exerciseName: exercise.name,
                muscle: slot.muscle,
                prescribedSetCount: slot.defaultSetCount,
                progressionKey: progressionKey(
                    cluster: selection.cluster,
                    effectiveStep: selection.effectiveStep,
                    slotPosition: slot.position
                ),
                resistanceProfile: nil,
                completionStatus: .skipped
            )
        }
        return try FixedCycleSessionContext(
            sessionId: session.id,
            cycleInstanceId: selection.cycleInstanceId,
            templateId: selection.templateId,
            programVersionID: programVersionID,
            clusterID: selection.cluster.rawValue,
            absoluteStep: selection.absoluteStep,
            templateDayPosition: selection.day.position,
            dayLabel: selection.day.label,
            exerciseSnapshots: snapshots
        )
    }

    static func makeOccurrence(
        session: Session,
        selection: Selection,
        context: FixedCycleSessionContext,
        exercises: [Exercise],
        entries: [SetEntry],
        resistanceProfiles: [ExerciseResistanceProfile],
        completedAt: Date = .now
    ) throws -> FixedCycleProgressionOccurrence {
        guard context.sessionId == session.id,
              context.cycleInstanceId == selection.cycleInstanceId,
              context.templateId == selection.templateId,
              context.programVersionID == programVersionID,
              context.clusterID == selection.cluster.rawValue,
              context.absoluteStep == selection.absoluteStep else {
            throw ProgramError.invalidClusterContext
        }
        let snapshots: [FixedCycleProgressionSnapshot] = context.exerciseSnapshots.map { snapshot in
            let performed = entries.contains {
                $0.sessionId == session.id
                    && $0.exerciseId == snapshot.exerciseId
                    && $0.isLocked
                    && $0.reps > 0
            }
            let resistanceProfile = (try? ResistanceProfileService.profile(
                workoutKind: .fixed,
                sessionId: session.id,
                exerciseId: snapshot.exerciseId,
                occurrenceId: nil,
                in: resistanceProfiles
            )).flatMap(ResistanceProfileService.value)
            return FixedCycleProgressionSnapshot(
                position: snapshot.position,
                exerciseId: snapshot.exerciseId,
                exerciseName: snapshot.exerciseName,
                muscle: snapshot.muscle,
                prescribedSetCount: snapshot.prescribedSetCount,
                progressionKey: snapshot.progressionKey,
                resistanceProfile: resistanceProfile,
                completionStatus: performed ? .performed : .skipped
            )
        }
        guard !snapshots.isEmpty else {
            throw ProgramError.invalidClusterContext
        }
        return try FixedCycleProgressionOccurrence(
            sessionId: session.id,
            cycleInstanceId: context.cycleInstanceId,
            templateId: context.templateId,
            programVersionID: programVersionID,
            clusterID: selection.cluster.rawValue,
            absoluteStep: selection.absoluteStep,
            templateDayPosition: context.templateDayPosition,
            dayLabel: context.dayLabel,
            completedAt: completedAt,
            exerciseSnapshots: snapshots
        )
    }

    /// Convenience for service-level callers that do not persist drafts. The
    /// app's workout flow always persists and passes FixedCycleSessionContext.
    static func makeOccurrence(
        session: Session,
        selection: Selection,
        exercises: [Exercise],
        entries: [SetEntry],
        resistanceProfiles: [ExerciseResistanceProfile],
        completedAt: Date = .now
    ) throws -> FixedCycleProgressionOccurrence {
        let context = try makeSessionContext(
            session: session,
            selection: selection,
            exercises: exercises
        )
        return try makeOccurrence(
            session: session,
            selection: selection,
            context: context,
            exercises: exercises,
            entries: entries,
            resistanceProfiles: resistanceProfiles,
            completedAt: completedAt
        )
    }

    static func progressionKey(
        cluster: Cluster,
        effectiveStep: Int,
        slotPosition: Int
    ) -> String {
        let identityStep: Int
        let role: String
        switch cluster {
        case .cluster1:
            identityStep = effectiveStep % 3
            role = slotPosition == 0 ? "chest" : "back"
        case .cluster2:
            identityStep = slotPosition == 0 ? effectiveStep % 6 : effectiveStep % 3
            role = slotPosition == 0 ? "legs" : (slotPosition == 1 ? "triceps" : "biceps")
        case .cluster3:
            identityStep = slotPosition == 0 ? effectiveStep % 2 : effectiveStep % 6
            role = slotPosition == 0 ? "shoulders" : "calves-forearms"
        }
        return "\(programIdentifier).v\(structureVersion).\(cluster.rawValue).\(role).\(variantLabel(identityStep).lowercased())"
    }

    @discardableResult
    static func advanceCompletedCluster(
        selection: Selection,
        occurrence: FixedCycleProgressionOccurrence,
        states: [FixedCycleClusterPointer]
    ) throws -> FixedCycleClusterPointer {
        guard occurrence.programVersionID == programVersionID,
              occurrence.clusterID == selection.cluster.rawValue,
              occurrence.positionIndex == selection.absoluteStep,
              let state = states.first(where: {
                  $0.cycleInstanceId == selection.cycleInstanceId
                      && $0.templateId == selection.templateId
                      && $0.programVersionID == programVersionID
                      && $0.clusterID == selection.cluster.rawValue
              }),
              state.positionIndex == selection.absoluteStep else {
            throw ProgramError.invalidClusterContext
        }
        state.positionIndex += 1
        state.updatedAt = occurrence.completedAt
        state.lastCompletedOccurrenceID = occurrence.id
        state.isDerived = false
        return state
    }

    static func occurrence(
        sessionID: UUID,
        cluster: Cluster,
        occurrences: [FixedCycleProgressionOccurrence]
    ) -> FixedCycleProgressionOccurrence? {
        occurrences.first {
            $0.sessionId == sessionID
                && $0.programVersionID == programVersionID
                && $0.clusterID == cluster.rawValue
        }
    }

    static func variantLabel(_ index: Int) -> String {
        String(UnicodeScalar(65 + max(0, index))!)
    }
}
