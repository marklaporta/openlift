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
    @Query private var exerciseSelectionPreferences: [AdaptiveExerciseSelectionPreference]
    @Query private var workoutSizePreferences: [AdaptiveWorkoutSizePreference]
    @Query private var planDesignStates: [AdaptivePlanDesignState]

    @State private var readiness: [MuscleGroup: ReadinessSelection] = Dictionary(
        uniqueKeysWithValues: MuscleGroup.allCases.map { ($0, ReadinessSelection()) }
    )
    @State private var errorMessage: String?
    @State private var swapContext: AdaptiveSwapContext?
    @State private var addMovementContext: AdaptiveAddMovementContext?
    @State private var addComplexContext: AdaptiveAddComplexContext?
    @State private var isEditingReadiness = false
    @State private var pendingFinishPlanId: UUID?

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
                            if isEditingReadiness {
                                readinessContent(program: program, editingPlan: plan)
                            } else {
                                previewContent(plan: plan)
                            }
                        case .frozen, .inProgress:
                            executionContent(plan: plan)
                        case .completed:
                            completedContent(plan: plan)
                        }
                    } else {
                        readinessContent(program: program, editingPlan: nil)
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
        .sheet(item: $addMovementContext) { context in
            ExerciseSwapSheet(
                currentExercise: nil,
                exercises: exercises,
                slotMuscle: context.primaryMuscle,
                onSelect: { exercise in
                    addMovement(exercise, context: context)
                    addMovementContext = nil
                },
                onCreate: { name, muscle, type, equipment in
                    createExerciseAndAddMovement(
                        context: context,
                        name: name,
                        muscle: muscle,
                        type: type,
                        equipment: equipment
                    )
                    addMovementContext = nil
                }
            )
        }
        .sheet(item: $addComplexContext) { context in
            AdaptiveAddComplexSheet(
                muscles: context.availableMuscles,
                program: activeProgram,
                onSelectConfigured: { definition in
                    appendConfiguredComplex(definition, planId: context.planId)
                    addComplexContext = nil
                },
                onBuildManually: { muscle in
                    addComplexContext = nil
                    addMovementContext = AdaptiveAddMovementContext(
                        planId: context.planId,
                        complexId: nil,
                        primaryMuscle: muscle
                    )
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
            if !AppRuntime.isUITesting {
                _ = try? AdaptiveExportService.hydrateAvailableExports(modelContext: modelContext)
            }
            await seedUITestProfileIfRequested()
        }
    }

    @ViewBuilder
    private func unreviewedProfileContent(_ program: AdaptiveProgram) -> some View {
        Section {
            ContentUnavailableView {
                Label("Profile Review Required", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Review and approve this profile in Cycle before generating a workout.")
            }
        }
    }

    @ViewBuilder
    private func readinessContent(program: AdaptiveProgram, editingPlan: GeneratedWorkoutPlan?) -> some View {
        Section(editingPlan == nil ? "1 · Readiness" : "Edit Readiness") {
            Text("Adjust anything that is not at its recovered default, then submit once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(enabledMuscles(in: program), id: \.self) { muscle in
            Section(muscle.displayName) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Muscle soreness")
                        .font(.subheadline.weight(.semibold))
                    Text("How sore this muscle feels today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Muscle soreness", selection: sorenessBinding(for: muscle)) {
                        ForEach(SorenessLevel.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("\(muscle.displayName) muscle soreness")
                    .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).soreness")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connective-tissue pain")
                        .font(.subheadline.weight(.semibold))
                    Text("Joint or tendon warning signs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Connective-tissue pain", selection: painBinding(for: muscle)) {
                        ForEach(ConnectiveTissuePainLevel.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("\(muscle.displayName) connective-tissue pain")
                    .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).pain")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Eagerness to train")
                        .font(.subheadline.weight(.semibold))
                    Text("How willing this muscle feels to work today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Eagerness to train", selection: eagernessBinding(for: muscle)) {
                        ForEach(EagernessLevel.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("\(muscle.displayName) eagerness to train")
                    .accessibilityIdentifier("adaptive.readiness.\(muscle.rawValue).eagerness")
                }
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
                                eagerness: .eager
                            )
                        )
                    })
                }
                .accessibilityIdentifier("adaptive.fillTestReadiness")
            }
        }
