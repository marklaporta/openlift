import Foundation
import SwiftData

enum BootstrapDataService {
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

    static func ensureExerciseCatalog(modelContext: ModelContext) throws -> [Exercise] {
        var currentExercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let currentNames = Set(currentExercises.map { $0.name.lowercased() })

        var inserted = false
        for entry in defaultExerciseCatalog where !currentNames.contains(entry.0.lowercased()) {
            let exercise = Exercise(name: entry.0, primaryMuscle: entry.1, type: entry.2, equipment: entry.3)
            modelContext.insert(exercise)
            inserted = true
        }

        if inserted {
            try modelContext.save()
            currentExercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        }

        return currentExercises
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

        if let iCloudDir = fileManager.url(forUbiquityContainerIdentifier: nil)?
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
        var sessionsById: [UUID: Session] = [:]
        for session in try modelContext.fetch(FetchDescriptor<Session>()) {
            sessionsById[session.id] = session
        }
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

        var result = WorkoutImportResult()

        for export in exports {
            guard let sessionId = UUID(uuidString: export.session_id),
                  let finishedAt = SessionExportService.parseExportDate(export.date) else { continue }

            let session: Session
            if let existing = sessionsById[sessionId] {
                session = existing
                result.skippedExisting += 1
                guard export.workout_kind == "ad_hoc" else { continue }
            } else {
                session = Session(
                    id: sessionId,
                    cycleInstanceId: cycle.id,
                    cycleDayIndex: export.cycle_day_index,
                    cycleNameSnapshot: export.cycle_name,
                    dayLabelSnapshot: export.workout_kind == "ad_hoc"
                        ? "Off-Schedule"
                        : "Day \(export.cycle_day_index + 1)",
                    createdAt: finishedAt.addingTimeInterval(-60),
                    finishedAt: finishedAt,
                    status: .completed,
                    exportStatus: .success
                )
                try session.validate()
                modelContext.insert(session)
                sessionsById[sessionId] = session
                result.imported += 1
            }

            if export.workout_kind == "ad_hoc" {
                session.cycleNameSnapshot = export.cycle_name
                session.dayLabelSnapshot = "Off-Schedule"
            }

            for exportExercise in export.exercises {
                guard let exercise = exercisesByName[exportExercise.exercise_name.lowercased()] else {
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
                            isLocked: true
                        )
                        try entry.validate()
                        modelContext.insert(entry)
                        entriesByKey[key] = entry
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
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        return result
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
        ("Cable Row", .back, .compound, .cable),
        ("Lat Pulldown", .back, .compound, .machine),
        ("Chest Supported Row", .back, .compound, .machine),
        ("Helms Row", .back, .compound, .dumbbell),
        ("Single-Arm Dumbbell Row", .back, .compound, .dumbbell),
        ("Assisted Pull-Up", .back, .compound, .machine),
        ("Hack Squat", .quads, .compound, .machine),
        ("Leg Press", .quads, .compound, .machine),
        ("Safety Squat Bar Squat", .quads, .compound, .barbell),
        ("Leg Extension", .quads, .isolation, .machine),
        ("Bulgarian Split Squat", .quads, .compound, .dumbbell),
        ("Pendulum Squat", .quads, .compound, .machine),
        ("Belt Squat", .quads, .compound, .machine),
        ("Seated Leg Curl", .hamstrings, .isolation, .machine),
        ("Leg Curl", .hamstrings, .isolation, .machine),
        ("Romanian Deadlift", .hamstrings, .compound, .barbell),
        ("Stiff-Leg Deadlift", .hamstrings, .compound, .barbell),
        ("Glute-Ham Raise", .hamstrings, .compound, .bodyweight),
        ("Reverse Hyper", .hamstrings, .isolation, .machine),
        ("Lying Leg Curl", .hamstrings, .isolation, .machine),
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
        ("Hip Thrust", .glutes, .compound, .barbell),
        ("Standing Calf Raise", .calves, .isolation, .machine)
    ]
}
