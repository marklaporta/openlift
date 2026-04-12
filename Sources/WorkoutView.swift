import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var templates: [CycleTemplate]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @Query private var setEntries: [SetEntry]
    @Query private var slotOverrides: [SessionSlotOverride]

    @State private var errorMessage: String?
    @State private var draftExportTask: Task<Void, Never>?
    @State private var swapContext: SwapContext?
    @State private var historyContext: ExerciseHistoryContext?

    private var activeCycle: ActiveCycleInstance? {
        OpenLiftStateResolver.activeCycle(
            activeCycles: activeCycles,
            templates: templates,
            sessions: sessions,
            latestExport: nil,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:))
        )
    }

    private var activeTemplate: CycleTemplate? {
        OpenLiftStateResolver.activeTemplate(
            activeCycles: activeCycles,
            templates: templates,
            sessions: sessions,
            latestExport: nil,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:))
        )
    }

    private var draftSession: Session? {
        OpenLiftStateResolver.preferredDraftSession(
            sessions: sessions,
            activeCycle: activeCycle
        )
    }

    private var activeDay: CycleDay? {
        guard let cycle = activeCycle, let template = activeTemplate else { return nil }
        let orderedDays = CycleOrdering.sortedDays(template.days)
        guard cycle.currentDayIndex >= 0, cycle.currentDayIndex < orderedDays.count else { return nil }
        return orderedDays[cycle.currentDayIndex]
    }

    var body: some View {
        NavigationStack {
            List {
                if let draftSession, let activeDay {
                    Section {
                        Text("\(activeDay.label) · Draft session")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    ForEach(resolvedSlots(for: activeDay, sessionId: draftSession.id)) { resolved in
                        let resolvedExercise = exercises.first(where: { $0.id == resolved.exerciseId })
                        ExerciseSection(
                            slot: resolved.slot,
                            exercise: resolvedExercise,
                            entries: entries(for: resolved.exerciseId, sessionId: draftSession.id),
                            onAddSet: { addSet(for: resolved.exerciseId, sessionId: draftSession.id) },
                            onRemoveSet: { removeSet(for: resolved.exerciseId, sessionId: draftSession.id) },
                            onSwap: {
                                swapContext = SwapContext(
                                    sessionId: draftSession.id,
                                    slot: resolved.slot,
                                    currentExerciseId: resolved.exerciseId
                                )
                            },
                            onHistory: {
                                guard let resolvedExercise else { return }
                                historyContext = ExerciseHistoryContext(
                                    exerciseId: resolvedExercise.id,
                                    exerciseName: resolvedExercise.name
                                )
                            },
                            onEntryUpdated: { scheduleDraftExport() }
                        )
                    }

                    Section {
                        Button("Finish Workout") {
                            finishWorkout()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "No Workout",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Create or activate a cycle to start logging sets.")
                    )
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
            }
        }
        .sheet(item: $swapContext) { context in
            let currentExercise = exercises.first(where: { $0.id == context.currentExerciseId })
            ExerciseSwapSheet(
                currentExercise: currentExercise,
                exercises: exercises,
                slotMuscle: context.slot.muscle,
                onSelect: { selected in
                    applySwap(
                        sessionId: context.sessionId,
                        slot: context.slot,
                        fromExerciseId: context.currentExerciseId,
                        toExerciseId: selected.id
                    )
                    swapContext = nil
                },
                onCreate: { name, muscle, type, equipment in
                    createExerciseAndSwap(
                        sessionId: context.sessionId,
                        slot: context.slot,
                        fromExerciseId: context.currentExerciseId,
                        name: name,
                        muscle: muscle,
                        type: type,
                        equipment: equipment
                    )
                    swapContext = nil
                }
            )
        }
        .sheet(item: $historyContext) { context in
            ExerciseHistorySheet(
                exerciseName: context.exerciseName,
                efforts: recentEfforts(exerciseId: context.exerciseId, exerciseName: context.exerciseName)
            )
        }
        .task {
            await prepareWorkoutState()
        }
        .alert("Validation Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "Unknown error")
        })
    }

    private func prepareWorkoutState() async {
        do {
            try bootstrapDataIfNeeded()
            try ensureDraftSession()
            try repairKnownMalformedStoredEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bootstrapDataIfNeeded() throws {
        let currentExercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
        let currentSessions = try modelContext.fetch(FetchDescriptor<Session>())
        let latestExport = BootstrapDataService.latestExportSummary()
        let recentCycleName = BootstrapDataService.recentCycleName(
            sessions: currentSessions,
            latestExport: latestExport
        )

        var currentTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        if let recentCycleName {
            _ = try BootstrapDataService.importPublishedTemplateIfNeeded(
                named: recentCycleName,
                modelContext: modelContext,
                existingTemplates: currentTemplates,
                exercises: currentExercises
            )
            currentTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        }

        if currentTemplates.isEmpty {
            _ = try BootstrapDataService.importPreferredPublishedTemplateIfNeeded(
                modelContext: modelContext,
                existingTemplates: currentTemplates,
                exercises: currentExercises
            )
            currentTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())

            if currentTemplates.isEmpty {
                _ = try BootstrapDataService.ensureDefaultStarterTemplateIfNeeded(
                    modelContext: modelContext,
                    existingTemplates: currentTemplates,
                    exercises: currentExercises
                )
                currentTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            }
        }

        var currentCycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let selectedTemplate = OpenLiftStateResolver.preferredTemplate(
            templates: currentTemplates,
            sessions: currentSessions,
            latestExport: latestExport,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:)),
            preferredTemplateName: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateName")
        )

        // If state is empty at runtime, rebuild a usable active cycle from templates/exports.
        if currentCycles.isEmpty, let template = selectedTemplate {
            let cycle = ActiveCycleInstance(
                templateId: template.id,
                currentDayIndex: BootstrapDataService.inferredNextDayIndex(
                    dayCount: template.days.count,
                    sessions: currentSessions,
                    targetCycleName: template.name,
                    latestExport: latestExport
                )
            )
            try cycle.validate(template: template)
            modelContext.insert(cycle)
            currentCycles = [cycle]
        }

        if let template = selectedTemplate,
           let cycle = OpenLiftStateResolver.activeCycle(
                activeCycles: currentCycles,
                templates: currentTemplates,
                sessions: currentSessions,
                latestExport: latestExport,
                preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                    .flatMap(UUID.init(uuidString:))
           ),
           cycle.templateId != template.id {
            try deleteDraftSessions(from: currentSessions, forCycleId: cycle.id)
            cycle.templateId = template.id
            cycle.currentDayIndex = BootstrapDataService.inferredNextDayIndex(
                dayCount: template.days.count,
                sessions: currentSessions,
                targetCycleName: template.name,
                latestExport: latestExport
            )
            try cycle.validate(template: template)
        }

        if let cycle = OpenLiftStateResolver.activeCycle(
            activeCycles: currentCycles,
            templates: currentTemplates,
            sessions: currentSessions,
            latestExport: latestExport,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:))
        ) {
            try hydrateMissingCompletedSessionsFromExports(cycle: cycle)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func hydrateLatestCompletedSessionIfPossible(cycle: ActiveCycleInstance, template: CycleTemplate) throws {
        guard let export = BootstrapDataService.latestExportSummary() else { return }
        guard let finishedAt = ISO8601DateFormatter().date(from: export.date) else { return }

        let completed = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: export.cycle_day_index,
            cycleNameSnapshot: export.cycle_name,
            dayLabelSnapshot: "Day \(export.cycle_day_index + 1)",
            createdAt: finishedAt.addingTimeInterval(-60),
            finishedAt: finishedAt,
            status: .completed,
            exportStatus: .success
        )
        try completed.validate()
        modelContext.insert(completed)

        let exercisesByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name.lowercased(), $0) })
        for exportExercise in export.exercises {
            guard let exercise = exercisesByName[exportExercise.exercise_name.lowercased()] else { continue }
            for set in exportExercise.sets where set.reps > 0 {
                let entry = SetEntry(
                    sessionId: completed.id,
                    exerciseId: exercise.id,
                    setIndex: set.set_index,
                    weight: set.weight,
                    reps: set.reps,
                    isLocked: true
                )
                try entry.validate()
                modelContext.insert(entry)
            }
        }

        cycle.currentDayIndex = (export.cycle_day_index + 1) % max(1, template.days.count)
        try cycle.validate(template: template)
    }

    private func hydrateMissingCompletedSessionsFromExports(cycle: ActiveCycleInstance) throws {
        let exports = BootstrapDataService.allExportSummaries()
        guard !exports.isEmpty else { return }

        var existingSessionIds = Set(sessions.map { $0.id.uuidString.uppercased() })
        let exercisesByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name.lowercased(), $0) })
        let iso = ISO8601DateFormatter()

        for export in exports {
            let exportSessionId = export.session_id.uppercased()
            guard !existingSessionIds.contains(exportSessionId) else { continue }
            guard let sessionUUID = UUID(uuidString: export.session_id),
                  let finishedAt = iso.date(from: export.date) else { continue }

            let recovered = Session(
                id: sessionUUID,
                cycleInstanceId: cycle.id,
                cycleDayIndex: export.cycle_day_index,
                cycleNameSnapshot: export.cycle_name,
                dayLabelSnapshot: "Day \(export.cycle_day_index + 1)",
                createdAt: finishedAt.addingTimeInterval(-60),
                finishedAt: finishedAt,
                status: .completed,
                exportStatus: .success
            )
            try recovered.validate()
            modelContext.insert(recovered)

            for exportExercise in export.exercises {
                guard let exercise = exercisesByName[exportExercise.exercise_name.lowercased()] else { continue }
                for set in exportExercise.sets where set.reps > 0 {
                    let entry = SetEntry(
                        sessionId: recovered.id,
                        exerciseId: exercise.id,
                        setIndex: set.set_index,
                        weight: set.weight,
                        reps: set.reps,
                        isLocked: true
                    )
                    try entry.validate()
                    modelContext.insert(entry)
                }
            }

            existingSessionIds.insert(exportSessionId)
        }
    }

    private func ensureDraftSession() throws {
        let fetchedCycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
        let fetchedTemplates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let fetchedSessions = try modelContext.fetch(FetchDescriptor<Session>())
        guard let cycle = activeCycle ?? fetchedCycles.first else { return }
        guard let template = activeTemplate ?? fetchedTemplates.first(where: { $0.id == cycle.templateId }) else { return }
        if OpenLiftStateResolver.preferredDraftSession(sessions: fetchedSessions, activeCycle: cycle) != nil { return }

        try cycle.validate(template: template)

        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: cycle.currentDayIndex)
        try session.validate()
        modelContext.insert(session)

        try addDraftEntries(for: session, cycle: cycle, template: template)

        try modelContext.save()
        scheduleDraftExport()
    }

    private func deleteDraftSessions(from sessions: [Session], forCycleId cycleId: UUID) throws {
        let draftIds = OpenLiftStateResolver.draftSessionIds(
            sessions: sessions,
            forCycleId: cycleId
        )
        guard !draftIds.isEmpty else { return }

        for entry in setEntries where draftIds.contains(entry.sessionId) {
            modelContext.delete(entry)
        }
        for override in slotOverrides where draftIds.contains(override.sessionId) {
            modelContext.delete(override)
        }
        for draft in sessions where draftIds.contains(draft.id) {
            modelContext.delete(draft)
        }
    }

    private func finishWorkout() {
        do {
            guard let cycle = activeCycle, let template = activeTemplate, let session = draftSession else { return }
            let dayIndex = cycle.currentDayIndex

            // Keep only confirmed logged sets in completed sessions/history/export.
            let sessionEntries = setEntries.filter { $0.sessionId == session.id }
            for entry in sessionEntries where entry.reps <= 0 || !entry.isLocked {
                modelContext.delete(entry)
            }
            for override in slotOverrides where override.sessionId == session.id {
                modelContext.delete(override)
            }

            session.status = .completed
            session.finishedAt = .now
            session.cycleNameSnapshot = template.name
            let orderedDays = CycleOrdering.sortedDays(template.days)
            if dayIndex >= 0, dayIndex < orderedDays.count {
                session.dayLabelSnapshot = orderedDays[dayIndex].label
            }

            do {
                try SessionExportService.export(
                    session: session,
                    cycleName: template.name,
                    exercises: exercises,
                    setEntries: setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked }
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
            }
            SessionExportService.deleteDraftSnapshot(sessionId: session.id)

            cycle.currentDayIndex = (dayIndex + 1) % max(template.days.count, 1)
            try cycle.validate(template: template)

            let next = Session(cycleInstanceId: cycle.id, cycleDayIndex: cycle.currentDayIndex)
            try next.validate()
            modelContext.insert(next)

            try addDraftEntries(for: next, cycle: cycle, template: template)

            try modelContext.save()
            scheduleDraftExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prefillValues(exerciseId: UUID, setIndex: Int, preferredSessionId: UUID? = nil) -> (weight: Double, reps: Int) {
        if let preferredSessionId {
            if let exact = setEntries.first(where: {
                $0.sessionId == preferredSessionId && $0.exerciseId == exerciseId && $0.setIndex == setIndex
            }) {
                return (exact.weight, exact.reps)
            }
            if let fallback = setEntries
                .filter({ $0.sessionId == preferredSessionId && $0.exerciseId == exerciseId })
                .sorted(by: { $0.setIndex > $1.setIndex })
                .first {
                return (fallback.weight, fallback.reps)
            }
        }

        let completedIds = sessions
            .filter { $0.status == .completed && $0.id != preferredSessionId }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            .map(\.id)

        for sessionId in completedIds {
            if let exact = setEntries.first(where: {
                $0.sessionId == sessionId && $0.exerciseId == exerciseId && $0.setIndex == setIndex
            }) {
                return (exact.weight, exact.reps)
            }
            if let fallback = setEntries
                .filter({ $0.sessionId == sessionId && $0.exerciseId == exerciseId })
                .sorted(by: { $0.setIndex > $1.setIndex })
                .first {
                return (fallback.weight, fallback.reps)
            }
        }
        return (0, 0)
    }

    private func addDraftEntries(for session: Session, cycle: ActiveCycleInstance, template: CycleTemplate) throws {
        guard cycle.currentDayIndex >= 0, cycle.currentDayIndex < template.days.count else {
            throw OpenLiftValidationError.invalidCurrentDayIndex(index: cycle.currentDayIndex, dayCount: template.days.count)
        }

        let previousDaySession = mostRecentCompletedSession(
            templateName: template.name,
            cycleDayIndex: cycle.currentDayIndex
        )

        let day = CycleOrdering.sortedDays(template.days)[cycle.currentDayIndex]
        for slot in CycleOrdering.sortedSlots(day.slots) {
            let setCount = suggestedSetCount(
                exerciseId: slot.exerciseId,
                previousDaySessionId: previousDaySession?.id
            ) ?? slot.defaultSetCount

            for setIndex in 1...max(1, setCount) {
                let prefills = prefillValues(
                    exerciseId: slot.exerciseId,
                    setIndex: setIndex,
                    preferredSessionId: previousDaySession?.id
                )
                let entry = SetEntry(
                    sessionId: session.id,
                    exerciseId: slot.exerciseId,
                    setIndex: setIndex,
                    weight: prefills.weight,
                    reps: prefills.reps,
                    isLocked: false
                )
                try entry.validate()
                modelContext.insert(entry)
            }
        }
    }

    private func suggestedSetCount(exerciseId: UUID, previousDaySessionId: UUID?) -> Int? {
        guard let previousDaySessionId else { return nil }
        let matching = setEntries
            .filter { $0.sessionId == previousDaySessionId && $0.exerciseId == exerciseId && $0.reps > 0 }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.setIndex).max()
    }

    private func mostRecentCompletedSession(templateName: String, cycleDayIndex: Int) -> Session? {
        OpenLiftStateResolver.mostRecentCompletedSession(
            sessions: sessions,
            activeCycles: activeCycles,
            templates: templates,
            templateName: templateName,
            cycleDayIndex: cycleDayIndex
        )
    }

    private func entries(for exerciseId: UUID, sessionId: UUID) -> [SetEntry] {
        setEntries
            .filter { $0.sessionId == sessionId && $0.exerciseId == exerciseId }
            .sorted { $0.setIndex < $1.setIndex }
    }

    private func addSet(for exerciseId: UUID, sessionId: UUID) {
        do {
            let current = entries(for: exerciseId, sessionId: sessionId)
            let newIndex = (current.last?.setIndex ?? 0) + 1
            let prefills = prefillValues(exerciseId: exerciseId, setIndex: newIndex, preferredSessionId: sessionId)
            let newEntry = SetEntry(
                sessionId: sessionId,
                exerciseId: exerciseId,
                setIndex: newIndex,
                weight: prefills.weight,
                reps: prefills.reps
            )
            try newEntry.validate()
            modelContext.insert(newEntry)
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSet(for exerciseId: UUID, sessionId: UUID) {
        do {
            guard let last = entries(for: exerciseId, sessionId: sessionId).last else { return }
            modelContext.delete(last)
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedSlots(for day: CycleDay, sessionId: UUID) -> [ResolvedWorkoutSlot] {
        CycleOrdering.sortedSlots(day.slots).map { slot in
            let overrideExerciseId = slotOverrides.first {
                $0.sessionId == sessionId && $0.slotPosition == slot.position
            }?.exerciseId
            return ResolvedWorkoutSlot(
                slot: slot,
                exerciseId: overrideExerciseId ?? slot.exerciseId
            )
        }
    }

    private func applySwap(sessionId: UUID, slot: CycleSlot, fromExerciseId: UUID, toExerciseId: UUID) {
        guard fromExerciseId != toExerciseId else { return }

        do {
            let oldEntries = entries(for: fromExerciseId, sessionId: sessionId)
            let existingTargetEntries = entries(for: toExerciseId, sessionId: sessionId)

            for entry in oldEntries {
                modelContext.delete(entry)
            }

            let setCount = max(1, oldEntries.count > 0 ? oldEntries.count : slot.defaultSetCount)
            if existingTargetEntries.isEmpty {
                for setIndex in 1...setCount {
                    let prefills = prefillValues(exerciseId: toExerciseId, setIndex: setIndex)
                    let entry = SetEntry(
                        sessionId: sessionId,
                        exerciseId: toExerciseId,
                        setIndex: setIndex,
                        weight: prefills.weight,
                        reps: prefills.reps,
                        isLocked: false
                    )
                    try entry.validate()
                    modelContext.insert(entry)
                }
            }

            if let existingOverride = slotOverrides.first(where: { $0.sessionId == sessionId && $0.slotPosition == slot.position }) {
                if toExerciseId == slot.exerciseId {
                    modelContext.delete(existingOverride)
                } else {
                    existingOverride.exerciseId = toExerciseId
                }
            } else if toExerciseId != slot.exerciseId {
                modelContext.insert(
                    SessionSlotOverride(
                        sessionId: sessionId,
                        slotPosition: slot.position,
                        exerciseId: toExerciseId
                    )
                )
            }

            try modelContext.save()
            scheduleDraftExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createExerciseAndSwap(
        sessionId: UUID,
        slot: CycleSlot,
        fromExerciseId: UUID,
        name: String,
        muscle: MuscleGroup,
        type: ExerciseType,
        equipment: EquipmentType
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Exercise name cannot be empty."
            return
        }

        if let existing = exercises.first(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            applySwap(
                sessionId: sessionId,
                slot: slot,
                fromExerciseId: fromExerciseId,
                toExerciseId: existing.id
            )
            return
        }

        do {
            let newExercise = Exercise(
                name: trimmedName,
                primaryMuscle: muscle,
                type: type,
                equipment: equipment
            )
            try newExercise.validate()
            modelContext.insert(newExercise)

            applySwap(
                sessionId: sessionId,
                slot: slot,
                fromExerciseId: fromExerciseId,
                toExerciseId: newExercise.id
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleDraftExport() {
        guard let session = draftSession, let template = activeTemplate else { return }

        let exerciseSnapshots = exercises.map {
            SessionExportService.ExerciseSnapshot(
                id: $0.id,
                name: $0.name,
                muscle: $0.primaryMuscle.rawValue
            )
        }
        let entrySnapshots = setEntries
            .filter { $0.sessionId == session.id }
            .map {
                SessionExportService.SetEntrySnapshot(
                    exerciseId: $0.exerciseId,
                    setIndex: $0.setIndex,
                    weight: $0.weight,
                    reps: $0.reps
                )
            }
        let snapshot = SessionExportService.DraftSnapshot(
            sessionId: session.id,
            cycleName: template.name,
            cycleDayIndex: session.cycleDayIndex,
            date: .now,
            exercises: exerciseSnapshots,
            entries: entrySnapshots
        )

        draftExportTask?.cancel()
        draftExportTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            try? SessionExportService.exportDraftSnapshot(snapshot: snapshot)
        }
    }

    private func recentEfforts(exerciseId: UUID, exerciseName: String) -> [ExerciseEffort] {
        var efforts: [ExerciseEffort] = []

        let completed = sessions
            .filter { $0.status == .completed || $0.finishedAt != nil || $0.exportStatus == .success }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }

        for session in completed {
            let sets = setEntries
                .filter { $0.sessionId == session.id && $0.exerciseId == exerciseId && $0.reps > 0 && $0.isLocked }
                .sorted { $0.setIndex < $1.setIndex }
                .map { ExerciseEffortSet(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps) }
            guard !sets.isEmpty else { continue }

            efforts.append(
                ExerciseEffort(
                    id: session.id.uuidString,
                    date: session.finishedAt ?? session.createdAt,
                    cycleName: cycleName(for: session),
                    dayLabel: dayLabel(for: session),
                    sets: sets
                )
            )
        }

        let existingIds = Set(efforts.map(\.id))
        for exported in exportedEfforts(exerciseName: exerciseName) where !existingIds.contains(exported.id) {
            efforts.append(exported)
        }

        return efforts
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map { $0 }
    }

    private func cycleName(for session: Session) -> String {
        OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func dayLabel(for session: Session) -> String {
        OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func exportedEfforts(exerciseName: String) -> [ExerciseEffort] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        if let iCloudRoot = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(iCloudRoot)
        }
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(docs)
        }

        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        var efforts: [ExerciseEffort] = []
        let targetName = exerciseName.lowercased()

        for directory in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in urls where fileURL.pathExtension == "json" && fileURL.lastPathComponent.hasPrefix("workout-") {
                guard let data = try? Data(contentsOf: fileURL),
                      let payload = try? decoder.decode(SessionExportService.ExportPayload.self, from: data),
                      let date = iso.date(from: payload.date),
                      let exercise = payload.exercises.first(where: { $0.exercise_name.lowercased() == targetName }) else {
                    continue
                }

                efforts.append(
                    ExerciseEffort(
                        id: payload.session_id,
                        date: date,
                        cycleName: payload.cycle_name,
                        dayLabel: "Day \(payload.cycle_day_index + 1)",
                        sets: exercise.sets.map {
                            ExerciseEffortSet(setIndex: $0.set_index, weight: $0.weight, reps: $0.reps)
                        }
                    )
                )
            }
        }

        let deduped = Dictionary(grouping: efforts, by: \.id).compactMap { _, grouped in
            grouped.max(by: { $0.date < $1.date })
        }
        return deduped.sorted { $0.date > $1.date }
    }
}

private func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

extension WorkoutView {
    fileprivate func repairKnownMalformedStoredEntries() throws {
        let exerciseNamesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
        var hasChanges = false
        var repairedDraftSessionIds: Set<UUID> = []

        for entry in setEntries {
            guard let exerciseName = exerciseNamesById[entry.exerciseId] else { continue }
            let didRepair = WorkoutEntryEditing.repairKnownMalformedEntry(
                exerciseName: exerciseName,
                setIndex: entry.setIndex,
                weight: &entry.weight,
                reps: &entry.reps
            )
            hasChanges = didRepair || hasChanges
            if didRepair {
                repairedDraftSessionIds.insert(entry.sessionId)
            }
        }

        if hasChanges {
            try modelContext.save()
            if let draftSession, repairedDraftSessionIds.contains(draftSession.id) {
                scheduleDraftExport()
            }
        }
    }
}

private struct ResolvedWorkoutSlot: Identifiable {
    let slot: CycleSlot
    let exerciseId: UUID

    var id: String {
        "\(slot.position)-\(slot.muscle.rawValue)"
    }
}

private struct SwapContext: Identifiable {
    let sessionId: UUID
    let slot: CycleSlot
    let currentExerciseId: UUID

    var id: String {
        "\(sessionId.uuidString)-\(slot.position)"
    }
}

private struct ExerciseHistoryContext: Identifiable {
    let exerciseId: UUID
    let exerciseName: String

    var id: UUID {
        exerciseId
    }
}

private struct ExerciseEffort: Identifiable {
    let id: String
    let date: Date
    let cycleName: String
    let dayLabel: String
    let sets: [ExerciseEffortSet]
}

private struct ExerciseEffortSet {
    let setIndex: Int
    let weight: Double
    let reps: Int
}

private struct ExerciseSection: View {
    @Environment(\.modelContext) private var modelContext

    let slot: CycleSlot
    let exercise: Exercise?
    let entries: [SetEntry]
    let onAddSet: () -> Void
    let onRemoveSet: () -> Void
    let onSwap: () -> Void
    let onHistory: () -> Void
    let onEntryUpdated: () -> Void
    private let actionButtonSize: CGFloat = 30
    private var usesAssistanceLoad: Bool {
        exercise?.usesAssistanceLoad ?? false
    }

    private enum RowField: Hashable {
        case weight(UUID), reps(UUID)
    }
    @FocusState private var focusedField: RowField?

    var body: some View {
        Section {
            ForEach(entries) { entry in
                HStack {
                    Text("S\(entry.setIndex)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 28, alignment: .leading)

                    Text(usesAssistanceLoad ? "A" : "W")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(
                        usesAssistanceLoad ? "Assist" : "Weight",
                        value: Binding<Double?>(
                            get: { WorkoutEntryEditing.displayWeight(entry.weight) },
                            set: { newWeight in
                                guard !entry.isLocked else { return }
                                var states = entries.map(WorkoutEntryEditing.EntryState.init)
                                WorkoutEntryEditing.applyWeightEdit(
                                    to: &states,
                                    setIndex: entry.setIndex,
                                    newWeight: newWeight
                                )

                                for sibling in entries {
                                    guard let state = states.first(where: { $0.setIndex == sibling.setIndex }) else { continue }
                                    sibling.weight = state.weight
                                    sibling.reps = state.reps
                                    sibling.isLocked = state.isLocked
                                }
                                try? modelContext.save()
                                onEntryUpdated()
                            }
                        ),
                        format: WeightFormatting.style
                    )
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .frame(width: 82)
                    .disabled(entry.isLocked)
                    .opacity(entry.isLocked ? 1 : 0.55)
                    .focused($focusedField, equals: .weight(entry.id))

                    Text("R")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Reps",
                        value: Binding<Int?>(
                            get: { WorkoutEntryEditing.displayReps(entry.reps) },
                            set: { newReps in
                                guard !entry.isLocked else { return }
                                var states = entries.map(WorkoutEntryEditing.EntryState.init)
                                WorkoutEntryEditing.applyRepsEdit(
                                    to: &states,
                                    setIndex: entry.setIndex,
                                    newReps: newReps
                                )

                                for sibling in entries {
                                    guard let state = states.first(where: { $0.setIndex == sibling.setIndex }) else { continue }
                                    sibling.weight = state.weight
                                    sibling.reps = state.reps
                                    sibling.isLocked = state.isLocked
                                }
                                try? modelContext.save()
                                onEntryUpdated()
                            }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 56)
                    .disabled(entry.isLocked)
                    .opacity(entry.isLocked ? 1 : 0.55)
                    .focused($focusedField, equals: .reps(entry.id))

                    Button {
                        focusedField = nil
                        if !entry.isLocked && entry.weight == 0 && entry.reps == 0 {
                            return
                        }
                        entry.isLocked.toggle()
                        try? modelContext.save()
                        onEntryUpdated()
                    } label: {
                        Image(systemName: entry.isLocked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(entry.isLocked ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isLocked && entry.weight == 0 && entry.reps == 0)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(exercise?.name ?? "Unknown Exercise")
                Spacer()
                HStack(spacing: 14) {
                    Button(action: onSwap) {
                        VStack(spacing: -3) {
                            Image(systemName: "arrow.right")
                            Image(systemName: "arrow.left")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: actionButtonSize, height: actionButtonSize)
                    .accessibilityIdentifier("workout.swap.\(slot.position)")
                    .accessibilityLabel("Swap \(exercise?.name ?? "exercise")")
                    Button(action: onHistory) {
                        Image(systemName: "calendar")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: actionButtonSize, height: actionButtonSize)

                    Button(action: onRemoveSet) {
                        Image(systemName: "minus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: actionButtonSize, height: actionButtonSize)

                    Button(action: onAddSet) {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: actionButtonSize, height: actionButtonSize)
                }
            }
        }
    }
}

private struct ExerciseHistorySheet: View {
    let exerciseName: String
    let efforts: [ExerciseEffort]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if efforts.isEmpty {
                    Text("No recent efforts found for this exercise yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(efforts) { effort in
                        Section {
                            ForEach(effort.sets, id: \.setIndex) { set in
                                HStack {
                                    Text("Set \(set.setIndex)")
                                    Spacer()
                                    Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) x \(set.reps)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(effort.date, style: .date)
                                Text("\(effort.cycleName) · \(effort.dayLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(exerciseName) History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ExerciseSwapSheet: View {
    let currentExercise: Exercise?
    let exercises: [Exercise]
    let slotMuscle: MuscleGroup
    let onSelect: (Exercise) -> Void
    let onCreate: (_ name: String, _ muscle: MuscleGroup, _ type: ExerciseType, _ equipment: EquipmentType) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMuscle: MuscleGroup
    @State private var newExerciseName: String = ""
    @State private var newExerciseType: ExerciseType = .isolation
    @State private var newExerciseEquipment: EquipmentType = .dumbbell

    private let exerciseTypes: [ExerciseType] = [.compound, .isolation]
    private let equipmentTypes: [EquipmentType] = [.machine, .barbell, .dumbbell, .cable, .bodyweight]

    init(
        currentExercise: Exercise?,
        exercises: [Exercise],
        slotMuscle: MuscleGroup,
        onSelect: @escaping (Exercise) -> Void,
        onCreate: @escaping (_ name: String, _ muscle: MuscleGroup, _ type: ExerciseType, _ equipment: EquipmentType) -> Void
    ) {
        self.currentExercise = currentExercise
        self.exercises = exercises
        self.slotMuscle = slotMuscle
        self.onSelect = onSelect
        self.onCreate = onCreate
        _selectedMuscle = State(
            initialValue: ExerciseSwapService.initialMuscleSelection(
                currentExercise: currentExercise,
                slotMuscle: slotMuscle
            )
        )
    }

    private var candidates: [Exercise] {
        guard let currentExercise else { return [] }
        return ExerciseSwapService.swapCandidates(
            exercises: exercises,
            selectedMuscle: selectedMuscle,
            currentExerciseId: currentExercise.id
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current") {
                    Text(currentExercise?.name ?? "Unknown Exercise")
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Slot Muscle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(slotMuscle.displayName)
                    }
                }

                Section("Swap To") {
                    Picker("Muscle", selection: $selectedMuscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("swap.musclePicker")

                    if candidates.isEmpty {
                        Text("No alternate exercises available for \(selectedMuscle.displayName).")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(candidates) { exercise in
                        Button(exercise.name) {
                            onSelect(exercise)
                            dismiss()
                        }
                        .accessibilityIdentifier("swap.candidate.\(exercise.name)")
                    }
                }

                Section("Create New") {
                    TextField("Exercise name", text: $newExerciseName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    HStack {
                        Text("Muscle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(selectedMuscle.displayName)
                    }

                    Picker("Type", selection: $newExerciseType) {
                        ForEach(exerciseTypes, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    Picker("Equipment", selection: $newExerciseEquipment) {
                        ForEach(equipmentTypes, id: \.self) { equipment in
                            Text(equipment.displayName).tag(equipment)
                        }
                    }

                    Button("Create & Swap") {
                        onCreate(newExerciseName, selectedMuscle, newExerciseType, newExerciseEquipment)
                        dismiss()
                    }
                    .disabled(newExerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Swap Exercise")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension MuscleGroup {
    var displayName: String {
        switch self {
        case .sideDelts: return "Side Delts"
        default: return rawValue.capitalized
        }
    }
}

private extension ExerciseType {
    var displayName: String {
        rawValue.capitalized
    }
}

private extension EquipmentType {
    var displayName: String {
        switch self {
        case .bodyweight: return "Bodyweight"
        default: return rawValue.capitalized
        }
    }
}

private extension Exercise {
    var usesAssistanceLoad: Bool {
        let normalized = name.lowercased()
        return normalized.contains("assisted pull-up") || normalized.contains("assisted dips")
    }
}

enum WorkoutEntryEditing {
    struct EntryState {
        let setIndex: Int
        var weight: Double
        var reps: Int
        var isLocked: Bool

        init(setIndex: Int, weight: Double, reps: Int, isLocked: Bool) {
            self.setIndex = setIndex
            self.weight = weight
            self.reps = reps
            self.isLocked = isLocked
        }

        init(entry: SetEntry) {
            self.setIndex = entry.setIndex
            self.weight = entry.weight
            self.reps = entry.reps
            self.isLocked = entry.isLocked
        }
    }

    private struct KnownMalformedCorrection {
        let exerciseNames: Set<String>
        let setIndex: Int
        let invalidWeight: Double?
        let invalidReps: Int?
        let correctedWeight: Double?
        let correctedReps: Int?
    }

    static func displayWeight(_ weight: Double) -> Double? {
        weight == 0 ? nil : WeightFormatting.normalized(weight)
    }

    static func displayReps(_ reps: Int) -> Int? {
        reps == 0 ? nil : reps
    }

    static func applyWeightEdit(to entries: inout [EntryState], setIndex: Int, newWeight: Double?) {
        guard let entryIndex = entries.firstIndex(where: { $0.setIndex == setIndex }) else { return }
        guard !entries[entryIndex].isLocked else { return }

        let previousWeight = entries[entryIndex].weight
        let clampedWeight = max(0, WeightFormatting.normalized(newWeight ?? 0))
        entries[entryIndex].weight = clampedWeight

        for index in entries.indices where entries[index].setIndex > setIndex && !entries[index].isLocked {
            let shouldAutofill = entries[index].weight == 0 || entries[index].weight == previousWeight
            guard shouldAutofill else { continue }
            entries[index].weight = clampedWeight
        }
    }

    static func applyRepsEdit(to entries: inout [EntryState], setIndex: Int, newReps: Int?) {
        guard let entryIndex = entries.firstIndex(where: { $0.setIndex == setIndex }) else { return }
        guard !entries[entryIndex].isLocked else { return }
        entries[entryIndex].reps = max(0, newReps ?? 0)
    }

    static func repairKnownMalformedEntry(
        exerciseName: String,
        setIndex: Int,
        weight: inout Double,
        reps: inout Int
    ) -> Bool {
        let normalizedName = normalizeExerciseName(exerciseName)

        for correction in knownMalformedCorrections {
            guard correction.exerciseNames.contains(normalizedName), correction.setIndex == setIndex else { continue }

            let weightMatches = correction.invalidWeight == nil || correction.invalidWeight == weight
            let repsMatches = correction.invalidReps == nil || correction.invalidReps == reps
            guard weightMatches, repsMatches else { continue }

            if let correctedWeight = correction.correctedWeight {
                weight = correctedWeight
            }
            if let correctedReps = correction.correctedReps {
                reps = correctedReps
            }
            return true
        }

        return false
    }

    private static let knownMalformedCorrections: [KnownMalformedCorrection] = [
        KnownMalformedCorrection(
            exerciseNames: [normalizeExerciseName("Cable Crossover Lateral Raise"), normalizeExerciseName("Cable Lateral Raise")],
            setIndex: 2,
            invalidWeight: nil,
            invalidReps: 68,
            correctedWeight: nil,
            correctedReps: 8
        ),
        KnownMalformedCorrection(
            exerciseNames: [normalizeExerciseName("Dumbbell Skullcrusher"), normalizeExerciseName("Dumbell Skullcrusher")],
            setIndex: 1,
            invalidWeight: nil,
            invalidReps: 910,
            correctedWeight: 22.5,
            correctedReps: 9
        ),
        KnownMalformedCorrection(
            exerciseNames: [normalizeExerciseName("Dumbbell Skullcrusher"), normalizeExerciseName("Dumbell Skullcrusher")],
            setIndex: 2,
            invalidWeight: nil,
            invalidReps: 98,
            correctedWeight: 22.5,
            correctedReps: 8
        ),
        KnownMalformedCorrection(
            exerciseNames: [normalizeExerciseName("Incline Curl")],
            setIndex: 1,
            invalidWeight: nil,
            invalidReps: 19,
            correctedWeight: 22.5,
            correctedReps: 9
        ),
        KnownMalformedCorrection(
            exerciseNames: [normalizeExerciseName("Incline Curl")],
            setIndex: 2,
            invalidWeight: nil,
            invalidReps: 68,
            correctedWeight: 22.5,
            correctedReps: 8
        )
    ]

    private static func normalizeExerciseName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "dumbell", with: "dumbbell")
    }
}

enum WeightFormatting {
    static let style = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0 ... 1))

    static func normalized(_ weight: Double) -> Double {
        (weight * 10).rounded() / 10
    }
}

#Preview {
    WorkoutView()
}