#endif

        Section {
            Button(editingPlan == nil ? "Submit Readiness" : "Update Readiness") {
                submitReadiness(program: program, editingPlan: editingPlan)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("adaptive.generatePlan")
            if editingPlan != nil {
                Button("Cancel") { isEditingReadiness = false }
            }
        }
    }

    @ViewBuilder
    private func previewContent(plan: GeneratedWorkoutPlan) -> some View {
        Section("2 · Design") {
            let complexes = plan.complexes.sorted { $0.position < $1.position }
            let target = designState(for: plan)?.targetComplexCount ?? complexes.count
            HStack {
                Text("Today: \(target) muscle group\(target == 1 ? "" : "s")")
                Spacer()
                Button { updateTodayTarget(plan: plan, target: target - 1) } label: {
                    Image(systemName: "minus")
                }
                .disabled(target <= 1)
                .accessibilityLabel("Decrease today's muscle-group target")
                .accessibilityIdentifier("adaptive.decreaseTarget")
                Button { updateTodayTarget(plan: plan, target: target + 1) } label: {
                    Image(systemName: "plus")
                }
                .disabled(target >= enabledMuscles(in: activeProgram!).count)
                .accessibilityLabel("Increase today's muscle-group target")
                .accessibilityIdentifier("adaptive.increaseTarget")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text("\(complexes.count) proposed exposure\(complexes.count == 1 ? "" : "s")")
                .font(.subheadline)
                .accessibilityValue(
                    complexes
                        .flatMap(\.exercises)
                        .sorted { $0.position < $1.position }
                        .map(\.exerciseName)
                        .joined(separator: ", ")
                )
            Button {
                loadReadiness(from: plan)
                isEditingReadiness = true
            } label: {
                Label("Edit Readiness", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("adaptive.editReadiness")
        }

        ForEach(plan.complexes.sorted(by: { $0.position < $1.position })) { complex in
            Section {
                ForEach(complex.exercises.sorted(by: { $0.position < $1.position })) { exercise in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.exerciseName)
                            Text("\(exercise.prescribedSetCount) set\(exercise.prescribedSetCount == 1 ? "" : "s")")
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
                            .accessibilityIdentifier("adaptive.previous.\(exercise.exerciseName)")
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            HStack(spacing: 5) {
                                Button {
                                    moveMovement(exercise, in: plan, direction: .earlier)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(!canMoveMovement(exercise, in: plan, direction: .earlier))
                                .accessibilityLabel("Move \(exercise.exerciseName) earlier")
                                .accessibilityIdentifier("adaptive.moveEarlier.\(exercise.occurrenceId.uuidString)")
                                Button {
                                    moveMovement(exercise, in: plan, direction: .later)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .disabled(!canMoveMovement(exercise, in: plan, direction: .later))
                                .accessibilityLabel("Move \(exercise.exerciseName) later")
                                .accessibilityIdentifier("adaptive.moveLater.\(exercise.occurrenceId.uuidString)")
                            }
                            HStack(spacing: 5) {
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
                                .accessibilityLabel("Substitute \(exercise.exerciseName)")
                                Button(role: .destructive) {
                                    removeMovement(exercise, from: plan)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel("Remove \(exercise.exerciseName)")
                                .accessibilityIdentifier("adaptive.removeMovement.\(exercise.occurrenceId.uuidString)")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                complexHeader(complex: complex, plan: plan, isExecuting: false)
            }
        }

        Section {
            Button {
                presentAddComplex(for: plan)
            } label: {
                Label("Add Complex", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("adaptive.addComplex")
            Button("Use Workout") { freeze(plan: plan) }
                .buttonStyle(.borderedProminent)
                .disabled(plan.complexes.flatMap(\.exercises).isEmpty)
                .accessibilityIdentifier("adaptive.useWorkout")
            Button("New Proposal") { regenerate(plan: plan) }
                .accessibilityIdentifier("adaptive.regeneratePlan")
        }
    }

    @ViewBuilder
    private func executionContent(plan: GeneratedWorkoutPlan) -> some View {
        if let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) {
            Section("3 · Execute") {
                HStack {
                    Button {
                        presentAddComplex(for: plan)
                    } label: {
                        Label("Add Complex", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("adaptive.addComplex.execute")
                    Spacer()
                if AdaptiveWorkoutService.canRegenerate(
                    plan: plan,
                    adaptiveSessions: adaptiveSessions,
                    setEntries: adaptiveSetEntries
                ) {
                        Button("Regenerate") { regenerate(plan: plan) }
                            .accessibilityLabel("Regenerate Before First Locked Set")
                            .accessibilityIdentifier("adaptive.regenerateBeforeFirstSet")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(plan.complexes.sorted(by: { $0.position < $1.position })) { complex in
                if isComplexSkipped(complex, plan: plan) {
                    Section {
                        complexHeader(complex: complex, plan: plan, isExecuting: true)
                        Label("Skipped", systemImage: "forward.end")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        complexHeader(complex: complex, plan: plan, isExecuting: true)
                    }

                    ForEach(complex.exercises.sorted(by: { $0.position < $1.position })) { snapshot in
                        if isExerciseSkipped(snapshot, plan: plan) {
                            Section(snapshot.exerciseName) {
                                Label("Skipped", systemImage: "forward.end")
                                    .foregroundStyle(.secondary)
                                Button {
                                    unskipExercise(snapshot, plan: plan)
                                } label: {
                                    Label("Restore Exercise", systemImage: "arrow.uturn.backward")
                                }
                                .accessibilityLabel("Restore \(snapshot.exerciseName)")
                                .accessibilityIdentifier("adaptive.restore.\(snapshot.occurrenceId.uuidString)")
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
                                canMoveEarlier: canMoveMovement(snapshot, in: plan, direction: .earlier),
                                canMoveLater: canMoveMovement(snapshot, in: plan, direction: .later),
                                onMoveEarlier: { moveMovement(snapshot, in: plan, direction: .earlier) },
                                onMoveLater: { moveMovement(snapshot, in: plan, direction: .later) },
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
                                onRemove: { removeMovement(snapshot, from: plan) },
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
                            Text("Used to adjust future set recommendations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Finish Adaptive Workout") { pendingFinishPlanId = plan.id }
                    .buttonStyle(.borderedProminent)
                    .disabled(hasMissingFeedback(plan: plan, session: session))
                    .accessibilityIdentifier("adaptive.finishWorkout")
                    .alert(
                        "Finish Adaptive Workout?",
                        isPresented: Binding(
                            get: { pendingFinishPlanId == plan.id },
                            set: { if !$0 { pendingFinishPlanId = nil } }
                        )
                    ) {
                        Button("Finish Workout", role: .destructive) {
                            pendingFinishPlanId = nil
                            finish(plan: plan)
                        }
                        Button("Keep Editing", role: .cancel) {
                            pendingFinishPlanId = nil
                        }
                    } message: {
                        Text("Completion is final and exports this workout. Confirm only when you are finished editing sets, exercises, and feedback.")
                    }
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
            }
        }

        if let program = activeProgram,
           let prediction = tomorrowPrediction(program: program) {
            Section {
                Text("Assumes tomorrow's soreness, connective-tissue pain, and eagerness match normal recovery. Actual readiness can change the workout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(prediction.complexes, id: \.definitionId) { complex in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(complex.primaryMuscle.displayName)
                            .font(.headline)
                        Text(complex.components.map(\.exerciseName).joined(separator: " + "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tomorrow · Expected")
                    .accessibilityIdentifier("adaptive.tomorrowPrediction")
            }
        }
    }

    private func enabledMuscles(in program: AdaptiveProgram) -> [MuscleGroup] {
        program.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }
            .map(\.muscle)
    }

    private func loadReadiness(from plan: GeneratedWorkoutPlan) {
        guard let check = readinessChecks.first(where: { $0.id == plan.readinessCheckId }) else { return }
        readiness = Dictionary(uniqueKeysWithValues: check.responses.map {
            (
                $0.muscle,
                ReadinessSelection(
                    soreness: $0.soreness,
                    pain: $0.connectiveTissuePain,
                    eagerness: $0.eagerness
                )
            )
        })
    }

    @ViewBuilder
    private func complexHeader(
        complex: PlannedComplexSnapshot,
        plan: GeneratedWorkoutPlan,
        isExecuting: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(complex.primaryMuscle.displayName)
            Spacer()
            Button {
                addMovementContext = AdaptiveAddMovementContext(
                    planId: plan.id,
                    complexId: complex.id,
                    primaryMuscle: complex.primaryMuscle
                )
            } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add exercise to \(complex.primaryMuscle.displayName)")
                .accessibilityIdentifier("adaptive.addToComplex.\(complex.id.uuidString)")
            Button { moveComplex(complex, in: plan, direction: .earlier) } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!canMoveComplex(complex, in: plan, direction: .earlier))
            .accessibilityLabel("Move \(complex.primaryMuscle.displayName) earlier")
            Button { moveComplex(complex, in: plan, direction: .later) } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(!canMoveComplex(complex, in: plan, direction: .later))
            .accessibilityLabel("Move \(complex.primaryMuscle.displayName) later")
            if isExecuting {
                Button {
                    if isComplexSkipped(complex, plan: plan) {
                        unskipComplex(complex, plan: plan)
                    } else {
                        skipComplex(complex, plan: plan)
                    }
                } label: {
                    Image(systemName: isComplexSkipped(complex, plan: plan)
                        ? "arrow.uturn.backward" : "forward.end")
                }
                .accessibilityLabel(
                    isComplexSkipped(complex, plan: plan)
                        ? "Restore \(complex.primaryMuscle.displayName) complex"
                        : "Skip \(complex.primaryMuscle.displayName) complex"
                )
            }
            Button(role: .destructive) { removeComplex(complex, from: plan) } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove \(complex.primaryMuscle.displayName) complex")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func readinessInputs() -> [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            let value = readiness[muscle] ?? ReadinessSelection()
            return (
                muscle,
                MuscleReadinessInput(
                    soreness: value.soreness,
                    connectiveTissuePain: value.pain,
                    eagerness: value.eagerness
                )
            )
        })
    }

    private func sorenessBinding(for muscle: MuscleGroup) -> Binding<SorenessLevel> {
        Binding(
            get: { readiness[muscle]?.soreness ?? .none },
            set: { readiness[muscle, default: ReadinessSelection()].soreness = $0 }
        )
    }

    private func painBinding(for muscle: MuscleGroup) -> Binding<ConnectiveTissuePainLevel> {
        Binding(
            get: { readiness[muscle]?.pain ?? .none },
            set: { readiness[muscle, default: ReadinessSelection()].pain = $0 }
        )
    }

    private func eagernessBinding(for muscle: MuscleGroup) -> Binding<EagernessLevel> {
        Binding(
            get: { readiness[muscle]?.eagerness ?? .eager },
            set: { readiness[muscle, default: ReadinessSelection()].eagerness = $0 }
        )
    }

    private func submitReadiness(program: AdaptiveProgram, editingPlan: GeneratedWorkoutPlan?) {
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
            let requestedTarget = editingPlan.flatMap(designState(for:))?.targetComplexCount
                ?? AdaptiveProgramService.defaultComplexCount(
                    for: program,
                    preferences: workoutSizePreferences
                )
            let target = max(1, min(requestedTarget, enabledMuscles(in: program).count))
            let candidate = try makePlan(
                program: program,
                readinessCheck: check,
                targetComplexCount: target
            )
            if let editingPlan, let state = designState(for: editingPlan) {
                _ = try AdaptiveWorkoutService.reconcileReadinessRevision(
                    existingPlan: editingPlan,
                    existingState: state,
                    candidatePlan: candidate,
                    readinessCheck: check,
                    overrides: overrides,
                    modelContext: modelContext
                )
            } else {
                modelContext.insert(candidate)
                modelContext.insert(
                    AdaptiveWorkoutService.makeDesignState(
                        plan: candidate,
                        targetComplexCount: target,
                        readinessRevision: check.revision
                    )
                )
                try modelContext.save()
            }
            isEditingReadiness = false
            if !AppRuntime.isUITesting {
                _ = try AdaptiveReadinessExportService.enqueueMirror(
                    check: check,
                    modelContext: modelContext
                )
            }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func makePlan(
        program: AdaptiveProgram,
        readinessCheck: DailyReadinessCheck,
        targetComplexCount: Int
    ) throws -> GeneratedWorkoutPlan {
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
        let exerciseSelections = AdaptiveExerciseSelectionService.recommendations(
            exercises: exercises,
            preferences: exerciseSelectionPreferences,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries
        )
        let result = AdaptivePlanService.generate(
            program: program,
            exercises: exercises,
            readiness: AdaptiveWorkoutService.readinessInputs(from: readinessCheck),
            ledger: ledger,
            targetComplexCount: targetComplexCount,
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
            exerciseSelections: exerciseSelections,
            now: .now
        )
        return try AdaptiveWorkoutService.makeProposedPlan(
            result: result,
            program: program,
            readinessCheck: readinessCheck,
            localDateKey: todayKey,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    private func tomorrowPrediction(program: AdaptiveProgram) -> AdaptivePlanProposal? {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) else {
            return nil
        }
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
            asOf: tomorrow,
            rollingWindowDays: windows
        )
        let target = min(
            AdaptiveProgramService.defaultComplexCount(
                for: program,
                preferences: workoutSizePreferences
            ),
            enabledMuscles(in: program).count
        )
        return AdaptiveForecastService.expectedProposal(
            program: program,
            exercises: exercises,
            ledger: ledger,
            targetComplexCount: max(1, target),
            exerciseSelections: AdaptiveExerciseSelectionService.recommendations(
                exercises: exercises,
                preferences: exerciseSelectionPreferences,
                rotationSessions: rotationSessions,
                rotationSetEntries: rotationSetEntries,
                adaptiveSessions: adaptiveSessions,
                adaptiveSetEntries: adaptiveSetEntries
            ),
            asOf: tomorrow
        )
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
            let oldDesignState = designState(for: plan)
            let requestedTarget = oldDesignState?.targetComplexCount
                ?? AdaptiveProgramService.defaultComplexCount(
                    for: program,
                    preferences: workoutSizePreferences
                )
            let target = max(1, min(requestedTarget, enabledMuscles(in: program).count))
            if let oldDesignState { modelContext.delete(oldDesignState) }
            try AdaptiveWorkoutService.discardForRegeneration(
                plan: plan,
                adaptiveSessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                overrides: overrides,
                modelContext: modelContext
            )
            let proposed = try makePlan(
                program: program,
                readinessCheck: check,
                targetComplexCount: target
            )
            modelContext.insert(proposed)
            modelContext.insert(
                AdaptiveWorkoutService.makeDesignState(
                    plan: proposed,
                    targetComplexCount: target,
                    readinessRevision: check.revision
                )
            )
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func designState(for plan: GeneratedWorkoutPlan) -> AdaptivePlanDesignState? {
        planDesignStates.first { $0.generatedPlanId == plan.id }
    }

    private func updateTodayTarget(plan: GeneratedWorkoutPlan, target: Int) {
        guard let program = activeProgram,
              let check = readinessChecks.first(where: { $0.id == plan.readinessCheckId }) else { return }
        do {
            let boundedTarget = max(1, min(target, enabledMuscles(in: program).count))
            let proposed = try makePlan(
                program: program,
                readinessCheck: check,
                targetComplexCount: boundedTarget
            )
            AdaptiveWorkoutService.deleteAuditRecords(
                generatedPlanId: plan.id,
                overrides: overrides,
                modelContext: modelContext
            )
            if let state = designState(for: plan) { modelContext.delete(state) }
            modelContext.delete(plan)
            modelContext.insert(proposed)
            modelContext.insert(
                AdaptiveWorkoutService.makeDesignState(
                    plan: proposed,
                    targetComplexCount: boundedTarget,
                    readinessRevision: check.revision
                )
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
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
                _ = try AdaptiveExportService.exportAndTrack(
                    plan: plan,
                    session: session,
                    readiness: readiness,
                    setEntries: adaptiveSetEntries,
                    exercises: exercises,
                    overrides: overrides,
                    feedback: complexFeedback,
                    requireICloudMirror: !AppRuntime.isUITesting,
                    modelContext: modelContext
                )
            } catch {
                session.exportStatus = .failed
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
        let relevant = complex.exercises.filter {
            !AdaptiveWorkoutService.isExerciseSkipped(
                planId: session.generatedPlanId,
                occurrenceId: $0.occurrenceId,
                overrides: overrides
            )
        }
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
        return plan.complexes.contains { complex in
            !AdaptiveWorkoutService.isComplexSkipped(
                planId: plan.id,
                complexId: complex.id,
                overrides: overrides
            )
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
        do {
            _ = try AdaptiveWorkoutService.addSet(
                snapshot: snapshot,
                session: session,
                existingEntries: existing,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeSet(snapshot: PlannedExerciseSnapshot, session: AdaptiveWorkoutSession) {
        let existing = entries(for: snapshot.occurrenceId, sessionId: session.id)
        do {
            _ = try AdaptiveWorkoutService.removeLastSet(
                snapshot: snapshot,
                existingEntries: existing,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
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

    private func unskipComplex(_ complex: PlannedComplexSnapshot, plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.recordUnskipComplex(
                plan: plan,
                complexId: complex.id,
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

    private func unskipExercise(_ snapshot: PlannedExerciseSnapshot, plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.recordUnskipExercise(
                plan: plan,
                occurrenceId: snapshot.occurrenceId,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func isComplexSkipped(_ complex: PlannedComplexSnapshot, plan: GeneratedWorkoutPlan) -> Bool {
        AdaptiveWorkoutService.isComplexSkipped(
            planId: plan.id,
            complexId: complex.id,
            overrides: overrides
        )
    }

    private func isExerciseSkipped(_ snapshot: PlannedExerciseSnapshot, plan: GeneratedWorkoutPlan) -> Bool {
        AdaptiveWorkoutService.isExerciseSkipped(
            planId: plan.id,
            occurrenceId: snapshot.occurrenceId,
            overrides: overrides
        )
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
                    difficulty: proposedDifficulty(for: exercise),
                    modelContext: modelContext
                )
            } else {
                try AdaptiveWorkoutService.substitute(
                    plan: plan,
                    occurrenceId: context.occurrenceId,
                    fromExerciseId: context.currentExerciseId,
                    to: exercise,
                    difficulty: proposedDifficulty(for: exercise),
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

    private func addMovement(_ exercise: Exercise, context: AdaptiveAddMovementContext) {
        guard let plan = generatedPlans.first(where: { $0.id == context.planId }) else { return }
        do {
            let setCount = proposedSetCount(for: exercise)
            if let complexId = context.complexId {
                let previous = AdaptivePrefillService.latestRows(
                    exerciseId: exercise.id,
                    excludingPlanId: plan.id,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries,
                    overrides: overrides
                )
                var prefill: [Int: AdaptiveSetPrefill] = [:]
                if !previous.isEmpty {
                    for setIndex in 1...setCount {
                        let row = previous.first(where: { $0.setIndex == setIndex }) ?? previous.last!
                        prefill[setIndex] = AdaptiveSetPrefill(weight: row.weight, reps: row.reps)
                    }
                }
                try AdaptiveWorkoutService.addMovementToComplex(
                    plan: plan,
                    complexId: complexId,
                    exercise: exercise,
                    difficulty: proposedDifficulty(for: exercise),
                    prescribedSetCount: setCount,
                    adaptiveSessions: adaptiveSessions,
                    prefill: prefill,
                    modelContext: modelContext
                )
            } else {
                let previous = AdaptivePrefillService.latestRows(
                    exerciseId: exercise.id,
                    excludingPlanId: plan.id,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries,
                    overrides: overrides
                )
                var prefillByExerciseId: [UUID: [Int: AdaptiveSetPrefill]] = [:]
                if !previous.isEmpty {
                    for setIndex in 1...setCount {
                        let row = previous.first(where: { $0.setIndex == setIndex }) ?? previous.last!
                        prefillByExerciseId[exercise.id, default: [:]][setIndex] =
                            AdaptiveSetPrefill(weight: row.weight, reps: row.reps)
                    }
                }
                _ = try AdaptiveWorkoutService.appendComplex(
                    plan: plan,
                    definition: nil,
                    manualExercise: exercise,
                    manualPrescribedSetCount: setCount,
                    exercises: exercises,
                    adaptiveSessions: adaptiveSessions,
                    prefillByExerciseId: prefillByExerciseId,
                    modelContext: modelContext
                )
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createExerciseAndAddMovement(
        context: AdaptiveAddMovementContext,
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
            addMovement(exercise, context: context)
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeMovement(_ exercise: PlannedExerciseSnapshot, from plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.removeMovement(
                plan: plan,
                occurrenceId: exercise.occurrenceId,
                adaptiveSessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func presentAddComplex(for plan: GeneratedWorkoutPlan) {
        let presentMuscles = Set(plan.complexes.map(\.primaryMuscle))
        addComplexContext = AdaptiveAddComplexContext(
            planId: plan.id,
            availableMuscles: MuscleGroup.allCases.filter { !presentMuscles.contains($0) }
        )
    }

    private func appendConfiguredComplex(_ definition: AdaptiveExerciseComplex, planId: UUID) {
        guard let plan = generatedPlans.first(where: { $0.id == planId }) else { return }
        do {
            var prefillByExerciseId: [UUID: [Int: AdaptiveSetPrefill]] = [:]
            for component in definition.components {
                let rows = AdaptivePrefillService.latestRows(
                    exerciseId: component.exerciseId,
                    excludingPlanId: plan.id,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries,
                    overrides: overrides
                )
                guard !rows.isEmpty else { continue }
                for setIndex in 1...max(1, component.prescribedSetCount) {
                    let row = rows.first(where: { $0.setIndex == setIndex }) ?? rows.last!
                    prefillByExerciseId[component.exerciseId, default: [:]][setIndex] =
                        AdaptiveSetPrefill(weight: row.weight, reps: row.reps)
                }
            }
            _ = try AdaptiveWorkoutService.appendComplex(
                plan: plan,
                definition: definition,
                exercises: exercises,
                adaptiveSessions: adaptiveSessions,
                prefillByExerciseId: prefillByExerciseId,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveComplex(
        _ complex: PlannedComplexSnapshot,
        in plan: GeneratedWorkoutPlan,
        direction: AdaptiveMovementDirection
    ) {
        do {
            _ = try AdaptiveWorkoutService.moveComplex(
                plan: plan,
                complexId: complex.id,
                direction: direction,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func canMoveComplex(
        _ complex: PlannedComplexSnapshot,
        in plan: GeneratedWorkoutPlan,
        direction: AdaptiveMovementDirection
    ) -> Bool {
        let ordered = plan.complexes.sorted { $0.position < $1.position }
        guard let index = ordered.firstIndex(where: { $0.id == complex.id }) else { return false }
        switch direction {
        case .earlier: return index > 0
        case .later: return index < ordered.count - 1
        }
    }

    private func removeComplex(_ complex: PlannedComplexSnapshot, from plan: GeneratedWorkoutPlan) {
        do {
            try AdaptiveWorkoutService.removeComplex(
                plan: plan,
                complexId: complex.id,
                adaptiveSessions: adaptiveSessions,
                setEntries: adaptiveSetEntries,
                feedback: complexFeedback,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveMovement(
        _ exercise: PlannedExerciseSnapshot,
        in plan: GeneratedWorkoutPlan,
        direction: AdaptiveMovementDirection
    ) {
        do {
            try AdaptiveWorkoutService.movePlannedMovement(
                plan: plan,
                occurrenceId: exercise.occurrenceId,
                direction: direction,
                modelContext: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func canMoveMovement(
        _ exercise: PlannedExerciseSnapshot,
        in plan: GeneratedWorkoutPlan,
        direction: AdaptiveMovementDirection
    ) -> Bool {
        let complexes = plan.complexes.sorted { $0.position < $1.position }
        guard let complexIndex = complexes.firstIndex(where: {
            $0.exercises.contains { $0.occurrenceId == exercise.occurrenceId }
        }) else { return false }
        let components = complexes[complexIndex].exercises.sorted { $0.position < $1.position }
        guard let exerciseIndex = components.firstIndex(where: {
            $0.occurrenceId == exercise.occurrenceId
        }) else { return false }
        switch direction {
        case .earlier:
            return exerciseIndex > 0 || complexIndex > 0
        case .later:
            return exerciseIndex < components.count - 1 || complexIndex < complexes.count - 1
        }
    }

    private func proposedDifficulty(for exercise: Exercise) -> MovementDifficulty {
        AdaptiveExerciseRoleService.difficulty(for: exercise)
    }

    private func proposedSetCount(for exercise: Exercise) -> Int {
        let configured = activeProgram?.complexes
            .flatMap(\.components)
            .filter { $0.exerciseId == exercise.id }
            .map(\.prescribedSetCount)
            .max() ?? 2
        let cap = activeProgram?.muscleRules.first(where: { $0.muscle == exercise.primaryMuscle })?
            .maxSetsPerExercise ?? configured
        return max(1, min(configured, cap))
    }

    @MainActor
    private func seedUITestProfileIfRequested() async {
#if DEBUG
        guard AppRuntime.isAdaptiveWorkflowUITesting, adaptivePrograms.isEmpty else { return }
        do {
            let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
            guard let chest = catalog.first(where: { $0.primaryMuscle == .chest }) else { return }
            let fixtureExercises: [Exercise]
            if AppRuntime.isAdaptiveHistoryUITesting {
                let names = [
                    "Flat Dumbbell Press",
                    "Cable Row",
                    "Bayesian Curl",
                    "Cable Lateral Raise"
                ]
                fixtureExercises = names.compactMap { name in
                    catalog.first(where: { $0.name == name })
                }
                guard fixtureExercises.count == names.count else { return }
            } else {
                guard let back = catalog.first(where: { $0.primaryMuscle == .back }) else { return }
                fixtureExercises = [chest, back]
            }
            let enabledMuscles = Set(fixtureExercises.map(\.primaryMuscle))
            if AppRuntime.isAdaptiveHistoryUITesting {
                _ = try AdaptiveExerciseSelectionPreferenceService.ensureRequestedDefaults(
                    modelContext: modelContext
                )
                let preferences = try modelContext.fetch(
                    FetchDescriptor<AdaptiveExerciseSelectionPreference>()
                )
                preferences.first { $0.muscle == .chest }?.mode = .repeatLast
                try modelContext.save()
            }
            var draft = AdaptiveProgramDraft.blank
            draft.name = "UI Test Adaptive"
            draft.isReviewedForUse = true
            draft.defaultComplexCount = fixtureExercises.count
            draft.muscleRules = draft.muscleRules.map { rule in
                var copy = rule
                copy.isEnabled = enabledMuscles.contains(rule.muscle)
                copy.priorityRank = fixtureExercises.firstIndex(where: {
                    $0.primaryMuscle == rule.muscle
                }).map { $0 + 1 } ?? 0
                copy.rollingSetFloor = AppRuntime.isAdaptiveHistoryUITesting ? 1 : 0
                return copy
            }
            draft.complexes = fixtureExercises.map { exercise in
                AdaptiveExerciseComplexDraft(
                    id: UUID(),
                    definitionId: UUID(),
                    sourceVersion: 0,
                    name: "UI Test \(exercise.primaryMuscle.displayName)",
                    primaryMuscle: exercise.primaryMuscle,
                    qualifiesForPrimaryFloor: true,
                    isEnabled: true,
                    components: [
                        AdaptiveComplexComponentDraft(
                            id: UUID(),
                            exerciseId: exercise.id,
                            prescribedSetCount: 1,
                            primaryMuscle: exercise.primaryMuscle,
                            secondaryMuscle: nil,
                            difficulty: .easy
                        )
                    ]
                )
            }
            let program = try AdaptiveProgramService.saveVersion(
                draft: draft,
                replacing: nil,
                allPrograms: adaptivePrograms,
                exercises: catalog,
                modelContext: modelContext
            )
            if AppRuntime.isAdaptiveHistoryUITesting {
                guard let plannedChest = fixtureExercises.first(where: {
                    $0.primaryMuscle == .chest
                }) else { return }
                try seedUITestAdaptiveHistory(program: program, exercise: plannedChest)
            }
            readiness = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
                (
                    $0,
                    ReadinessSelection(
                        soreness: SorenessLevel.none,
                        pain: ConnectiveTissuePainLevel.none,
                        eagerness: .eager
                    )
                )
            })
        } catch {
            errorMessage = error.localizedDescription
        }
#endif
    }

#if DEBUG
    private func seedUITestAdaptiveHistory(program: AdaptiveProgram, exercise: Exercise) throws {
        guard let definition = program.complexes.first(where: { $0.primaryMuscle == .chest }) else { return }
        let calendar = Calendar.current
        for dayOffset in [-6, -3] {
            guard let workoutDate = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            let occurrenceId = UUID()
            let exerciseSnapshot = PlannedExerciseSnapshot(
                occurrenceId: occurrenceId,
                position: 0,
                exerciseId: exercise.id,
                exerciseName: exercise.name,
                primaryMuscle: .chest,
                difficulty: .easy,
                prescribedSetCount: 1
            )
            let complexSnapshot = PlannedComplexSnapshot(
                sourceDefinitionId: definition.definitionId,
                sourceVersion: definition.version,
                position: definition.position,
                name: definition.name,
                primaryMuscle: .chest,
                reasonCodes: ["ui_test_prior_workout"],
                exercises: [exerciseSnapshot]
            )
            let plan = GeneratedWorkoutPlan(
                localDateKey: AdaptiveWorkoutService.localDateKey(for: workoutDate),
                timeZoneIdentifier: TimeZone.current.identifier,
                createdAt: workoutDate,
                frozenAt: workoutDate,
                status: .completed,
                adaptiveProgramId: program.id,
                adaptiveProgramVersion: program.version,
                readinessCheckId: UUID(),
                plannerVersion: AdaptivePlanService.plannerVersion,
                reasonCodes: ["ui_test_prior_workout"],
                complexes: [complexSnapshot]
            )
            let session = AdaptiveWorkoutSession(
                generatedPlanId: plan.id,
                createdAt: workoutDate,
                finishedAt: workoutDate.addingTimeInterval(1_800),
                status: .completed,
                exportStatus: .success
            )
            plan.sessionId = session.id
            let setEntry = AdaptiveSetEntry(
                adaptiveSessionId: session.id,
                occurrenceId: occurrenceId,
                exerciseId: exercise.id,
                setIndex: 1,
                weight: 60,
                reps: 9,
                isLocked: true
            )
            let feedback = ComplexFeedback(
                generatedPlanId: plan.id,
                plannedComplexId: complexSnapshot.id,
                rating: .tooLittle,
                createdAt: workoutDate.addingTimeInterval(1_900)
            )
            modelContext.insert(plan)
            modelContext.insert(session)
            modelContext.insert(setEntry)
            modelContext.insert(feedback)
        }
        try modelContext.save()
    }
#endif
}

private struct ReadinessSelection {
    var soreness: SorenessLevel = .none
    var pain: ConnectiveTissuePainLevel = .none
    var eagerness: EagernessLevel = .eager
}

private struct AdaptiveSwapContext: Identifiable {
    let id = UUID()
    let planId: UUID
    let occurrenceId: UUID
    let currentExerciseId: UUID
    let primaryMuscle: MuscleGroup
}

private struct AdaptiveAddMovementContext: Identifiable {
    let id = UUID()
    let planId: UUID
    let complexId: UUID?
    let primaryMuscle: MuscleGroup
}

private struct AdaptiveAddComplexContext: Identifiable {
    let id = UUID()
    let planId: UUID
    let availableMuscles: [MuscleGroup]
}

private struct AdaptiveAddComplexSheet: View {
    @Environment(\.dismiss) private var dismiss

    let muscles: [MuscleGroup]
    let program: AdaptiveProgram?
    let onSelectConfigured: (AdaptiveExerciseComplex) -> Void
    let onBuildManually: (MuscleGroup) -> Void

    var body: some View {
        NavigationStack {
            List(muscles, id: \.self) { muscle in
                Section(muscle.displayName) {
                    let configured = program?.complexes.filter {
                        $0.isEnabled && $0.primaryMuscle == muscle && !$0.components.isEmpty
                    }.sorted { $0.position < $1.position } ?? []
                    ForEach(configured) { definition in
                        Button(definition.name) { onSelectConfigured(definition) }
                    }
                    Button {
                        onBuildManually(muscle)
                    } label: {
                        Label("Build Manually", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("adaptive.buildComplex.\(muscle.rawValue)")
                }
            }
            .navigationTitle("Add Complex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct AdaptiveExerciseSection: View {
    @Environment(\.modelContext) private var modelContext

    let title: String
    let usesAssistanceLoad: Bool
    let entries: [AdaptiveSetEntry]
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onAddSet: () -> Void
    let onRemoveSet: () -> Void
    let onSwap: () -> Void
    let onSkip: () -> Void
    let onRemove: () -> Void
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
                    .accessibilityIdentifier("adaptive.weight.\(title).\(entry.setIndex)")

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
                    .accessibilityIdentifier("adaptive.reps.\(title).\(entry.setIndex)")

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
                Menu {
                    Button(action: onMoveEarlier) {
                        Label("Move Earlier", systemImage: "arrow.up")
                    }
                    .disabled(!canMoveEarlier)
                    Button(action: onMoveLater) {
                        Label("Move Later", systemImage: "arrow.down")
                    }
                    .disabled(!canMoveLater)
                    Button(action: onSwap) {
                        Label("Substitute", systemImage: "arrow.left.arrow.right")
                    }
                    Button(action: onSkip) {
                        Label("Skip", systemImage: "forward.end")
                    }
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Edit \(title)")
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
