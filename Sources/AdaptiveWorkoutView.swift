import SwiftData
import SwiftUI

struct AdaptiveWorkoutView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var rotationSessions: [Session]
    @Query private var rotationSetEntries: [SetEntry]
    @Query private var adaptivePrograms: [AdaptiveProgram]
    @Query private var readinessChecks: [DailyReadinessCheck]
    @Query private var generatedPlans: [GeneratedWorkoutPlan]
    @Query private var adaptiveSessions: [AdaptiveWorkoutSession]
    @Query private var adaptiveSetEntries: [AdaptiveSetEntry]
    @Query private var occurrenceLinks: [AdaptiveSetOccurrenceLink]
    @Query private var overrides: [AdaptiveOverrideEvent]
    @Query private var complexFeedback: [ComplexFeedback]
    @Query private var adHocFeedback: [AdHocExerciseFeedback]

    @State private var readiness: [MuscleGroup: ReadinessSelection] = Dictionary(
        uniqueKeysWithValues: MuscleGroup.allCases.map { ($0, ReadinessSelection()) }
    )
    @State private var errorMessage: String?
    @State private var swapContext: AdaptiveSwapContext?

    private var activeProgram: AdaptiveProgram? {
        AdaptiveProgramService.activeProgram(from: adaptivePrograms)
    }

    private var todayKey: String {
        AdaptiveWorkoutService.localDateKey(for: .now)
    }

    private var currentPlan: GeneratedWorkoutPlan? {
        guard let program = activeProgram else { return nil }
        return AdaptiveWorkoutService.currentPlan(
            plans: generatedPlans,
            localDateKey: todayKey,
            programId: program.id
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if let program = activeProgram {
                    if !program.isReviewedForUse {
                        unreviewedProfileContent(program)
                    } else if let plan = currentPlan {
                        switch plan.status {
                        case .proposed:
                            previewContent(plan: plan)
                        case .frozen, .inProgress:
                            executionContent(plan: plan)
                        case .completed:
                            completedContent(plan: plan)
                        }
                    } else {
                        readinessContent(program: program)
                    }
                } else {
                    Section {
                        ContentUnavailableView {
                            Label("No Adaptive Profile", systemImage: "slider.horizontal.3")
                        } description: {
                            Text("Create and review an Adaptive profile in Cycle before generating a workout.")
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { adaptiveDismissKeyboard() }
                }
            }
        }
        .sheet(item: $swapContext) { context in
            ExerciseSwapSheet(
                currentExercise: exercises.first(where: { $0.id == context.currentExerciseId }),
                exercises: exercises,
                slotMuscle: context.primaryMuscle,
                onSelect: { selected in
                    substitute(context: context, with: selected)
                    swapContext = nil
                },
                onCreate: { name, muscle, type, equipment in
                    createExerciseAndSubstitute(
                        context: context,
                        name: name,
                        muscle: muscle,
                        type: type,
                        equipment: equipment
                    )
                    swapContext = nil
                }
            )
        }
        .alert(
            "Adaptive Workout Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            _ = try? AdaptiveExportService.hydrateAvailableExports(modelContext: modelContext)
            await seedUITestProfileIfRequested()
        }
    }

    @ViewBuilder
    private func unreviewedProfileContent(_ program: AdaptiveProgram) -> some View {
        Section {
            ContentUnavailableView {
                Label("Profile Review Required", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(program.name) is saved but not approved for real use. Review its floors, caps, difficulties, and complexes in Cycle.")
            }
        }
    }

    @ViewBuilder
    private func readinessContent(program: AdaptiveProgram) -> some View {
        Section("Morning Readiness") {
            Text("Answer every enabled muscle. Disabled muscles are not tracked or considered for recovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Soreness, connective-tissue pain, and eagerness are stored as raw choices; OpenLift derives eligibility locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(enabledMuscles(in: program), id: \.self) { muscle in
            Section(muscle.displayName) {
                Picker("Soreness", selection: sorenessBinding(for: muscle)) {
                    ForEach(SorenessLevel.allCases, id: \.self) { value in
                        Text(value.displayName).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).soreness")

                Picker("Pain", selection: painBinding(for: muscle)) {
                    ForEach(ConnectiveTissuePainLevel.allCases, id: \.self) { value in
                        Text(value.displayName).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("\(muscle.displayName) connective tissue pain")
                .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).pain")

                Picker("Eagerness", selection: eagernessBinding(for: muscle)) {
                    ForEach(EagernessLevel.allCases, id: \.self) { value in
                        Text(value.displayName).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).eagerness")
            }
        }

#if DEBUG
        if AppRuntime.isAdaptiveWorkflowUITesting {
            Section {
                Button("Fill All-Clear Test Readiness") {
                    readiness = Dictionary(uniqueKeysWithValues: enabledMuscles(in: program).map {
                        (
                            $0,
                            ReadinessSelection(
                                soreness: SorenessLevel.none,
                                pain: ConnectiveTissuePainLevel.none,
                                eagerness: .neutral
                            )
                        )
                    })
                }
                .accessibilityIdentifier("adaptive.fillTestReadiness")
            }
        }
#endif

        Section {
            Button("Generate Plan") {
                generateNewPlan(program: program)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!readinessIsComplete(for: program) && !AppRuntime.isAdaptiveWorkflowUITesting)
            .accessibilityIdentifier("adaptive.generatePlan")
        }
    }

    @ViewBuilder
    private func previewContent(plan: GeneratedWorkoutPlan) -> some View {
        Section("Proposed Plan") {
            Text("Nothing has been frozen and no workout session exists yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let complexes = plan.complexes.sorted { $0.position < $1.position }
            let movementCount = complexes.reduce(0) { $0 + $1.exercises.count }
            Text("\(movementCount) component movement(s) · planner v\(plan.plannerVersion)")
                .font(.headline)
        }

        ForEach(plan.complexes.sorted(by: { $0.position < $1.position })) { complex in
            Section {
                ForEach(complex.exercises.sorted(by: { $0.position < $1.position })) { exercise in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.exerciseName)
                            Text("\(exercise.prescribedSetCount) set(s) · \(exercise.difficulty.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let previous = previousRows(plan: plan, complex: complex, exercise: exercise)
                            Text(
                                previous.isEmpty
                                    ? "No prior completed sets for prefill"
                                    : "Previous: \(formatRows(previous))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            swapContext = AdaptiveSwapContext(
                                planId: plan.id,
                                occurrenceId: exercise.occurrenceId,
                                currentExerciseId: exercise.exerciseId,
                                primaryMuscle: exercise.primaryMuscle
                            )
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Substitute \(exercise.exerciseName)")
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(complex.name)
                    Text(complex.reasonCodes.map(humanizedReason).joined(separator: " · "))
                }
            }
        }

        Section {
            Button("Use Workout") { freeze(plan: plan) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("adaptive.useWorkout")
            Button("Regenerate Explicitly") { regenerate(plan: plan) }
                .accessibilityIdentifier("adaptive.regeneratePlan")
        }
    }

    @ViewBuilder
    private func executionContent(plan: GeneratedWorkoutPlan) -> some View {
        if let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) {
            Section("Adaptive Workout") {
                Text(plan.status == .inProgress ? "In progress · frozen plan" : "Frozen plan")
                    .font(.headline)
                Text("Definition edits and new history cannot change this order or prescription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if AdaptiveWorkoutService.canRegenerate(
                    plan: plan,
                    adaptiveSessions: adaptiveSessions,
                    setEntries: adaptiveSetEntries
                ) {
                    Button("Regenerate Before First Locked Set") { regenerate(plan: plan) }
                }
            }

            ForEach(plan.complexes.sorted(by: { $0.position < $1.position })) { complex in
                if isComplexSkipped(complex, plan: plan) {
                    Section(complex.name) {
                        Label("Skipped · recorded as an override", systemImage: "forward.end")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text(complex.reasonCodes.map(humanizedReason).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Skip Complex", role: .destructive) {
                            skipComplex(complex, plan: plan)
                        }
                        .disabled(complexHasLockedSet(complex, session: session))
                    } header: {
                        Text(complex.name)
                    }

                    ForEach(complex.exercises.sorted(by: { $0.position < $1.position })) { snapshot in
                        if isExerciseSkipped(snapshot, plan: plan) {
                            Section(snapshot.exerciseName) {
                                Label("Skipped · recorded as an override", systemImage: "forward.end")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            let entries = entries(for: snapshot.occurrenceId, sessionId: session.id)
                            let effectiveExerciseId = entries.first?.exerciseId ?? snapshot.exerciseId
                            AdaptiveExerciseSection(
                                title: exercises.first(where: { $0.id == effectiveExerciseId })?.name
                                    ?? snapshot.exerciseName,
                                usesAssistanceLoad: exercises.first(where: { $0.id == effectiveExerciseId })?
                                    .adaptiveUsesAssistanceLoad ?? false,
                                entries: entries,
                                onAddSet: { addSet(snapshot: snapshot, session: session) },
                                onRemoveSet: { removeSet(snapshot: snapshot, session: session) },
                                onSwap: {
                                    swapContext = AdaptiveSwapContext(
                                        planId: plan.id,
                                        occurrenceId: snapshot.occurrenceId,
                                        currentExerciseId: effectiveExerciseId,
                                        primaryMuscle: snapshot.primaryMuscle
                                    )
                                },
                                onSkip: { skipExercise(snapshot, plan: plan) },
                                onEntryUpdated: { locked in
                                    if locked {
                                        do {
                                            try AdaptiveWorkoutService.markInProgress(
                                                plan: plan,
                                                modelContext: modelContext
                                            )
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                            )
                        }
                    }

                    if complexIsReadyForFeedback(complex, session: session) {
                        Section("Volume feedback · \(complex.name)") {
                            Picker(
                                "Volume adequacy",
                                selection: feedbackBinding(for: complex, plan: plan)
                            ) {
                                Text("Select feedback").tag(Optional<ComplexFeedbackRating>.none)
                                ForEach(ComplexFeedbackRating.allCases, id: \.self) { rating in
                                    Text(rating.displayName).tag(Optional(rating))
                                }
                            }
                            .accessibilityIdentifier("adaptive.feedbackPicker")
                            Text("Feedback is saved now and can only affect future plans. Pain/problem is recorded separately as a safety signal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Finish Adaptive Workout") { finish(plan: plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(hasMissingFeedback(plan: plan, session: session))
                    .accessibilityIdentifier("adaptive.finishWorkout")
                if hasMissingFeedback(plan: plan, session: session) {
                    Text("Rate every completed, non-skipped complex before finishing. Choose Not sure when appropriate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section {
                ContentUnavailableView(
                    "Session Missing",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The frozen plan exists, but its Adaptive session record is missing.")
                )
            }
        }
    }

    @ViewBuilder
    private func completedContent(plan: GeneratedWorkoutPlan) -> some View {
        Section {
            ContentUnavailableView {
                Label("Adaptive Workout Complete", systemImage: "checkmark.circle")
            } description: {
                Text("Today’s frozen plan is complete. It did not advance your fixed-cycle position.")
            }
        }
    }

    private func enabledMuscles(in program: AdaptiveProgram) -> [MuscleGroup] {
        program.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }
            .map(\.muscle)
    }

    private func readinessIsComplete(for program: AdaptiveProgram) -> Bool {
        enabledMuscles(in: program).allSatisfy { readiness[$0]?.isComplete == true }
    }

    private func readinessInputs() -> [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.compactMap { muscle in
            guard let value = readiness[muscle],
                  let soreness = value.soreness,
                  let pain = value.pain,
                  let eagerness = value.eagerness else { return nil }
            return (
                muscle,
                MuscleReadinessInput(
                    soreness: soreness,
                    connectiveTissuePain: pain,
                    eagerness: eagerness
                )
            )
        })
    }

    private func sorenessBinding(for muscle: MuscleGroup) -> Binding<SorenessLevel?> {
        Binding(
            get: { readiness[muscle]?.soreness },
            set: { readiness[muscle, default: ReadinessSelection()].soreness = $0 }
        )
    }

    private func painBinding(for muscle: MuscleGroup) -> Binding<ConnectiveTissuePainLevel?> {
        Binding(
            get: { readiness[muscle]?.pain },
            set: { readiness[muscle, default: ReadinessSelection()].pain = $0 }
        )
    }

    private func eagernessBinding(for muscle: MuscleGroup) -> Binding<EagernessLevel?> {
        Binding(
            get: { readiness[muscle]?.eagerness },
            set: { readiness[muscle, default: ReadinessSelection()].eagerness = $0 }
        )
    }

    private func generateNewPlan(program: AdaptiveProgram) {
        do {
            guard program.isReviewedForUse else { throw AdaptiveWorkoutServiceError.profileNotReviewed }
            let revision = readinessChecks
                .filter { $0.localDateKey == todayKey && $0.adaptiveProgramId == program.id }
                .map(\.revision)
                .max().map { $0 + 1 } ?? 1
            let check = try AdaptiveWorkoutService.makeReadinessCheck(
                program: program,
                inputs: readinessInputs(),
                localDateKey: todayKey,
                timeZoneIdentifier: TimeZone.current.identifier,
                revision: revision
            )
            modelContext.insert(check)
            try generateAndPersistPlan(program: program, readinessCheck: check)
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func generateAndPersistPlan(
        program: AdaptiveProgram,
        readinessCheck: DailyReadinessCheck
    ) throws {
        let rotationEvidence = TrainingLoadLedgerService.storedEvidence(
            sessions: rotationSessions,
            setEntries: rotationSetEntries,
            exercises: exercises,
            adaptivePlans: generatedPlans,
            occurrenceLinks: occurrenceLinks,
            overrides: overrides
        )
        let adaptiveEvidence = TrainingLoadLedgerService.storedAdaptiveEvidence(
            sessions: adaptiveSessions,
            setEntries: adaptiveSetEntries,
            plans: generatedPlans,
            overrides: overrides,
            exercises: exercises
        )
        let windows = Dictionary(uniqueKeysWithValues: program.muscleRules.map {
            ($0.muscle, $0.rollingWindowDays)
        })
        let ledger = TrainingLoadLedgerService.build(
            evidence: rotationEvidence + adaptiveEvidence,
            asOf: .now,
            rollingWindowDays: windows
        )
        let result = AdaptivePlanService.generate(
            program: program,
            exercises: exercises,
            readiness: AdaptiveWorkoutService.readinessInputs(from: readinessCheck),
            ledger: ledger,
            doseRecommendations: AdaptiveDoseEvidenceService.recommendations(
                program: program,
                plans: generatedPlans,
                sessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                feedback: complexFeedback,
                adHocFeedback: adHocFeedback,
                overrides: overrides,
                readinessCheck: readinessCheck
            ),
            now: .now
        )
        let proposed = try AdaptiveWorkoutService.makeProposedPlan(
            result: result,
            program: program,
            readinessCheck: readinessCheck,
            localDateKey: todayKey,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        modelContext.insert(proposed)
        try modelContext.save()
    }

    private func freeze(plan: GeneratedWorkoutPlan) {
        do {
            _ = try AdaptiveWorkoutService.freeze(
                plan: plan,
                modelContext: modelContext,
                prefill: AdaptivePrefillService.prefill(
                    plan: plan,
                    adaptivePlans: generatedPlans,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries,
                    overrides: overrides
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func previousRows(
        plan: GeneratedWorkoutPlan,
        complex: PlannedComplexSnapshot,
        exercise: PlannedExerciseSnapshot
    ) -> [ComparableSetRow] {
        AdaptivePrefillService.rows(
            plan: plan,
            complex: complex,
            exercise: exercise,
            adaptivePlans: generatedPlans,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries,
            overrides: overrides
        )
    }

    private func formatRows(_ rows: [ComparableSetRow]) -> String {
        rows.map { "\(WeightFormatting.normalized($0.weight)) x \($0.reps)" }.joined(separator: ", ")
    }

    private func regenerate(plan: GeneratedWorkoutPlan) {
        do {
            guard let program = activeProgram,
                  let check = readinessChecks.first(where: { $0.id == plan.readinessCheckId }) else {
                throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
            }
            try AdaptiveWorkoutService.discardForRegeneration(
                plan: plan,
                adaptiveSessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                modelContext: modelContext
            )
            try generateAndPersistPlan(program: program, readinessCheck: check)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish(plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.complete(
                plan: plan,
                adaptiveSessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                modelContext: modelContext
            )
            guard let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }),
                  let readiness = readinessChecks.first(where: { $0.id == plan.readinessCheckId }) else {
                throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
            }
            do {
                try AdaptiveExportService.export(
                    plan: plan,
                    session: session,
                    readiness: readiness,
                    setEntries: adaptiveSetEntries,
                    exercises: exercises,
                    overrides: overrides,
                    feedback: complexFeedback,
                    requireICloudMirror: !AppRuntime.isUITesting
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
                SessionExportService.scheduleBackgroundExportRetry()
                errorMessage = error.localizedDescription
            }
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func complexIsReadyForFeedback(
        _ complex: PlannedComplexSnapshot,
        session: AdaptiveWorkoutSession
    ) -> Bool {
        let skippedOccurrences = Set(overrides.filter {
            $0.generatedPlanId == session.generatedPlanId && $0.kind == .skipExercise
        }.compactMap(\.occurrenceId))
        let relevant = complex.exercises.filter { !skippedOccurrences.contains($0.occurrenceId) }
        guard !relevant.isEmpty else { return false }
        return relevant.allSatisfy { snapshot in
            adaptiveSetEntries.contains {
                $0.adaptiveSessionId == session.id
                    && $0.occurrenceId == snapshot.occurrenceId
                    && $0.isLocked
                    && $0.reps > 0
            }
        }
    }

    private func hasMissingFeedback(
        plan: GeneratedWorkoutPlan,
        session: AdaptiveWorkoutSession
    ) -> Bool {
        let skippedComplexes = Set(overrides.filter {
            $0.generatedPlanId == plan.id && $0.kind == .skipComplex
        }.compactMap(\.plannedComplexId))
        return plan.complexes.contains { complex in
            !skippedComplexes.contains(complex.id)
                && complexIsReadyForFeedback(complex, session: session)
                && feedbackFor(complex, plan: plan) == nil
        }
    }

    private func feedbackFor(
        _ complex: PlannedComplexSnapshot,
        plan: GeneratedWorkoutPlan
    ) -> ComplexFeedbackRating? {
        complexFeedback
            .filter { $0.generatedPlanId == plan.id && $0.plannedComplexId == complex.id }
            .max(by: { $0.createdAt < $1.createdAt })?
            .rating
    }

    private func feedbackBinding(
        for complex: PlannedComplexSnapshot,
        plan: GeneratedWorkoutPlan
    ) -> Binding<ComplexFeedbackRating?> {
        Binding(
            get: { feedbackFor(complex, plan: plan) },
            set: { rating in
                guard let rating else { return }
                do {
                    try AdaptiveWorkoutService.recordFeedback(
                        plan: plan,
                        complex: complex,
                        rating: rating,
                        existingFeedback: complexFeedback,
                        modelContext: modelContext
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func entries(for occurrenceId: UUID, sessionId: UUID) -> [AdaptiveSetEntry] {
        adaptiveSetEntries
            .filter { $0.adaptiveSessionId == sessionId && $0.occurrenceId == occurrenceId }
            .sorted { $0.setIndex < $1.setIndex }
    }

    private func addSet(snapshot: PlannedExerciseSnapshot, session: AdaptiveWorkoutSession) {
        let existing = entries(for: snapshot.occurrenceId, sessionId: session.id)
        let exerciseId = existing.first?.exerciseId ?? snapshot.exerciseId
        modelContext.insert(
            AdaptiveSetEntry(
                adaptiveSessionId: session.id,
                occurrenceId: snapshot.occurrenceId,
                exerciseId: exerciseId,
                setIndex: (existing.map(\.setIndex).max() ?? 0) + 1
            )
        )
        do { try modelContext.save() } catch { errorMessage = error.localizedDescription }
    }

    private func removeSet(snapshot: PlannedExerciseSnapshot, session: AdaptiveWorkoutSession) {
        let existing = entries(for: snapshot.occurrenceId, sessionId: session.id)
        guard existing.count > 1, let last = existing.last, !last.isLocked else { return }
        modelContext.delete(last)
        do { try modelContext.save() } catch { errorMessage = error.localizedDescription }
    }

    private func skipComplex(_ complex: PlannedComplexSnapshot, plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.recordSkip(
                plan: plan,
                complexId: complex.id,
                occurrenceId: nil,
                kind: .skipComplex,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func skipExercise(_ snapshot: PlannedExerciseSnapshot, plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.recordSkip(
                plan: plan,
                complexId: nil,
                occurrenceId: snapshot.occurrenceId,
                kind: .skipExercise,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func isComplexSkipped(_ complex: PlannedComplexSnapshot, plan: GeneratedWorkoutPlan) -> Bool {
        overrides.contains {
            $0.generatedPlanId == plan.id && $0.plannedComplexId == complex.id && $0.kind == .skipComplex
        }
    }

    private func isExerciseSkipped(_ snapshot: PlannedExerciseSnapshot, plan: GeneratedWorkoutPlan) -> Bool {
        overrides.contains {
            $0.generatedPlanId == plan.id && $0.occurrenceId == snapshot.occurrenceId && $0.kind == .skipExercise
        }
    }

    private func complexHasLockedSet(
        _ complex: PlannedComplexSnapshot,
        session: AdaptiveWorkoutSession
    ) -> Bool {
        let occurrenceIds = Set(complex.exercises.map(\.occurrenceId))
        return adaptiveSetEntries.contains {
            $0.adaptiveSessionId == session.id && occurrenceIds.contains($0.occurrenceId) && $0.isLocked
        }
    }

    private func substitute(context: AdaptiveSwapContext, with exercise: Exercise) {
        guard let plan = generatedPlans.first(where: { $0.id == context.planId }) else { return }
        do {
            if plan.status == .proposed {
                try AdaptiveWorkoutService.substituteProposedExercise(
                    plan: plan,
                    occurrenceId: context.occurrenceId,
                    to: exercise,
                    modelContext: modelContext
                )
            } else {
                try AdaptiveWorkoutService.substitute(
                    plan: plan,
                    occurrenceId: context.occurrenceId,
                    fromExerciseId: context.currentExerciseId,
                    toExerciseId: exercise.id,
                    adaptiveSessions: adaptiveSessions,
                    setEntries: adaptiveSetEntries,
                    modelContext: modelContext
                )
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createExerciseAndSubstitute(
        context: AdaptiveSwapContext,
        name: String,
        muscle: MuscleGroup,
        type: ExerciseType,
        equipment: EquipmentType
    ) {
        do {
            let exercise = try ExerciseCatalogService.makeExercise(
                name: name,
                primaryMuscle: muscle,
                type: type,
                equipment: equipment,
                existingExercises: exercises
            )
            modelContext.insert(exercise)
            try modelContext.save()
            substitute(context: context, with: exercise)
        } catch { errorMessage = error.localizedDescription }
    }

    private func humanizedReason(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @MainActor
    private func seedUITestProfileIfRequested() async {
#if DEBUG
        guard AppRuntime.isAdaptiveWorkflowUITesting, adaptivePrograms.isEmpty else { return }
        do {
            let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
            guard let chest = catalog.first(where: { $0.primaryMuscle == .chest }) else { return }
            var draft = AdaptiveProgramDraft.blank
            draft.name = "UI Test Adaptive"
            draft.isReviewedForUse = true
            draft.muscleRules = draft.muscleRules.map { rule in
                var copy = rule
                copy.isEnabled = rule.muscle == .chest
                copy.priorityRank = rule.muscle == .chest ? 1 : 0
                copy.rollingSetFloor = 0
                return copy
            }
            draft.complexes = [
                AdaptiveExerciseComplexDraft(
                    id: UUID(),
                    definitionId: UUID(),
                    sourceVersion: 0,
                    name: "UI Test Chest",
                    primaryMuscle: .chest,
                    qualifiesForPrimaryFloor: true,
                    isEnabled: true,
                    components: [
                        AdaptiveComplexComponentDraft(
                            id: UUID(),
                            exerciseId: chest.id,
                            prescribedSetCount: 1,
                            primaryMuscle: .chest,
                            secondaryMuscle: nil,
                            difficulty: .easy
                        )
                    ]
                )
            ]
            _ = try AdaptiveProgramService.saveVersion(
                draft: draft,
                replacing: nil,
                allPrograms: adaptivePrograms,
                exercises: catalog,
                modelContext: modelContext
            )
            readiness = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
                (
                    $0,
                    ReadinessSelection(
                        soreness: SorenessLevel.none,
                        pain: ConnectiveTissuePainLevel.none,
                        eagerness: .neutral
                    )
                )
            })
        } catch {
            errorMessage = error.localizedDescription
        }
#endif
    }
}

private struct ReadinessSelection {
    var soreness: SorenessLevel?
    var pain: ConnectiveTissuePainLevel?
    var eagerness: EagernessLevel?

    var isComplete: Bool {
        soreness != nil && pain != nil && eagerness != nil
    }
}

private struct AdaptiveSwapContext: Identifiable {
    let id = UUID()
    let planId: UUID
    let occurrenceId: UUID
    let currentExerciseId: UUID
    let primaryMuscle: MuscleGroup
}

private struct AdaptiveExerciseSection: View {
    @Environment(\.modelContext) private var modelContext

    let title: String
    let usesAssistanceLoad: Bool
    let entries: [AdaptiveSetEntry]
    let onAddSet: () -> Void
    let onRemoveSet: () -> Void
    let onSwap: () -> Void
    let onSkip: () -> Void
    let onEntryUpdated: (Bool) -> Void

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
                                applyWeightEdit(entry: entry, newWeight: newWeight)
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
                                applyRepsEdit(entry: entry, newReps: newReps)
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
                        guard entry.isLocked || entry.weight != 0 || entry.reps != 0 else { return }
                        entry.isLocked.toggle()
                        try? modelContext.save()
                        onEntryUpdated(entry.isLocked)
                    } label: {
                        Image(systemName: entry.isLocked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(entry.isLocked ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isLocked && entry.weight == 0 && entry.reps == 0)
                    .accessibilityLabel(entry.isLocked ? "Unlock set \(entry.setIndex)" : "Lock set \(entry.setIndex)")
                    .accessibilityIdentifier("adaptive.lockSet.\(entry.setIndex)")
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Button(action: onSwap) { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Substitute \(title)")
                    .disabled(entries.contains(where: \.isLocked))
                Button(action: onSkip) { Image(systemName: "forward.end") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Skip \(title)")
                    .disabled(entries.contains(where: \.isLocked))
                Button(action: onRemoveSet) { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onAddSet) { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func applyWeightEdit(entry: AdaptiveSetEntry, newWeight: Double?) {
        var states = entries.map {
            WorkoutEntryEditing.EntryState(
                setIndex: $0.setIndex,
                weight: $0.weight,
                reps: $0.reps,
                isLocked: $0.isLocked
            )
        }
        WorkoutEntryEditing.applyWeightEdit(to: &states, setIndex: entry.setIndex, newWeight: newWeight)
        apply(states)
    }

    private func applyRepsEdit(entry: AdaptiveSetEntry, newReps: Int?) {
        var states = entries.map {
            WorkoutEntryEditing.EntryState(
                setIndex: $0.setIndex,
                weight: $0.weight,
                reps: $0.reps,
                isLocked: $0.isLocked
            )
        }
        WorkoutEntryEditing.applyRepsEdit(to: &states, setIndex: entry.setIndex, newReps: newReps)
        apply(states)
    }

    private func apply(_ states: [WorkoutEntryEditing.EntryState]) {
        for entry in entries {
            guard let state = states.first(where: { $0.setIndex == entry.setIndex }) else { continue }
            entry.weight = state.weight
            entry.reps = state.reps
            entry.isLocked = state.isLocked
        }
        try? modelContext.save()
        onEntryUpdated(states.contains(where: \.isLocked))
    }
}

private extension Exercise {
    var adaptiveUsesAssistanceLoad: Bool {
        let normalized = name.lowercased()
        return normalized.contains("assisted pull-up") || normalized.contains("assisted dips")
    }
}

private func adaptiveDismissKeyboard() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}
