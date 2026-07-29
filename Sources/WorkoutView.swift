import SwiftUI
import SwiftData

enum FixedCycleWorkoutError: LocalizedError, Equatable {
    case incompleteReadiness(MuscleGroup)
    case readinessRequired
    case qualifyingSetRequired
    case exerciseAlreadyExists
    case cannotReplacePerformedExercise

    var errorDescription: String? {
        switch self {
        case .incompleteReadiness(let muscle):
            return "Complete readiness for \(muscle.displayName)."
        case .readinessRequired:
            return "Submit today's readiness before editing or finishing this workout."
        case .qualifyingSetRequired:
            return "Complete and lock at least one working set before finishing the workout."
        case .exerciseAlreadyExists:
            return "That exercise is already configured in this muscle block."
        case .cannotReplacePerformedExercise:
            return "This exercise already has completed work in the draft. Keep that evidence or remove it explicitly before replacing the future slot."
        }
    }
}

enum FixedCycleWorkoutService {
    static let allClear = MuscleReadinessInput(
        soreness: .none,
        connectiveTissuePain: .none,
        eagerness: .eager
    )

    static func localDateKey(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func requiredMuscles(for day: CycleDay) -> [MuscleGroup] {
        CycleOrdering.sortedSlots(day.slots).reduce(into: [MuscleGroup]()) { result, slot in
            if !result.contains(slot.muscle) {
                result.append(slot.muscle)
            }
        }
    }

    static func readinessMuscles(
        for template: CycleTemplate,
        targeting day: CycleDay
    ) -> [MuscleGroup] {
        let targeted = requiredMuscles(for: day)
        let cycleMuscles = Set(template.days.flatMap(\.slots).map(\.muscle))
        return targeted + MuscleGroup.allCases.filter {
            cycleMuscles.contains($0) && !targeted.contains($0)
        }
    }

    static func latestObservation(
        sessionId: UUID,
        localDateKey: String,
        observations: [FixedCycleReadinessObservation]
    ) -> FixedCycleReadinessObservation? {
        observations
            .filter { $0.sessionId == sessionId && $0.localDateKey == localDateKey }
            .max {
                if $0.revision != $1.revision { return $0.revision < $1.revision }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func makeReadinessObservation(
        sessionId: UUID,
        template: CycleTemplate,
        day: CycleDay,
        inputs: [MuscleGroup: MuscleReadinessInput],
        systemicEagerness: EagernessLevel? = nil,
        existing: [FixedCycleReadinessObservation],
        now: Date = .now,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) throws -> FixedCycleReadinessObservation {
        let dateKey = localDateKey(for: now, calendar: calendar)
        let responses = try readinessMuscles(for: template, targeting: day).map { muscle -> FixedCycleReadinessResponse in
            guard let value = inputs[muscle] else {
                throw FixedCycleWorkoutError.incompleteReadiness(muscle)
            }
            return FixedCycleReadinessResponse(
                muscle: muscle,
                soreness: value.soreness,
                connectiveTissuePain: value.connectiveTissuePain,
                eagerness: systemicEagerness ?? value.eagerness
            )
        }
        let revision = existing
            .filter { $0.sessionId == sessionId && $0.localDateKey == dateKey }
            .map(\.revision)
            .max()
            .map { $0 + 1 } ?? 1
        return FixedCycleReadinessObservation(
            sessionId: sessionId,
            localDateKey: dateKey,
            timeZoneIdentifier: timeZone.identifier,
            revision: revision,
            createdAt: now,
            responses: responses
        )
    }

    static func canExecute(
        sessionId: UUID,
        now: Date,
        observations: [FixedCycleReadinessObservation],
        calendar: Calendar = .current
    ) -> Bool {
        latestObservation(
            sessionId: sessionId,
            localDateKey: localDateKey(for: now, calendar: calendar),
            observations: observations
        ) != nil
    }

    static func hasQualifyingSet(sessionId: UUID, entries: [SetEntry]) -> Bool {
        entries.contains {
            $0.sessionId == sessionId && $0.isLocked && $0.reps > 0
        }
    }

    static func hasQualifyingSet(
        sessionId: UUID,
        exerciseIds: Set<UUID>,
        entries: [SetEntry]
    ) -> Bool {
        entries.contains {
            $0.sessionId == sessionId
                && exerciseIds.contains($0.exerciseId)
                && $0.isLocked
                && $0.reps > 0
        }
    }

    /// A persistent template removal may take effect immediately while locked
    /// work from the current occurrence must remain visible in final history.
    /// Stage the whole pre-edit occurrence once so relaunch and export retry do
    /// not depend on the later template shape.
    static func stageOccurrenceSnapshotsIfNeeded(
        sessionId: UUID,
        day: CycleDay,
        exercises: [Exercise],
        existingSnapshots: [FixedCycleExerciseSnapshot],
        modelContext: ModelContext
    ) {
        guard !existingSnapshots.contains(where: { $0.sessionId == sessionId }) else { return }
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        for slot in CycleOrdering.sortedSlots(day.slots) {
            guard let exercise = exercisesById[slot.exerciseId] else { continue }
            modelContext.insert(
                FixedCycleExerciseSnapshot(
                    sessionId: sessionId,
                    position: slot.position,
                    exerciseId: exercise.id,
                    exerciseName: exercise.name,
                    muscle: slot.muscle,
                    statusRawValue: "planned"
                )
            )
        }
    }

    static func prefillEffort(
        exerciseId: UUID,
        session: Session,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> ExerciseEffortLookupResult? {
        ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseId,
            cycleInstanceId: session.cycleInstanceId,
            cycleDayIndex: session.cycleDayIndex,
            excludingSessionId: session.id,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries
        )
    }

    static func replaceExercise(
        slot: CycleSlot,
        currentExerciseId: UUID? = nil,
        with exercise: Exercise,
        sessionId: UUID,
        entries: [SetEntry],
        slotOverrides: [SessionSlotOverride] = [],
        modelContext: ModelContext
    ) throws {
        let replacedExerciseId = currentExerciseId ?? slot.exerciseId
        guard replacedExerciseId != exercise.id else { return }
        let current = entries.filter {
            $0.sessionId == sessionId && $0.exerciseId == replacedExerciseId
        }
        guard !current.contains(where: { $0.isLocked && $0.reps > 0 }) else {
            throw FixedCycleWorkoutError.cannotReplacePerformedExercise
        }
        for entry in current { modelContext.delete(entry) }
        for occurrenceOverride in slotOverrides where
            occurrenceOverride.sessionId == sessionId
                && occurrenceOverride.slotPosition == slot.position {
            modelContext.delete(occurrenceOverride)
        }
        slot.exerciseId = exercise.id
    }

    @discardableResult
    static func addMovement(
        exercise: Exercise,
        to day: CycleDay,
        sessionId: UUID,
        defaultSetCount: Int,
        modelContext: ModelContext
    ) throws -> CycleSlot {
        let ordered = CycleOrdering.sortedSlots(day.slots)
        guard !ordered.contains(where: {
            $0.muscle == exercise.primaryMuscle && $0.exerciseId == exercise.id
        }) else {
            throw FixedCycleWorkoutError.exerciseAlreadyExists
        }
        let insertion = (ordered.lastIndex(where: { $0.muscle == exercise.primaryMuscle })
            .map { $0 + 1 }) ?? ordered.count
        for index in insertion..<ordered.count {
            ordered[index].position += 1
        }
        let slot = CycleSlot(
            position: insertion,
            muscle: exercise.primaryMuscle,
            exerciseId: exercise.id,
            defaultSetCount: max(1, defaultSetCount)
        )
        day.slots.append(slot)
        return slot
    }

    static func skipExercise(
        slot: CycleSlot,
        sessionId: UUID,
        reasonCode: String,
        entries: [SetEntry],
        existingOverrides: [FixedCycleOccurrenceOverride],
        modelContext: ModelContext
    ) {
        guard !existingOverrides.contains(where: {
            $0.sessionId == sessionId
                && $0.kind == .skipExercise
                && $0.slotPosition == slot.position
        }) else { return }
        for entry in entries where
            entry.sessionId == sessionId && entry.exerciseId == slot.exerciseId {
            modelContext.delete(entry)
        }
        modelContext.insert(
            FixedCycleOccurrenceOverride(
                sessionId: sessionId,
                kind: .skipExercise,
                slotPosition: slot.position,
                exerciseId: slot.exerciseId,
                muscle: slot.muscle,
                reasonCode: reasonCode
            )
        )
    }

    static func skipMuscle(
        muscle: MuscleGroup,
        day: CycleDay,
        sessionId: UUID,
        reasonCode: String,
        entries: [SetEntry],
        existingOverrides: [FixedCycleOccurrenceOverride],
        modelContext: ModelContext
    ) {
        guard !existingOverrides.contains(where: {
            $0.sessionId == sessionId && $0.kind == .skipMuscle && $0.muscle == muscle
        }) else { return }
        let ids = Set(day.slots.filter { $0.muscle == muscle }.map(\.exerciseId))
        for entry in entries where entry.sessionId == sessionId && ids.contains(entry.exerciseId) {
            modelContext.delete(entry)
        }
        modelContext.insert(
            FixedCycleOccurrenceOverride(
                sessionId: sessionId,
                kind: .skipMuscle,
                muscle: muscle,
                reasonCode: reasonCode
            )
        )
    }

    static func removeExercisePersistently(
        slot: CycleSlot,
        from day: CycleDay,
        sessionId: UUID,
        entries: [SetEntry],
        modelContext: ModelContext
    ) {
        let current = entries.filter {
            $0.sessionId == sessionId && $0.exerciseId == slot.exerciseId
        }
        if !current.contains(where: { $0.isLocked && $0.reps > 0 }) {
            for entry in current { modelContext.delete(entry) }
        }
        day.slots.removeAll { $0 === slot }
        modelContext.delete(slot)
        normalizePositions(day)
    }

    static func removeMusclePersistently(
        muscle: MuscleGroup,
        from day: CycleDay,
        sessionId: UUID,
        entries: [SetEntry],
        modelContext: ModelContext
    ) {
        let slots = day.slots.filter { $0.muscle == muscle }
        for slot in slots {
            removeExercisePersistently(
                slot: slot,
                from: day,
                sessionId: sessionId,
                entries: entries,
                modelContext: modelContext
            )
        }
    }

    private static func normalizePositions(_ day: CycleDay) {
        for (index, slot) in CycleOrdering.sortedSlots(day.slots).enumerated() {
            slot.position = index
        }
    }
}

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var templates: [CycleTemplate]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @Query private var setEntries: [SetEntry]
    @Query private var slotOverrides: [SessionSlotOverride]
    @Query private var trainingPreferences: [TrainingPreference]
    @Query private var adaptiveSessions: [AdaptiveWorkoutSession]
    @Query private var adaptiveSetEntries: [AdaptiveSetEntry]
    @Query private var fixedReadiness: [FixedCycleReadinessObservation]
    @Query private var fixedOverrides: [FixedCycleOccurrenceOverride]
    @Query private var fixedSnapshots: [FixedCycleExerciseSnapshot]

    @State private var errorMessage: String?
    @State private var draftExportTask: Task<Void, Never>?
    @State private var swapContext: SwapContext?
    @State private var addMovementContext: AddMovementContext?
    @State private var historyContext: ExerciseHistoryContext?
    @State private var readinessInputs: [MuscleGroup: MuscleReadinessInput] = [:]
    @State private var systemicEagerness: EagernessLevel = .eager
    @State private var observedLocalDateKey = FixedCycleWorkoutService.localDateKey(for: .now)
    @State private var pendingFixedMutation: PendingFixedMutation?
    @State private var skippedReason = "user_choice"
    private let dateRefresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var trainingMode: TrainingMode {
        TrainingModeService.resolvedMode(preferences: trainingPreferences)
    }

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

    private var latestFixedReadiness: FixedCycleReadinessObservation? {
        guard let draftSession else { return nil }
        return FixedCycleWorkoutService.latestObservation(
            sessionId: draftSession.id,
            localDateKey: observedLocalDateKey,
            observations: fixedReadiness
        )
    }

    private var isFixedExecutionEnabled: Bool {
        latestFixedReadiness != nil
    }

    var body: some View {
        Group {
            if trainingMode == .adaptive {
                AdaptiveWorkoutView()
            } else {
                rotationWorkoutContent
            }
        }
        .sheet(item: $swapContext) { context in
            let currentExercise = exercises.first(where: { $0.id == context.currentExerciseId })
            ExerciseSwapSheet(
                currentExercise: currentExercise,
                exercises: exercises,
                slotMuscle: context.slot.muscle,
                navigationTitle: "Replace Exercise in \(context.dayLabel)",
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
        .sheet(item: $addMovementContext) { context in
            ExerciseSwapSheet(
                currentExercise: nil,
                exercises: exercises,
                slotMuscle: context.defaultMuscle,
                navigationTitle: "Add Movement to \(context.day.label)",
                onSelect: { selected in
                    addPersistentMovement(selected, day: context.day, sessionId: context.sessionId)
                    addMovementContext = nil
                },
                onCreate: { name, muscle, type, equipment in
                    createExerciseAndAdd(
                        name: name,
                        muscle: muscle,
                        type: type,
                        equipment: equipment,
                        day: context.day,
                        sessionId: context.sessionId
                    )
                    addMovementContext = nil
                }
            )
        }
        .sheet(item: $historyContext) { context in
            ExerciseHistorySheet(
                exerciseName: context.exerciseName,
                efforts: recentEfforts(exerciseId: context.exerciseId, exerciseName: context.exerciseName)
            )
        }
        .task(id: trainingMode) {
            guard trainingMode == .rotation else { return }
            await prepareWorkoutState()
        }
        .onReceive(dateRefresh) { now in
            refreshLocalDate(now)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshLocalDate(.now)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshLocalDate(.now)
        }
        .alert("Validation Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "Unknown error")
        })
        .alert(
            pendingFixedMutation?.title ?? "Confirm Change",
            isPresented: Binding(
                get: { pendingFixedMutation != nil },
                set: { if !$0 { pendingFixedMutation = nil } }
            )
        ) {
            if let pendingFixedMutation {
                Button(pendingFixedMutation.confirmationLabel, role: .destructive) {
                    applyPendingFixedMutation(pendingFixedMutation)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingFixedMutation = nil
            }
        } message: {
            Text(pendingFixedMutation?.message ?? "")
        }
    }

    private var rotationWorkoutContent: some View {
        NavigationStack {
            List {
                if let draftSession, let activeTemplate, let activeDay {
                    if latestFixedReadiness == nil {
                        fixedReadinessEntry(
                            session: draftSession,
                            template: activeTemplate,
                            day: activeDay
                        )
                    } else if let latestFixedReadiness {
                        Section {
                            Text("\(activeDay.label) · Draft session")
                                .font(.headline)
                                .lineLimit(1)
                        }

                        let cautionMuscles = FixedCycleWorkoutService.requiredMuscles(for: activeDay)
                            .filter { muscle in
                                guard let response = latestFixedReadiness.responses.first(
                                    where: { $0.muscle == muscle }
                                ) else {
                                    return false
                                }
                                return response.connectiveTissuePain != .none
                                    || !response.soreness.allowsAutomaticTraining
                            }
                        if !cautionMuscles.isEmpty {
                            Text(
                                "Caution: \(cautionMuscles.map(\.displayName).joined(separator: ", "))"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }

                        ForEach(resolvedSlots(for: activeDay, sessionId: draftSession.id)) { resolved in
                            let resolvedExercise = exercises.first(where: { $0.id == resolved.exerciseId })
                            let source = prefillEffort(
                                exerciseId: resolved.exerciseId,
                                session: draftSession
                            )
                            ExerciseSection(
                                slot: resolved.slot,
                                exercise: resolvedExercise,
                                entries: entries(for: resolved.exerciseId, sessionId: draftSession.id),
                                isExecutionEnabled: isFixedExecutionEnabled,
                                prefillSource: source.map(prefillSourceText),
                                onAddSet: { addSet(for: resolved.exerciseId, sessionId: draftSession.id) },
                                onRemoveSet: { removeSet(for: resolved.exerciseId, sessionId: draftSession.id) },
                                onSwap: {
                                    swapContext = SwapContext(
                                        sessionId: draftSession.id,
                                        slot: resolved.slot,
                                        currentExerciseId: resolved.exerciseId,
                                        dayLabel: activeDay.label
                                    )
                                },
                                onHistory: {
                                    guard let resolvedExercise else { return }
                                    historyContext = ExerciseHistoryContext(
                                        exerciseId: resolvedExercise.id,
                                        exerciseName: resolvedExercise.name
                                    )
                                },
                                onSkipToday: {
                                    skipExerciseToday(
                                        resolved.slot,
                                        sessionId: draftSession.id,
                                        reasonCode: skippedReason
                                    )
                                },
                                onSkipMuscleToday: {
                                    skipMuscleToday(
                                        resolved.slot.muscle,
                                        day: activeDay,
                                        sessionId: draftSession.id,
                                        reasonCode: skippedReason
                                    )
                                },
                                onRemoveFuture: {
                                    pendingFixedMutation = .removeExercise(
                                        day: activeDay,
                                        slot: resolved.slot,
                                        sessionId: draftSession.id,
                                        exerciseName: resolvedExercise?.name ?? "exercise"
                                    )
                                },
                                onRemoveMuscleFuture: {
                                    pendingFixedMutation = .removeMuscle(
                                        day: activeDay,
                                        muscle: resolved.slot.muscle,
                                        sessionId: draftSession.id
                                    )
                                },
                                onEntryUpdated: { scheduleDraftExport() }
                            )
                        }

                        let retained = retainedRemovedExercises(
                            sessionId: draftSession.id,
                            day: activeDay
                        )
                        if !retained.isEmpty {
                            Section("Completed Work Retained for This Workout") {
                                ForEach(retained) { exercise in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(exercise.name)
                                            .font(.headline)
                                        ForEach(entries(
                                            for: exercise.id,
                                            sessionId: draftSession.id
                                        ).filter { $0.isLocked && $0.reps > 0 }) { entry in
                                            Text(
                                                "S\(entry.setIndex) · \(entry.weight, specifier: "%.1f") × \(entry.reps)"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        let skipped = fixedOverrides.filter {
                            $0.sessionId == draftSession.id
                        }
                        if !skipped.isEmpty {
                            Section("Skipped This Workout") {
                                ForEach(skipped) { item in
                                    HStack {
                                        Text(skippedLabel(item))
                                        Spacer()
                                        Button("Restore") {
                                            restoreSkip(item, day: activeDay, sessionId: draftSession.id)
                                        }
                                    }
                                }
                            }
                        }

                        Section("Occurrence Actions") {
                            Picker("Skip reason", selection: $skippedReason) {
                                Text("Recovery").tag("recovery")
                                Text("Time").tag("time")
                                Text("Equipment").tag("equipment")
                                Text("Other").tag("user_choice")
                            }
                        }

                        Section {
                            Button("Add Movement to \(activeDay.label)") {
                                addMovementContext = AddMovementContext(
                                    day: activeDay,
                                    sessionId: draftSession.id,
                                    defaultMuscle: CycleOrdering.sortedSlots(activeDay.slots).last?.muscle ?? .chest
                                )
                            }
                            .disabled(!isFixedExecutionEnabled)
                        }

                        Section {
                            Button("Finish Workout") {
                                finishWorkout()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isFixedExecutionEnabled)
                        }
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
    }

    private func prepareWorkoutState() async {
        refreshLocalDate(.now)
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
        guard export.workout_kind != "ad_hoc" else { return }
        guard let finishedAt = SessionExportService.parseExportDate(export.date) else { return }

        let completed = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: export.cycle_day_index,
            cycleNameSnapshot: export.cycle_name,
            dayLabelSnapshot: "Day \(export.cycle_day_index + 1)",
            createdAt: finishedAt.addingTimeInterval(-60),
            finishedAt: finishedAt,
            status: .completed,
            exportStatus: .pending
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
            if let raw = exportExercise.volume_feedback,
               let rating = ComplexFeedbackRating(rawValue: raw) {
                modelContext.insert(
                    AdHocExerciseFeedback(
                        sessionId: completed.id,
                        exerciseId: exercise.id,
                        rating: rating,
                        createdAt: finishedAt
                    )
                )
            }
        }

        cycle.currentDayIndex = (export.cycle_day_index + 1) % max(1, template.days.count)
        try cycle.validate(template: template)
    }

    private func hydrateMissingCompletedSessionsFromExports(cycle: ActiveCycleInstance) throws {
        try BootstrapDataService.reconcileWorkoutExports(
            BootstrapDataService.allExportSummaries(),
            cycle: cycle,
            modelContext: modelContext
        )
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
            guard isFixedExecutionEnabled else {
                throw FixedCycleWorkoutError.readinessRequired
            }
            guard FixedCycleWorkoutService.hasQualifyingSet(
                sessionId: session.id,
                entries: setEntries
            ) else {
                throw FixedCycleWorkoutError.qualifyingSetRequired
            }
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
            let persistedFixedSnapshots = try modelContext
                .fetch(FetchDescriptor<FixedCycleExerciseSnapshot>())
            let fixedMetadata = dayIndex >= 0 && dayIndex < orderedDays.count
                ? SessionExportService.fixedCycleMetadata(
                    session: session,
                    template: template,
                    day: orderedDays[dayIndex],
                    exercises: exercises,
                    setEntries: setEntries,
                    readiness: fixedReadiness,
                    overrides: fixedOverrides,
                    snapshots: persistedFixedSnapshots
                )
                : nil
            for item in fixedMetadata?.ordered_exercises ?? [] {
                guard let exerciseId = UUID(uuidString: item.exercise_id),
                      let muscle = MuscleGroup(rawValue: item.muscle) else {
                    continue
                }
                if let existing = persistedFixedSnapshots.first(where: {
                    $0.sessionId == session.id
                        && $0.position == item.position
                        && $0.exerciseId == exerciseId
                }) {
                    existing.statusRawValue = item.status
                    existing.skipReason = item.skip_reason
                } else {
                    modelContext.insert(
                        FixedCycleExerciseSnapshot(
                            sessionId: session.id,
                            position: item.position,
                            exerciseId: exerciseId,
                            exerciseName: item.exercise_name,
                            muscle: muscle,
                            statusRawValue: item.status,
                            skipReason: item.skip_reason
                        )
                    )
                }
            }

            do {
                let exportOutcome = try SessionExportService.exportAndTrack(
                    session: session,
                    cycleName: template.name,
                    exercises: exercises,
                    setEntries: setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked },
                    requireICloudMirror: !AppRuntime.isUITesting,
                    fixedCycleMetadata: fixedMetadata,
                    modelContext: modelContext
                )
                if exportOutcome.status == .success {
                    SessionExportService.deleteDraftSnapshot(sessionId: session.id)
                }
            } catch {
                session.exportStatus = .failed
                errorMessage = error.localizedDescription
            }

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

    private func prefillValues(
        exerciseId: UUID,
        setIndex: Int,
        preferredSessionId: UUID? = nil,
        effort: ExerciseEffortLookupResult? = nil
    ) -> (weight: Double, reps: Int) {
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

        if let rows = effort?.rows, !rows.isEmpty {
            let row = rows.first(where: { $0.setIndex == setIndex }) ?? rows.last!
            return (row.weight, row.reps)
        }

        if let global = ExerciseEffortLookupService.globalEffort(
            exerciseId: exerciseId,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: sessions,
            rotationSetEntries: setEntries
        ), !global.rows.isEmpty {
            let row = global.rows.first(where: { $0.setIndex == setIndex }) ?? global.rows.last!
            return (row.weight, row.reps)
        }
        return (0, 0)
    }

    private func addDraftEntries(for session: Session, cycle: ActiveCycleInstance, template: CycleTemplate) throws {
        guard cycle.currentDayIndex >= 0, cycle.currentDayIndex < template.days.count else {
            throw OpenLiftValidationError.invalidCurrentDayIndex(index: cycle.currentDayIndex, dayCount: template.days.count)
        }

        let day = CycleOrdering.sortedDays(template.days)[cycle.currentDayIndex]
        for slot in CycleOrdering.sortedSlots(day.slots) {
            let effort = FixedCycleWorkoutService.prefillEffort(
                exerciseId: slot.exerciseId,
                session: session,
                adaptiveSessions: adaptiveSessions,
                adaptiveSetEntries: adaptiveSetEntries,
                rotationSessions: sessions,
                rotationSetEntries: setEntries
            )
            let setCount = effort?.rows.count ?? slot.defaultSetCount

            for setIndex in 1...max(1, setCount) {
                let prefills = prefillValues(
                    exerciseId: slot.exerciseId,
                    setIndex: setIndex,
                    effort: effort
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

    private func entries(for exerciseId: UUID, sessionId: UUID) -> [SetEntry] {
        setEntries
            .filter { $0.sessionId == sessionId && $0.exerciseId == exerciseId }
            .sorted { $0.setIndex < $1.setIndex }
    }

    private func addSet(for exerciseId: UUID, sessionId: UUID) {
        do {
            guard isFixedExecutionEnabled else {
                throw FixedCycleWorkoutError.readinessRequired
            }
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
            guard isFixedExecutionEnabled else {
                throw FixedCycleWorkoutError.readinessRequired
            }
            guard let last = entries(for: exerciseId, sessionId: sessionId).last else { return }
            modelContext.delete(last)
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedSlots(for day: CycleDay, sessionId: UUID) -> [ResolvedWorkoutSlot] {
        let occurrenceOverrides = fixedOverrides.filter { $0.sessionId == sessionId }
        let skippedMuscles = Set(occurrenceOverrides.filter {
            $0.kind == .skipMuscle
        }.compactMap(\.muscle))
        let skippedPositions = Set(occurrenceOverrides.filter {
            $0.kind == .skipExercise
        }.compactMap(\.slotPosition))
        return CycleOrdering.sortedSlots(day.slots).filter {
            !skippedMuscles.contains($0.muscle) && !skippedPositions.contains($0.position)
        }.map { slot in
            let overrideExerciseId = slotOverrides.first {
                $0.sessionId == sessionId && $0.slotPosition == slot.position
            }?.exerciseId
            return ResolvedWorkoutSlot(
                slot: slot,
                exerciseId: overrideExerciseId ?? slot.exerciseId
            )
        }
    }

    private func retainedRemovedExercises(
        sessionId: UUID,
        day: CycleDay
    ) -> [Exercise] {
        let configured = Set(day.slots.map(\.exerciseId))
        let stagedPosition = Dictionary(
            fixedSnapshots
                .filter { $0.sessionId == sessionId && !configured.contains($0.exerciseId) }
                .map { ($0.exerciseId, $0.position) },
            uniquingKeysWith: min
        )
        let retainedIds = Set(setEntries.filter {
            $0.sessionId == sessionId
                && $0.isLocked
                && $0.reps > 0
                && !configured.contains($0.exerciseId)
        }.map(\.exerciseId))
        return exercises.filter { retainedIds.contains($0.id) }.sorted {
            let left = stagedPosition[$0.id] ?? Int.max
            let right = stagedPosition[$1.id] ?? Int.max
            if left != right { return left < right }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func applySwap(sessionId: UUID, slot: CycleSlot, fromExerciseId: UUID, toExerciseId: UUID) {
        guard fromExerciseId != toExerciseId else { return }

        do {
            guard isFixedExecutionEnabled else {
                throw FixedCycleWorkoutError.readinessRequired
            }
            guard let exercise = exercises.first(where: { $0.id == toExerciseId }),
                  let session = sessions.first(where: { $0.id == sessionId }) else { return }
            let oldCount = max(1, entries(for: fromExerciseId, sessionId: sessionId).count)
            try FixedCycleWorkoutService.replaceExercise(
                slot: slot,
                currentExerciseId: fromExerciseId,
                with: exercise,
                sessionId: sessionId,
                entries: setEntries,
                slotOverrides: slotOverrides,
                modelContext: modelContext
            )
            let effort = FixedCycleWorkoutService.prefillEffort(
                exerciseId: exercise.id,
                session: session,
                adaptiveSessions: adaptiveSessions,
                adaptiveSetEntries: adaptiveSetEntries,
                rotationSessions: sessions,
                rotationSetEntries: setEntries
            )
            let setCount = effort?.rows.count ?? oldCount
            for setIndex in 1...max(1, setCount) {
                let values = prefillValues(
                    exerciseId: exercise.id,
                    setIndex: setIndex,
                    effort: effort
                )
                modelContext.insert(
                    SetEntry(
                        sessionId: sessionId,
                        exerciseId: exercise.id,
                        setIndex: setIndex,
                        weight: values.weight,
                        reps: values.reps
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

    @ViewBuilder
    private func fixedReadinessEntry(
        session: Session,
        template: CycleTemplate,
        day: CycleDay
    ) -> some View {
        ReadinessEntrySections(
            title: "1 · Readiness",
            muscles: FixedCycleWorkoutService.readinessMuscles(
                for: template,
                targeting: day
            ),
            sorenessSelection: sorenessBinding,
            painSelection: painBinding,
            eagernessSelection: $systemicEagerness,
            submitLabel: "Submit Readiness",
            submitAccessibilityIdentifier: "fixed.submitReadiness",
            accessibilityPrefix: "fixed",
            onSubmit: {
                submitReadiness(session: session, template: template, day: day)
            },
            onCancel: nil
        )
        .onAppear {
            prefillFixedReadinessInputs(template: template, day: day)
        }
    }

    private func sorenessBinding(_ muscle: MuscleGroup) -> Binding<SorenessLevel> {
        Binding(
            get: { readinessInputs[muscle]?.soreness ?? .none },
            set: { readinessInputs[muscle, default: FixedCycleWorkoutService.allClear].soreness = $0 }
        )
    }

    private func painBinding(_ muscle: MuscleGroup) -> Binding<ConnectiveTissuePainLevel> {
        Binding(
            get: { readinessInputs[muscle]?.connectiveTissuePain ?? .none },
            set: { readinessInputs[muscle, default: FixedCycleWorkoutService.allClear].connectiveTissuePain = $0 }
        )
    }

    private func submitReadiness(
        session: Session,
        template: CycleTemplate,
        day: CycleDay
    ) {
        do {
            let observation = try FixedCycleWorkoutService.makeReadinessObservation(
                sessionId: session.id,
                template: template,
                day: day,
                inputs: readinessInputs,
                systemicEagerness: systemicEagerness,
                existing: fixedReadiness
            )
            modelContext.insert(observation)
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func refreshLocalDate(_ now: Date) {
        let current = FixedCycleWorkoutService.localDateKey(for: now)
        guard current != observedLocalDateKey else { return }
        observedLocalDateKey = current
        if let activeTemplate, let activeDay {
            readinessInputs = Dictionary(
                uniqueKeysWithValues: FixedCycleWorkoutService
                    .readinessMuscles(for: activeTemplate, targeting: activeDay)
                    .map { ($0, FixedCycleWorkoutService.allClear) }
            )
        } else {
            readinessInputs = [:]
        }
    }

    private func prefillFixedReadinessInputs(
        template: CycleTemplate,
        day: CycleDay
    ) {
        readinessInputs = Dictionary(
            uniqueKeysWithValues: FixedCycleWorkoutService
                .readinessMuscles(for: template, targeting: day)
                .map { ($0, readinessInputs[$0] ?? FixedCycleWorkoutService.allClear) }
        )
        if let latest = fixedReadiness.max(by: {
            ($0.createdAt, $0.revision) < ($1.createdAt, $1.revision)
        }) {
            systemicEagerness = .leastEager(in: latest.responses.map(\.eagerness))
        }
    }

    private func prefillEffort(
        exerciseId: UUID,
        session: Session
    ) -> ExerciseEffortLookupResult? {
        return FixedCycleWorkoutService.prefillEffort(
            exerciseId: exerciseId,
            session: session,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: sessions,
            rotationSetEntries: setEntries
        )
    }

    private func prefillSourceText(_ result: ExerciseEffortLookupResult) -> String {
        let match = result.matchKind == .sameCycleDay ? "Prior same-day effort" : "Global latest effort"
        let kind: String
        switch result.sourceKind {
        case .fixedCycle: kind = "Fixed Cycle"
        case .adaptive: kind = "Adaptive"
        case .adHoc: kind = "Ad hoc"
        }
        return "\(match) · \(kind) · \(result.completedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func skipExerciseToday(
        _ slot: CycleSlot,
        sessionId: UUID,
        reasonCode: String
    ) {
        do {
            guard isFixedExecutionEnabled else { throw FixedCycleWorkoutError.readinessRequired }
            FixedCycleWorkoutService.skipExercise(
                slot: slot,
                sessionId: sessionId,
                reasonCode: reasonCode,
                entries: setEntries,
                existingOverrides: fixedOverrides,
                modelContext: modelContext
            )
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func skipMuscleToday(
        _ muscle: MuscleGroup,
        day: CycleDay,
        sessionId: UUID,
        reasonCode: String
    ) {
        do {
            guard isFixedExecutionEnabled else { throw FixedCycleWorkoutError.readinessRequired }
            FixedCycleWorkoutService.skipMuscle(
                muscle: muscle,
                day: day,
                sessionId: sessionId,
                reasonCode: reasonCode,
                entries: setEntries,
                existingOverrides: fixedOverrides,
                modelContext: modelContext
            )
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSkip(
        _ item: FixedCycleOccurrenceOverride,
        day: CycleDay,
        sessionId: UUID
    ) {
        do {
            guard isFixedExecutionEnabled else {
                throw FixedCycleWorkoutError.readinessRequired
            }
            let slots: [CycleSlot]
            switch item.kind {
            case .skipExercise:
                slots = day.slots.filter { $0.position == item.slotPosition }
            case .skipMuscle:
                slots = day.slots.filter { $0.muscle == item.muscle }
            }
            guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
            modelContext.delete(item)
            for slot in slots where entries(for: slot.exerciseId, sessionId: sessionId).isEmpty {
                let effort = FixedCycleWorkoutService.prefillEffort(
                    exerciseId: slot.exerciseId,
                    session: session,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: sessions,
                    rotationSetEntries: setEntries
                )
                for index in 1...max(1, effort?.rows.count ?? slot.defaultSetCount) {
                    let value = prefillValues(
                        exerciseId: slot.exerciseId,
                        setIndex: index,
                        effort: effort
                    )
                    modelContext.insert(
                        SetEntry(
                            sessionId: sessionId,
                            exerciseId: slot.exerciseId,
                            setIndex: index,
                            weight: value.weight,
                            reps: value.reps
                        )
                    )
                }
            }
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func skippedLabel(_ item: FixedCycleOccurrenceOverride) -> String {
        if item.kind == .skipMuscle {
            return "\(item.muscle?.displayName ?? "Muscle") · \(item.reasonCode)"
        }
        let name = item.exerciseId.flatMap { id in
            exercises.first(where: { $0.id == id })?.name
        } ?? "Exercise"
        return "\(name) · \(item.reasonCode)"
    }

    private func addPersistentMovement(_ exercise: Exercise, day: CycleDay, sessionId: UUID) {
        do {
            guard isFixedExecutionEnabled else { throw FixedCycleWorkoutError.readinessRequired }
            guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
            let effort = FixedCycleWorkoutService.prefillEffort(
                exerciseId: exercise.id,
                session: session,
                adaptiveSessions: adaptiveSessions,
                adaptiveSetEntries: adaptiveSetEntries,
                rotationSessions: sessions,
                rotationSetEntries: setEntries
            )
            let slot = try FixedCycleWorkoutService.addMovement(
                exercise: exercise,
                to: day,
                sessionId: sessionId,
                defaultSetCount: effort?.rows.count ?? 3,
                modelContext: modelContext
            )
            for index in 1...max(1, effort?.rows.count ?? slot.defaultSetCount) {
                let value = prefillValues(exerciseId: exercise.id, setIndex: index, effort: effort)
                modelContext.insert(
                    SetEntry(
                        sessionId: sessionId,
                        exerciseId: exercise.id,
                        setIndex: index,
                        weight: value.weight,
                        reps: value.reps
                    )
                )
            }
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func createExerciseAndAdd(
        name: String,
        muscle: MuscleGroup,
        type: ExerciseType,
        equipment: EquipmentType,
        day: CycleDay,
        sessionId: UUID
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = exercises.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            addPersistentMovement(existing, day: day, sessionId: sessionId)
            return
        }
        let exercise = Exercise(
            name: trimmed,
            primaryMuscle: muscle,
            type: type,
            equipment: equipment
        )
        modelContext.insert(exercise)
        addPersistentMovement(exercise, day: day, sessionId: sessionId)
    }

    private func applyPendingFixedMutation(_ mutation: PendingFixedMutation) {
        pendingFixedMutation = nil
        do {
            guard isFixedExecutionEnabled else { throw FixedCycleWorkoutError.readinessRequired }
            switch mutation {
            case .removeExercise(let day, let slot, let sessionId, _):
                if FixedCycleWorkoutService.hasQualifyingSet(
                    sessionId: sessionId,
                    exerciseIds: Set([slot.exerciseId]),
                    entries: setEntries
                ) {
                    FixedCycleWorkoutService.stageOccurrenceSnapshotsIfNeeded(
                        sessionId: sessionId,
                        day: day,
                        exercises: exercises,
                        existingSnapshots: fixedSnapshots,
                        modelContext: modelContext
                    )
                }
                FixedCycleWorkoutService.removeExercisePersistently(
                    slot: slot,
                    from: day,
                    sessionId: sessionId,
                    entries: setEntries,
                    modelContext: modelContext
                )
            case .removeMuscle(let day, let muscle, let sessionId):
                let exerciseIds = Set(day.slots.filter { $0.muscle == muscle }.map(\.exerciseId))
                if FixedCycleWorkoutService.hasQualifyingSet(
                    sessionId: sessionId,
                    exerciseIds: exerciseIds,
                    entries: setEntries
                ) {
                    FixedCycleWorkoutService.stageOccurrenceSnapshotsIfNeeded(
                        sessionId: sessionId,
                        day: day,
                        exercises: exercises,
                        existingSnapshots: fixedSnapshots,
                        modelContext: modelContext
                    )
                }
                FixedCycleWorkoutService.removeMusclePersistently(
                    muscle: muscle,
                    from: day,
                    sessionId: sessionId,
                    entries: setEntries,
                    modelContext: modelContext
                )
            }
            try modelContext.save()
            scheduleDraftExport()
        } catch {
            modelContext.rollback()
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
            entries: entrySnapshots,
            fixedCycleMetadata: activeDay.map {
                SessionExportService.fixedCycleMetadata(
                    session: session,
                    template: template,
                    day: $0,
                    exercises: exercises,
                    setEntries: setEntries,
                    readiness: fixedReadiness,
                    overrides: fixedOverrides,
                    snapshots: fixedSnapshots
                )
            }
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

        if let iCloudRoot = SessionExportService.iCloudContainerURL()?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(iCloudRoot)
        }
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(docs)
        }

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
                      let payload = SessionExportService.decodeExportPayload(data: data, fileURL: fileURL),
                      let date = SessionExportService.parseExportDate(payload.date),
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
    let dayLabel: String

    var id: String {
        "\(sessionId.uuidString)-\(slot.position)"
    }
}

private struct AddMovementContext: Identifiable {
    let id = UUID()
    let day: CycleDay
    let sessionId: UUID
    let defaultMuscle: MuscleGroup
}

private enum PendingFixedMutation {
    case removeExercise(day: CycleDay, slot: CycleSlot, sessionId: UUID, exerciseName: String)
    case removeMuscle(day: CycleDay, muscle: MuscleGroup, sessionId: UUID)

    var title: String {
        switch self {
        case .removeExercise(let day, _, _, let exerciseName):
            return "Remove \(exerciseName) from future \(day.label) workouts?"
        case .removeMuscle(let day, let muscle, _):
            return "Remove \(muscle.displayName) from future \(day.label) workouts?"
        }
    }

    var message: String {
        switch self {
        case .removeExercise(let day, _, _, let exerciseName):
            return "\(exerciseName) will be removed only from \(day.label). Completed history and the exercise catalog remain unchanged."
        case .removeMuscle(let day, let muscle, _):
            return "The \(muscle.displayName) block will be removed only from \(day.label). Completed history remains unchanged."
        }
    }

    var confirmationLabel: String {
        switch self {
        case .removeExercise(let day, _, _, _):
            return "Remove from Future \(day.label)"
        case .removeMuscle(let day, _, _):
            return "Remove Muscle from Future \(day.label)"
        }
    }
}

struct ExerciseHistoryContext: Identifiable {
    let exerciseId: UUID
    let exerciseName: String

    var id: UUID {
        exerciseId
    }
}

struct ExerciseEffort: Identifiable {
    let id: String
    let date: Date
    let cycleName: String
    let dayLabel: String
    let sets: [ExerciseEffortSet]
}

struct ExerciseEffortSet {
    let setIndex: Int
    let weight: Double
    let reps: Int
}

private struct ExerciseSection: View {
    @Environment(\.modelContext) private var modelContext

    let slot: CycleSlot
    let exercise: Exercise?
    let entries: [SetEntry]
    let isExecutionEnabled: Bool
    let prefillSource: String?
    let onAddSet: () -> Void
    let onRemoveSet: () -> Void
    let onSwap: () -> Void
    let onHistory: () -> Void
    let onSkipToday: () -> Void
    let onSkipMuscleToday: () -> Void
    let onRemoveFuture: () -> Void
    let onRemoveMuscleFuture: () -> Void
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
            if let prefillSource {
                Label(prefillSource, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    .accessibilityIdentifier(
                        "fixed.weight.\(exercise?.name ?? "unknown").\(entry.setIndex)"
                    )
                    .disabled(entry.isLocked)
                    .disabled(!isExecutionEnabled || entry.isLocked)
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
                    .accessibilityIdentifier(
                        "fixed.reps.\(exercise?.name ?? "unknown").\(entry.setIndex)"
                    )
                    .disabled(!isExecutionEnabled || entry.isLocked)
                    .opacity(entry.isLocked ? 1 : 0.55)
                    .focused($focusedField, equals: .reps(entry.id))

                    Button {
                        focusedField = nil
                        if !entry.isLocked && entry.weight == 0 && entry.reps == 0 {
                            return
                        }
                        WorkoutEntryEditing.setLocked(
                            !entry.isLocked,
                            entry: entry
                        )
                        try? modelContext.save()
                        onEntryUpdated()
                    } label: {
                        Image(systemName: entry.isLocked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(entry.isLocked ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "fixed.lock.\(exercise?.name ?? "unknown").\(entry.setIndex)"
                    )
                    .disabled(
                        !isExecutionEnabled
                            || (!entry.isLocked && entry.weight == 0 && entry.reps == 0)
                    )
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
                    .disabled(!isExecutionEnabled)
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
                    .disabled(!isExecutionEnabled)

                    Button(action: onAddSet) {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: actionButtonSize, height: actionButtonSize)
                    .disabled(!isExecutionEnabled)

                    Menu {
                        Button("Skip Exercise for Today", action: onSkipToday)
                        Button("Skip \(slot.muscle.displayName) for Today", action: onSkipMuscleToday)
                        Divider()
                        Button("Remove Exercise from Future Workouts", role: .destructive, action: onRemoveFuture)
                        Button("Remove \(slot.muscle.displayName) from Future Workouts", role: .destructive, action: onRemoveMuscleFuture)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(!isExecutionEnabled)
                }
            }
        }
    }
}

struct ExerciseHistorySheet: View {
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

struct ExerciseSwapSheet: View {
    let currentExercise: Exercise?
    let exercises: [Exercise]
    let slotMuscle: MuscleGroup
    let navigationTitle: String?
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
        navigationTitle: String? = nil,
        onSelect: @escaping (Exercise) -> Void,
        onCreate: @escaping (_ name: String, _ muscle: MuscleGroup, _ type: ExerciseType, _ equipment: EquipmentType) -> Void
    ) {
        self.currentExercise = currentExercise
        self.exercises = exercises
        self.slotMuscle = slotMuscle
        self.navigationTitle = navigationTitle
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
        if let currentExercise {
            return ExerciseSwapService.swapCandidates(
                exercises: exercises,
                selectedMuscle: selectedMuscle,
                currentExerciseId: currentExercise.id
            )
        }
        return exercises
            .filter { $0.isActive && $0.primaryMuscle == selectedMuscle }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if let currentExercise {
                    Section("Current") {
                        Text(currentExercise.name)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Slot Muscle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(slotMuscle.displayName)
                        }
                    }
                }

                Section(currentExercise == nil ? "Add" : "Swap To") {
                    Picker("Muscle", selection: $selectedMuscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("swap.musclePicker")

                    if candidates.isEmpty {
                        Text("No exercises available for \(selectedMuscle.displayName).")
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

                    Button(currentExercise == nil ? "Create & Add" : "Create & Swap") {
                        onCreate(newExerciseName, selectedMuscle, newExerciseType, newExerciseEquipment)
                        dismiss()
                    }
                    .disabled(newExerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(
                navigationTitle ?? (currentExercise == nil ? "Add Movement" : "Swap Exercise")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
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

    static func setLocked(_ isLocked: Bool, entry: SetEntry, at date: Date = .now) {
        guard entry.isLocked != isLocked else { return }
        entry.isLocked = isLocked
        entry.lockedAt = isLocked ? date : nil
    }

    static func setLocked(_ isLocked: Bool, entry: AdaptiveSetEntry, at date: Date = .now) {
        guard entry.isLocked != isLocked else { return }
        entry.isLocked = isLocked
        entry.lockedAt = isLocked ? date : nil
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
