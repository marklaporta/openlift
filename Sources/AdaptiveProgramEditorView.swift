import SwiftData
import SwiftUI

struct AdaptiveProgramEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var programs: [AdaptiveProgram]
    @Query private var workoutSizePreferences: [AdaptiveWorkoutSizePreference]
    @Query private var exposureConfigurations: [AdaptiveMuscleExposureConfiguration]
    @Query private var capacityPreferences: [AdaptiveWorkoutCapacityPreference]

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
            .task {
                guard let existingProgram else { return }
                if let stored = workoutSizePreferences.first(where: {
                    $0.adaptiveProgramId == existingProgram.id
                }) {
                    draft.defaultComplexCount = stored.defaultComplexCount
                }
                let configurations = AdaptiveExposureControllerService.configurations(
                    for: existingProgram,
                    allConfigurations: exposureConfigurations
                )
                for index in draft.muscleRules.indices {
                    let muscle = draft.muscleRules[index].muscle
                    if let configuration = configurations[muscle] {
                        draft.muscleRules[index].isEnabled =
                            configuration.isAutomaticPlanningEnabled
                        draft.muscleRules[index].normalSetCount =
                            configuration.normalSetCount
                        draft.muscleRules[index].cadenceKind =
                            configuration.cadenceKind
                        draft.muscleRules[index].minimumCalendarDays =
                            configuration.minimumCalendarDays
                        draft.muscleRules[index].cadencePattern =
                            configuration.cadencePattern
                        draft.muscleRules[index].exerciseSplitKind =
                            configuration.exerciseSplitKind
                        draft.muscleRules[index].firstSplitSetCount =
                            configuration.firstSplitSetCount
                        draft.muscleRules[index].secondSplitSetCount =
                            configuration.secondSplitSetCount
                    }
                }
                disableComplexesForDisabledRules()
                normalizePriorities()
                if let capacity = capacityPreferences.first(where: {
                    $0.adaptiveProgramId == existingProgram.id
                }) {
                    draft.defaultComplexCount = capacity.maxMuscleGroupCount
                    draft.maxExerciseCount = capacity.maxExerciseCount
                    draft.maxExercisesPerMuscle = capacity.maxExercisesPerMuscle
                    draft.maxWorkingSetCount = capacity.maxWorkingSetCount
                }
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
                "Maximum muscle groups: \(draft.defaultComplexCount)",
                value: $draft.defaultComplexCount,
                in: 1...12
            )
            Stepper(
                "Maximum exercises: \(draft.maxExerciseCount)",
                value: $draft.maxExerciseCount,
                in: 1...30
            )
            Stepper(
                "Exercises per muscle: \(draft.maxExercisesPerMuscle)",
                value: $draft.maxExercisesPerMuscle,
                in: 1...5
            )
            Stepper(
                "Maximum working sets: \(draft.maxWorkingSetCount)",
                value: $draft.maxWorkingSetCount,
                in: 1...15
            )
            Text("Automatic workouts never exceed 15 working sets. Chest and back exercises are capped at 3 sets each.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Reviewed for real use", isOn: $draft.isReviewedForUse)
            Text("Approve after checking the settings below. Saving creates a new version.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if existingProgram == nil {
                Button("Load Starter Proposal") {
                    draft = AdaptiveProgramService.demoDraft(exercises: exercises)
                }
                .accessibilityIdentifier("adaptive.loadDemo")
            }
        }
    }

    private var muscleRulesSection: some View {
        Section("Muscle Rules") {
            ForEach(Array(draft.muscleRules.indices), id: \.self) { index in
                let rule = draft.muscleRules[index]
                DisclosureGroup {
                    Toggle(
                        "Enabled for automatic planning",
                        isOn: Binding(
                            get: { draft.muscleRules[index].isEnabled },
                            set: { setRuleEnabled(at: index, enabled: $0) }
                        )
                    )
                    .disabled(
                        !AdaptiveExposureControllerService.automaticPriority.contains(rule.muscle)
                    )

                    if rule.isEnabled {
                        LabeledContent(
                            "Automatic priority",
                            value: "\(AdaptiveExposureControllerService.automaticPriority.firstIndex(of: rule.muscle).map { $0 + 1 } ?? 0)"
                        )
                        Stepper(
                            "Normal sets per exposure: \(rule.normalSetCount)",
                            value: Binding(
                                get: { draft.muscleRules[index].normalSetCount },
                                set: { setNormalDose(at: index, to: $0) }
                            ),
                            in: 1...normalDoseLimit(for: rule)
                        )
                        Picker(
                            "Recovery cadence",
                            selection: Binding(
                                get: { draft.muscleRules[index].cadenceKind },
                                set: { setCadence(at: index, to: $0) }
                            )
                        ) {
                            ForEach(AdaptiveCadenceKind.allCases, id: \.self) { cadence in
                                Text(cadence.displayName).tag(cadence)
                            }
                        }
                        if rule.cadenceKind == .fixedCalendarDays {
                            Stepper(
                                cadenceDescription(days: rule.minimumCalendarDays),
                                value: $draft.muscleRules[index].minimumCalendarDays,
                                in: 1...14
                            )
                        } else {
                            Text("Intervals: \(rule.cadencePattern.map(String.init).joined(separator: ", ")) calendar days. Skips do not advance the pattern.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        exerciseSplitEditor(at: index)
                    } else {
                        Text(
                            AdaptiveExposureControllerService.automaticPriority.contains(rule.muscle)
                                ? "Manual planning only"
                                : "Always manual only"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack {
                        Text(rule.muscle.displayName)
                        Spacer()
                        Text(rule.isEnabled ? "\(rule.normalSetCount) sets" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var complexesSection: some View {
        Section("Ordered Exercise Complexes") {
            Text("Exercises in a complex are scheduled together in this order.")
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
                "Counts as primary-muscle training exposure",
                isOn: $draft.complexes[complexIndex].qualifiesForPrimaryFloor
            )

            ForEach(Array(complex.components.indices), id: \.self) { componentIndex in
                componentEditor(complexIndex: complexIndex, componentIndex: componentIndex)
            }

            Button("Add Component") { addComponent(to: complexIndex) }
                .disabled(activeExercises.isEmpty)
            Text("Back may pair one vertical pull with one horizontal pull. Other muscles use at most one compound.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            if let exercise = exercises.first(where: { $0.id == component.exerciseId }) {
                LabeledContent(
                    "Category",
                    value: exercise.type == .compound ? "Compound · hard/core" : "Isolation · accessory"
                )
            }

            Stepper(
                "Prescribed working sets: \(component.prescribedSetCount)",
                value: $draft.complexes[complexIndex].components[componentIndex].prescribedSetCount,
                in: 1...4
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
        let muscle = draft.muscleRules[index].muscle
        draft.muscleRules[index].isEnabled =
            enabled && AdaptiveExposureControllerService.automaticPriority.contains(muscle)
        if !draft.muscleRules[index].isEnabled {
            for complexIndex in draft.complexes.indices
                where draft.complexes[complexIndex].primaryMuscle == muscle {
                draft.complexes[complexIndex].isEnabled = false
            }
        }
        normalizePriorities()
    }

    private func normalizePriorities() {
        let enabledIndices = draft.muscleRules.indices
            .filter { draft.muscleRules[$0].isEnabled }
            .sorted {
                let left = draft.muscleRules[$0].muscle
                let right = draft.muscleRules[$1].muscle
                return (AdaptiveExposureControllerService.automaticPriority.firstIndex(of: left) ?? Int.max)
                    < (AdaptiveExposureControllerService.automaticPriority.firstIndex(of: right) ?? Int.max)
            }
        for (rank, index) in enabledIndices.enumerated() {
            draft.muscleRules[index].priorityRank = rank + 1
        }
        for index in draft.muscleRules.indices where !draft.muscleRules[index].isEnabled {
            draft.muscleRules[index].priorityRank = 0
            draft.muscleRules[index].rollingSetFloor = 0
        }
    }

    @ViewBuilder
    private func exerciseSplitEditor(at index: Int) -> some View {
        let rule = draft.muscleRules[index]
        if rule.muscle == .chest || rule.muscle == .back {
            Picker(
                "Exercise split",
                selection: Binding(
                    get: { draft.muscleRules[index].exerciseSplitKind },
                    set: { setExerciseSplit(at: index, to: $0) }
                )
            ) {
                Text("Single exercise").tag(AdaptiveExerciseSplitKind.none)
                if rule.muscle == .chest {
                    Text("Compound + isolation").tag(
                        AdaptiveExerciseSplitKind.chestCompoundIsolation
                    )
                } else {
                    Text("Vertical + horizontal").tag(
                        AdaptiveExerciseSplitKind.backVerticalHorizontal
                    )
                }
            }
            if rule.exerciseSplitKind != .none {
                Stepper(
                    "\(splitFirstLabel(for: rule)): \(rule.firstSplitSetCount)",
                    value: Binding(
                        get: { draft.muscleRules[index].firstSplitSetCount },
                        set: {
                            let first = min(max(1, $0), 3)
                            draft.muscleRules[index].firstSplitSetCount = first
                            draft.muscleRules[index].secondSplitSetCount =
                                rule.normalSetCount - first
                        }
                    ),
                    in: splitFirstRange(for: rule)
                )
                LabeledContent(
                    splitSecondLabel(for: rule),
                    value: "\(rule.secondSplitSetCount)"
                )
            }
        }
    }

    private func setNormalDose(at index: Int, to value: Int) {
        let boundedValue = min(
            normalDoseLimit(for: draft.muscleRules[index]),
            draft.muscleRules[index].exerciseSplitKind == .none
                ? max(1, value)
                : max(2, value)
        )
        draft.muscleRules[index].normalSetCount = boundedValue
        if draft.muscleRules[index].exerciseSplitKind != .none {
            let first = min(max(1, boundedValue / 2), boundedValue - 1)
            draft.muscleRules[index].firstSplitSetCount = first
            draft.muscleRules[index].secondSplitSetCount = boundedValue - first
        }
    }

    private func setExerciseSplit(
        at index: Int,
        to split: AdaptiveExerciseSplitKind
    ) {
        draft.muscleRules[index].exerciseSplitKind = split
        let bounded = min(
            normalDoseLimit(for: draft.muscleRules[index]),
            split == .none
                ? draft.muscleRules[index].normalSetCount
                : max(2, draft.muscleRules[index].normalSetCount)
        )
        setNormalDose(at: index, to: bounded)
    }

    private func normalDoseLimit(for rule: AdaptiveMuscleRuleDraft) -> Int {
        if rule.exerciseSplitKind != .none { return 6 }
        if rule.muscle == .chest || rule.muscle == .back { return 3 }
        return min(15, rule.maxSetsPerExercise)
    }

    private func splitFirstRange(
        for rule: AdaptiveMuscleRuleDraft
    ) -> ClosedRange<Int> {
        let dose = min(6, max(2, rule.normalSetCount))
        return max(1, dose - 3)...min(3, dose - 1)
    }

    private func setCadence(at index: Int, to cadence: AdaptiveCadenceKind) {
        draft.muscleRules[index].cadenceKind = cadence
        if cadence == .lateralDelts2221
            && draft.muscleRules[index].cadencePattern.isEmpty {
            draft.muscleRules[index].cadencePattern = [2, 2, 2, 1]
        }
    }

    private func disableComplexesForDisabledRules() {
        let disabled = Set(
            draft.muscleRules.filter { !$0.isEnabled }.map(\.muscle)
        )
        for index in draft.complexes.indices
            where disabled.contains(draft.complexes[index].primaryMuscle) {
            draft.complexes[index].isEnabled = false
        }
    }

    private func cadenceDescription(days: Int) -> String {
        let restDays = max(0, days - 1)
        return "\(days) calendar days (\(restDays) full rest \(restDays == 1 ? "day" : "days"))"
    }

    private func splitFirstLabel(for rule: AdaptiveMuscleRuleDraft) -> String {
        rule.muscle == .chest ? "Compound sets" : "Vertical-pull sets"
    }

    private func splitSecondLabel(for rule: AdaptiveMuscleRuleDraft) -> String {
        rule.muscle == .chest ? "Isolation sets" : "Horizontal-pull sets"
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
            difficulty: AdaptiveExerciseRoleService.difficulty(for: exercise)
        )
    }

    private func setExercise(_ exerciseId: UUID, complexIndex: Int, componentIndex: Int) {
        guard let exercise = exercises.first(where: { $0.id == exerciseId }) else { return }
        draft.complexes[complexIndex].components[componentIndex].exerciseId = exercise.id
        draft.complexes[complexIndex].components[componentIndex].primaryMuscle = exercise.primaryMuscle
        draft.complexes[complexIndex].components[componentIndex].difficulty =
            AdaptiveExerciseRoleService.difficulty(for: exercise)
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
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
