import SwiftData
import SwiftUI

struct AdaptiveProgramEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var programs: [AdaptiveProgram]

    let existingProgram: AdaptiveProgram?

    @State private var draft: AdaptiveProgramDraft
    @State private var errorMessage: String?
    @State private var presentingNewExercise = false
    @State private var exerciseCreationTarget: UUID?

    init(existingProgram: AdaptiveProgram?) {
        self.existingProgram = existingProgram
        _draft = State(initialValue: existingProgram.map(AdaptiveProgramDraft.init(existing:)) ?? .blank)
    }

    private var activeExercises: [Exercise] {
        exercises
            .filter(\.isActive)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var enabledRuleCount: Int {
        max(1, draft.muscleRules.filter(\.isEnabled).count)
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                muscleRulesSection
                complexesSection
            }
            .navigationTitle(existingProgram == nil ? "New Adaptive Profile" : "Edit Adaptive Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Version") { save() }
                        .accessibilityIdentifier("adaptive.saveProfile")
                }
            }
            .alert(
                "Adaptive Profile Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .sheet(isPresented: $presentingNewExercise) {
            NewExerciseSheet(
                existingExercises: exercises,
                purposeText: "The exercise is added to OpenLift’s shared catalog and assigned to this Adaptive component."
            ) { exercise in
                assignCreatedExercise(exercise)
            }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            TextField("Profile Name", text: $draft.name)
                .accessibilityIdentifier("adaptive.profileName")
            Stepper(
                "Planner movement target: \(draft.globalMaxMovements)",
                value: $draft.globalMaxMovements,
                in: 1...20
            )
            Text("This limits the automatic proposal. You can add or remove movements before accepting a workout.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("OpenLift will not pair a hard quad movement with a hard hamstring movement. Difficulty remains recorded as recovery context, not a daily point budget.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Reviewed for real use", isOn: $draft.isReviewedForUse)
            Text("Review means you have checked every rank, floor, cap, difficulty, exercise, and set count. Saving always creates a new immutable version.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if existingProgram == nil {
                Button("Load Demo Proposal") {
                    draft = AdaptiveProgramService.demoDraft(exercises: exercises)
                }
                .accessibilityIdentifier("adaptive.loadDemo")
                Text("The demo is only a starting proposal. It does not invent exercises for muscle groups missing from your catalog and cannot save until every enabled group has a qualifying complex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var muscleRulesSection: some View {
        Section("Muscle Rules") {
            Text("Supported: Chest, Back, Triceps, Biceps, Shoulders, Quads, Hamstrings, Forearms, Glutes, Calves, Abs, and Traps.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(draft.muscleRules.indices), id: \.self) { index in
                let rule = draft.muscleRules[index]
                DisclosureGroup {
                    Toggle(
                        "Enabled for planning",
                        isOn: Binding(
                            get: { draft.muscleRules[index].isEnabled },
                            set: { setRuleEnabled(at: index, enabled: $0) }
                        )
                    )

                    if rule.isEnabled {
                        Picker(
                            "Priority Rank",
                            selection: Binding(
                                get: { draft.muscleRules[index].priorityRank },
                                set: { setPriority(at: index, to: $0) }
                            )
                        ) {
                            ForEach(1...enabledRuleCount, id: \.self) { rank in
                                Text("\(rank)").tag(rank)
                            }
                        }

                        Stepper(
                            "Rolling floor: \(rule.rollingSetFloor) sets",
                            value: $draft.muscleRules[index].rollingSetFloor,
                            in: 0...100
                        )
                        Stepper(
                            "Floor window: \(rule.rollingWindowDays) days",
                            value: $draft.muscleRules[index].rollingWindowDays,
                            in: 1...60
                        )
                        Stepper(
                            "Maximum recovered gap: \(rule.maxRecoveredDayGap) days",
                            value: $draft.muscleRules[index].maxRecoveredDayGap,
                            in: 1...60
                        )
                        Stepper(
                            "Exercises per exposure: \(rule.maxExercisesPerExposure)",
                            value: $draft.muscleRules[index].maxExercisesPerExposure,
                            in: 1...10
                        )
                        Stepper(
                            "Sets per exercise: \(rule.maxSetsPerExercise)",
                            value: $draft.muscleRules[index].maxSetsPerExercise,
                            in: 1...10
                        )
                    } else {
                        Text("Candidate only · no priority or volume floor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack {
                        Text(rule.muscle.displayName)
                        Spacer()
                        Text(rule.isEnabled ? "#\(rule.priorityRank)" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var complexesSection: some View {
        Section("Ordered Exercise Complexes") {
            Text("A complex is atomic: all enabled components are selected together, in this order, and each component consumes one daily movement slot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(draft.complexes.indices), id: \.self) { complexIndex in
                complexEditor(at: complexIndex)
            }

            Button("Add Complex") { addComplex() }
                .disabled(activeExercises.isEmpty)
                .accessibilityIdentifier("adaptive.addComplex")
        }
    }

    @ViewBuilder
    private func complexEditor(at complexIndex: Int) -> some View {
        let complex = draft.complexes[complexIndex]
        DisclosureGroup {
            TextField("Complex Name", text: $draft.complexes[complexIndex].name)
            Toggle("Enabled", isOn: $draft.complexes[complexIndex].isEnabled)
            Picker("Scheduling Muscle", selection: $draft.complexes[complexIndex].primaryMuscle) {
                ForEach(enabledMuscles, id: \.self) { muscle in
                    Text(muscle.displayName).tag(muscle)
                }
            }
            Toggle(
                "Qualifies for primary-muscle floor",
                isOn: $draft.complexes[complexIndex].qualifiesForPrimaryFloor
            )

            ForEach(Array(complex.components.indices), id: \.self) { componentIndex in
                componentEditor(complexIndex: complexIndex, componentIndex: componentIndex)
            }

            Button("Add Component") { addComponent(to: complexIndex) }
                .disabled(activeExercises.isEmpty)

            HStack {
                Button {
                    moveComplex(at: complexIndex, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(complexIndex == 0)

                Button {
                    moveComplex(at: complexIndex, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(complexIndex == draft.complexes.count - 1)
            }

            Button("Delete Complex", role: .destructive) {
                draft.complexes.remove(at: complexIndex)
            }
        } label: {
            HStack {
                Text("\(complexIndex + 1). \(complex.name)")
                Spacer()
                Text("\(complex.components.count) movement(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func componentEditor(complexIndex: Int, componentIndex: Int) -> some View {
        let component = draft.complexes[complexIndex].components[componentIndex]
        VStack(alignment: .leading, spacing: 8) {
            Text("Component \(componentIndex + 1)")
                .font(.headline)

            Picker(
                "Exercise",
                selection: Binding(
                    get: { component.exerciseId },
                    set: { setExercise($0, complexIndex: complexIndex, componentIndex: componentIndex) }
                )
            ) {
                ForEach(activeExercises, id: \.id) { exercise in
                    Text(exercise.name).tag(exercise.id)
                }
            }

            Button("Create New Exercise…") {
                exerciseCreationTarget = component.id
                presentingNewExercise = true
            }

            Text("Primary: \(component.primaryMuscle.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Major Secondary", selection: $draft.complexes[complexIndex].components[componentIndex].secondaryMuscle) {
                Text("None").tag(Optional<MuscleGroup>.none)
                ForEach(MuscleGroup.allCases.filter { $0 != component.primaryMuscle }, id: \.self) { muscle in
                    Text(muscle.displayName).tag(Optional(muscle))
                }
            }

            Picker("Difficulty", selection: $draft.complexes[complexIndex].components[componentIndex].difficulty) {
                ForEach(MovementDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.displayName).tag(difficulty)
                }
            }

            Stepper(
                "Prescribed working sets: \(component.prescribedSetCount)",
                value: $draft.complexes[complexIndex].components[componentIndex].prescribedSetCount,
                in: 1...10
            )

            HStack {
                Button {
                    moveComponent(complexIndex: complexIndex, componentIndex: componentIndex, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(componentIndex == 0)

                Button {
                    moveComponent(complexIndex: complexIndex, componentIndex: componentIndex, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(componentIndex == draft.complexes[complexIndex].components.count - 1)

                Button(role: .destructive) {
                    draft.complexes[complexIndex].components.remove(at: componentIndex)
                } label: {
                    Label("Remove Component", systemImage: "trash")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var enabledMuscles: [MuscleGroup] {
        let enabled = draft.muscleRules.filter(\.isEnabled).map(\.muscle)
        return enabled.isEmpty ? [.chest] : enabled
    }

    private func setRuleEnabled(at index: Int, enabled: Bool) {
        draft.muscleRules[index].isEnabled = enabled
        normalizePriorities()
    }

    private func setPriority(at index: Int, to newRank: Int) {
        let oldRank = draft.muscleRules[index].priorityRank
        if let swapIndex = draft.muscleRules.firstIndex(where: {
            $0.isEnabled && $0.priorityRank == newRank
        }) {
            draft.muscleRules[swapIndex].priorityRank = oldRank
        }
        draft.muscleRules[index].priorityRank = newRank
    }

    private func normalizePriorities() {
        let enabledIndices = draft.muscleRules.indices
            .filter { draft.muscleRules[$0].isEnabled }
            .sorted {
                let left = draft.muscleRules[$0]
                let right = draft.muscleRules[$1]
                let leftRank = left.priorityRank == 0 ? Int.max : left.priorityRank
                let rightRank = right.priorityRank == 0 ? Int.max : right.priorityRank
                if leftRank != rightRank { return leftRank < rightRank }
                return (MuscleGroup.initialAdaptiveRankOrder.firstIndex(of: left.muscle) ?? Int.max)
                    < (MuscleGroup.initialAdaptiveRankOrder.firstIndex(of: right.muscle) ?? Int.max)
            }
        for (rank, index) in enabledIndices.enumerated() {
            draft.muscleRules[index].priorityRank = rank + 1
        }
        for index in draft.muscleRules.indices where !draft.muscleRules[index].isEnabled {
            draft.muscleRules[index].priorityRank = 0
            draft.muscleRules[index].rollingSetFloor = 0
        }
    }

    private func addComplex() {
        guard let exercise = activeExercises.first else { return }
        draft.complexes.append(
            AdaptiveExerciseComplexDraft(
                id: UUID(),
                definitionId: UUID(),
                sourceVersion: 0,
                name: "New \(exercise.primaryMuscle.displayName) Complex",
                primaryMuscle: exercise.primaryMuscle,
                qualifiesForPrimaryFloor: true,
                isEnabled: true,
                components: [makeComponent(exercise: exercise)]
            )
        )
    }

    private func addComponent(to complexIndex: Int) {
        let muscle = draft.complexes[complexIndex].primaryMuscle
        guard let exercise = activeExercises.first(where: { $0.primaryMuscle == muscle }) ?? activeExercises.first else {
            return
        }
        draft.complexes[complexIndex].components.append(makeComponent(exercise: exercise))
    }

    private func makeComponent(exercise: Exercise) -> AdaptiveComplexComponentDraft {
        AdaptiveComplexComponentDraft(
            id: UUID(),
            exerciseId: exercise.id,
            prescribedSetCount: 2,
            primaryMuscle: exercise.primaryMuscle,
            secondaryMuscle: nil,
            difficulty: exercise.type == .compound ? .moderate : .easy
        )
    }

    private func setExercise(_ exerciseId: UUID, complexIndex: Int, componentIndex: Int) {
        guard let exercise = exercises.first(where: { $0.id == exerciseId }) else { return }
        draft.complexes[complexIndex].components[componentIndex].exerciseId = exercise.id
        draft.complexes[complexIndex].components[componentIndex].primaryMuscle = exercise.primaryMuscle
        if draft.complexes[complexIndex].components[componentIndex].secondaryMuscle == exercise.primaryMuscle {
            draft.complexes[complexIndex].components[componentIndex].secondaryMuscle = nil
        }
    }

    private func assignCreatedExercise(_ exercise: Exercise) {
        guard let targetId = exerciseCreationTarget else { return }
        for complexIndex in draft.complexes.indices {
            if let componentIndex = draft.complexes[complexIndex].components.firstIndex(where: { $0.id == targetId }) {
                setExercise(exercise.id, complexIndex: complexIndex, componentIndex: componentIndex)
                break
            }
        }
        exerciseCreationTarget = nil
    }

    private func moveComplex(at index: Int, by delta: Int) {
        let destination = index + delta
        guard draft.complexes.indices.contains(destination) else { return }
        let value = draft.complexes.remove(at: index)
        draft.complexes.insert(value, at: destination)
    }

    private func moveComponent(complexIndex: Int, componentIndex: Int, by delta: Int) {
        let destination = componentIndex + delta
        guard draft.complexes[complexIndex].components.indices.contains(destination) else { return }
        let value = draft.complexes[complexIndex].components.remove(at: componentIndex)
        draft.complexes[complexIndex].components.insert(value, at: destination)
    }

    private func save() {
        do {
            _ = try AdaptiveProgramService.saveVersion(
                draft: draft,
                replacing: existingProgram,
                allPrograms: programs,
                exercises: exercises,
                modelContext: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
