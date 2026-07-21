import SwiftUI
import SwiftData

struct LogWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var exercises: [Exercise]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @Query private var setEntries: [SetEntry]

    @State private var name = "Off-Schedule"
    @State private var date = Date()
    @State private var exerciseDrafts: [LogExerciseDraft] = []
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var historyContext: ExerciseHistoryContext?
    @State private var newExerciseRequest: NewExerciseRequest?
    @FocusState private var focusedField: LogEntryField?

    private var sortedExercises: [Exercise] {
        exercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    TextField("Name", text: $name)
                    DatePicker("Date", selection: $date)
                    Text("Saves directly to History as a completed off-schedule workout. Does not advance the active cycle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($exerciseDrafts) { $exerciseDraft in
                    Section {
                        Picker(
                            "Exercise",
                            selection: Binding(
                                get: { exerciseDraft.exerciseId },
                                set: { newExerciseId in
                                    applyExerciseSelection(
                                        draftId: exerciseDraft.id,
                                        exerciseId: newExerciseId
                                    )
                                }
                            )
                        ) {
                            ForEach(sortedExercises) { exercise in
                                Text(exercise.name).tag(exercise.id)
                            }
                        }

                        Button("Create New Exercise…") {
                            newExerciseRequest = NewExerciseRequest(draftId: exerciseDraft.id)
                        }

                        ForEach($exerciseDraft.sets) { $set in
                            HStack {
                                Text("S\(setNumber(for: set.id, in: exerciseDraft.id))")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 28, alignment: .leading)

                                Text("W")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "Weight",
                                    value: Binding<Double?>(
                                        get: { WorkoutEntryEditing.displayWeight(set.weight) },
                                        set: { newWeight in
                                            applyWeightEdit(
                                                exerciseId: exerciseDraft.id,
                                                setId: set.id,
                                                newWeight: newWeight
                                            )
                                        }
                                    ),
                                    format: WeightFormatting.style
                                )
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 86)
                                    .focused($focusedField, equals: .weight(set.id))

                                Text("R")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "Reps",
                                    value: Binding<Int?>(
                                        get: { WorkoutEntryEditing.displayReps(set.reps) },
                                        set: { newReps in
                                            applyRepsEdit(
                                                exerciseId: exerciseDraft.id,
                                                setId: set.id,
                                                newReps: newReps
                                            )
                                        }
                                    ),
                                    format: .number
                                )
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 62)
                                    .focused($focusedField, equals: .reps(set.id))

                                Button {
                                    focusedField = nil
                                    removeSet(set.id, from: exerciseDraft.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove set \(setNumber(for: set.id, in: exerciseDraft.id))")
                            }
                        }
                        .onDelete { offsets in
                            exerciseDraft.sets.remove(atOffsets: offsets)
                        }

                        Button("Add Set") {
                            addSet(to: exerciseDraft.id)
                        }

                        Picker("Volume adequacy", selection: $exerciseDraft.feedback) {
                            Text("Not recorded").tag(Optional<ComplexFeedbackRating>.none)
                            ForEach(ComplexFeedbackRating.allCases, id: \.self) { rating in
                                Text(rating.displayName).tag(Optional(rating))
                            }
                        }
                        Text("Ad hoc feedback is stored with this exercise. It informs future dose conservatively but never makes this session comparable to an Adaptive complex.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        HStack(spacing: 8) {
                            Text(exerciseName(for: exerciseDraft.exerciseId))
                            Spacer()
                            Button {
                                let exerciseName = exerciseName(for: exerciseDraft.exerciseId)
                                historyContext = ExerciseHistoryContext(
                                    exerciseId: exerciseDraft.exerciseId,
                                    exerciseName: exerciseName
                                )
                            } label: {
                                Image(systemName: "calendar")
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Show \(exerciseName(for: exerciseDraft.exerciseId)) history")
                        }
                    }
                }
                .onDelete { offsets in
                    exerciseDrafts.remove(atOffsets: offsets)
                }

                Section {
                    Button("Add Existing Exercise") {
                        addExercise()
                    }
                    .disabled(sortedExercises.isEmpty)

                    Button("Create New Exercise") {
                        newExerciseRequest = NewExerciseRequest(draftId: nil)
                    }

                    Button("Save to History") {
                        saveWorkout()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(exerciseDrafts.isEmpty)
                }

                if let savedMessage {
                    Section {
                        Text(savedMessage)
                            .foregroundStyle(.green)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Log Workout")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .onAppear {
                if exerciseDrafts.isEmpty {
                    addExercise()
                }
            }
            .alert("Cannot Save Workout", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "Unknown error")
            })
        }
        .sheet(item: $historyContext) { context in
            ExerciseHistorySheet(
                exerciseName: context.exerciseName,
                efforts: recentEfforts(exerciseId: context.exerciseId, exerciseName: context.exerciseName)
            )
        }
        .sheet(item: $newExerciseRequest) { request in
            NewExerciseSheet(existingExercises: exercises) { exercise in
                applyCreatedExercise(exercise, to: request.draftId)
            }
        }
    }

    private func addExercise() {
        guard let exerciseId = sortedExercises.first?.id else { return }
        exerciseDrafts.append(
            LogExerciseDraft(
                exerciseId: exerciseId,
                sets: prefilledSets(for: exerciseId)
            )
        )
    }

    private func applyCreatedExercise(_ exercise: Exercise, to draftId: UUID?) {
        let blankSets = [LogSetDraft(), LogSetDraft(), LogSetDraft()]
        if let draftId,
           let index = exerciseDrafts.firstIndex(where: { $0.id == draftId }) {
            exerciseDrafts[index].exerciseId = exercise.id
            exerciseDrafts[index].sets = blankSets
        } else {
            exerciseDrafts.append(LogExerciseDraft(exerciseId: exercise.id, sets: blankSets))
        }
        savedMessage = "Created \(exercise.name)."
    }

    private func addSet(to exerciseId: UUID) {
        guard let exerciseIndex = exerciseDrafts.firstIndex(where: { $0.id == exerciseId }) else { return }
        let exerciseId = exerciseDrafts[exerciseIndex].exerciseId
        let newSetIndex = exerciseDrafts[exerciseIndex].sets.count + 1
        let prefill = prefilledSet(for: exerciseId, setIndex: newSetIndex)
        exerciseDrafts[exerciseIndex].sets.append(prefill)
    }

    private func removeSet(_ setId: UUID, from exerciseId: UUID) {
        guard let exerciseIndex = exerciseDrafts.firstIndex(where: { $0.id == exerciseId }) else { return }
        exerciseDrafts[exerciseIndex].sets.removeAll { $0.id == setId }
    }

    private func setNumber(for setId: UUID, in exerciseId: UUID) -> Int {
        guard let exercise = exerciseDrafts.first(where: { $0.id == exerciseId }),
              let index = exercise.sets.firstIndex(where: { $0.id == setId }) else {
            return 1
        }
        return index + 1
    }

    private func applyWeightEdit(exerciseId: UUID, setId: UUID, newWeight: Double?) {
        guard let exerciseIndex = exerciseDrafts.firstIndex(where: { $0.id == exerciseId }),
              let setIndex = exerciseDrafts[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            return
        }

        var states = exerciseDrafts[exerciseIndex].sets.enumerated().map { index, set in
            WorkoutEntryEditing.EntryState(
                setIndex: index + 1,
                weight: set.weight,
                reps: set.reps,
                isLocked: false
            )
        }
        WorkoutEntryEditing.applyWeightEdit(to: &states, setIndex: setIndex + 1, newWeight: newWeight)

        for index in exerciseDrafts[exerciseIndex].sets.indices {
            exerciseDrafts[exerciseIndex].sets[index].weight = states[index].weight
            exerciseDrafts[exerciseIndex].sets[index].reps = states[index].reps
        }
    }

    private func applyRepsEdit(exerciseId: UUID, setId: UUID, newReps: Int?) {
        guard let exerciseIndex = exerciseDrafts.firstIndex(where: { $0.id == exerciseId }),
              let setIndex = exerciseDrafts[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            return
        }
        var states = exerciseDrafts[exerciseIndex].sets.enumerated().map { index, set in
            WorkoutEntryEditing.EntryState(
                setIndex: index + 1,
                weight: set.weight,
                reps: set.reps,
                isLocked: false
            )
        }
        WorkoutEntryEditing.applyRepsEdit(to: &states, setIndex: setIndex + 1, newReps: newReps)

        for index in exerciseDrafts[exerciseIndex].sets.indices {
            exerciseDrafts[exerciseIndex].sets[index].weight = states[index].weight
            exerciseDrafts[exerciseIndex].sets[index].reps = states[index].reps
        }
    }

    private func applyExerciseSelection(draftId: UUID, exerciseId: UUID) {
        guard let index = exerciseDrafts.firstIndex(where: { $0.id == draftId }) else { return }
        exerciseDrafts[index].exerciseId = exerciseId
        exerciseDrafts[index].sets = prefilledSets(for: exerciseId)
    }

    private func saveWorkout() {
        do {
            guard let cycle = activeCycles.first else {
                throw LogWorkoutError.noActiveCycle
            }

            let cleanedExercises = exerciseDrafts.compactMap { draft -> LogExerciseInput? in
                let cleanedSets = draft.sets.filter { $0.weight >= 0 && $0.reps > 0 }
                guard !cleanedSets.isEmpty else { return nil }
                return LogExerciseInput(
                    exerciseId: draft.exerciseId,
                    feedback: draft.feedback,
                    sets: cleanedSets.map { LogSetInput(weight: $0.weight, reps: $0.reps) }
                )
            }
            guard !cleanedExercises.isEmpty else {
                throw LogWorkoutError.noLoggedSets
            }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cycleName = trimmedName.isEmpty ? "Off-Schedule" : trimmedName
            let session = Session(
                cycleInstanceId: cycle.id,
                cycleDayIndex: cycle.currentDayIndex,
                cycleNameSnapshot: cycleName,
                dayLabelSnapshot: "Off-Schedule",
                createdAt: date.addingTimeInterval(-60),
                finishedAt: date,
                status: .completed,
                exportStatus: .pending
            )
            try session.validate()
            modelContext.insert(session)

            var insertedEntries: [SetEntry] = []
            var insertedFeedback: [AdHocExerciseFeedback] = []
            for exerciseInput in cleanedExercises {
                for (index, set) in exerciseInput.sets.enumerated() {
                    let entry = SetEntry(
                        sessionId: session.id,
                        exerciseId: exerciseInput.exerciseId,
                        setIndex: index + 1,
                        weight: set.weight,
                        reps: set.reps,
                        isLocked: true
                    )
                    try entry.validate()
                    modelContext.insert(entry)
                    insertedEntries.append(entry)
                }
                if let rating = exerciseInput.feedback {
                    let feedback = AdHocExerciseFeedback(
                        sessionId: session.id,
                        exerciseId: exerciseInput.exerciseId,
                        rating: rating,
                        createdAt: date
                    )
                    modelContext.insert(feedback)
                    insertedFeedback.append(feedback)
                }
            }

            do {
                try SessionExportService.export(
                    session: session,
                    cycleName: cycleName,
                    exercises: exercises,
                    setEntries: insertedEntries,
                    requireICloudMirror: true,
                    adHocFeedback: insertedFeedback
                )
                session.exportStatus = .success
            } catch {
                session.exportStatus = .failed
                SessionExportService.scheduleBackgroundExportRetry()
                errorMessage = error.localizedDescription
            }

            try modelContext.save()
            savedMessage = "Saved to History."
            exerciseDrafts = []
            addExercise()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exerciseName(for id: UUID) -> String {
        sortedExercises.first(where: { $0.id == id })?.name ?? "Exercise"
    }

    private func prefilledSets(for exerciseId: UUID) -> [LogSetDraft] {
        let exerciseName = exerciseName(for: exerciseId)
        if let latest = recentEfforts(exerciseId: exerciseId, exerciseName: exerciseName).first {
            return latest.sets
                .sorted { $0.setIndex < $1.setIndex }
                .map { LogSetDraft(weight: $0.weight, reps: $0.reps) }
        }
        return [LogSetDraft(), LogSetDraft(), LogSetDraft()]
    }

    private func prefilledSet(for exerciseId: UUID, setIndex: Int) -> LogSetDraft {
        let exerciseName = exerciseName(for: exerciseId)
        guard let latest = recentEfforts(exerciseId: exerciseId, exerciseName: exerciseName).first else {
            let previousWeight = exerciseDrafts
                .first(where: { $0.exerciseId == exerciseId })?
                .sets
                .last?
                .weight ?? 0
            return LogSetDraft(weight: previousWeight)
        }

        let sortedSets = latest.sets.sorted { $0.setIndex < $1.setIndex }
        if let matching = sortedSets.first(where: { $0.setIndex == setIndex }) {
            return LogSetDraft(weight: matching.weight, reps: matching.reps)
        }
        if let fallback = sortedSets.last {
            return LogSetDraft(weight: fallback.weight, reps: fallback.reps)
        }
        return LogSetDraft()
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

private enum LogEntryField: Hashable {
    case weight(UUID), reps(UUID)
}

private struct NewExerciseRequest: Identifiable {
    let id = UUID()
    let draftId: UUID?
}

struct NewExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let existingExercises: [Exercise]
    let onCreated: (Exercise) -> Void
    let purposeText: String

    @State private var name = ""
    @State private var primaryMuscle: MuscleGroup = .chest
    @State private var type: ExerciseType = .compound
    @State private var equipment: EquipmentType = .machine
    @State private var errorMessage: String?

    init(
        existingExercises: [Exercise],
        purposeText: String = "The exercise is added to OpenLift’s shared catalog and selected for this workout.",
        onCreated: @escaping (Exercise) -> Void
    ) {
        self.existingExercises = existingExercises
        self.purposeText = purposeText
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("newExercise.name")

                    Picker("Primary Muscle", selection: $primaryMuscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }

                    Picker("Type", selection: $type) {
                        ForEach(ExerciseType.allCases, id: \.self) { exerciseType in
                            Text(exerciseType.rawValue.capitalized).tag(exerciseType)
                        }
                    }

                    Picker("Equipment", selection: $equipment) {
                        ForEach(EquipmentType.allCases, id: \.self) { equipmentType in
                            Text(equipmentType.rawValue.capitalized).tag(equipmentType)
                        }
                    }
                }

                Section {
                    Text(purposeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createExercise() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("newExercise.create")
                }
            }
            .alert(
                "Cannot Create Exercise",
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
    }

    private func createExercise() {
        do {
            let exercise = try ExerciseCatalogService.makeExercise(
                name: name,
                primaryMuscle: primaryMuscle,
                type: type,
                equipment: equipment,
                existingExercises: existingExercises
            )
            modelContext.insert(exercise)
            do {
                try modelContext.save()
            } catch {
                modelContext.delete(exercise)
                throw error
            }
            onCreated(exercise)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LogExerciseInput {
    let exerciseId: UUID
    let feedback: ComplexFeedbackRating?
    let sets: [LogSetInput]
}

private struct LogSetInput {
    let weight: Double
    let reps: Int
}

private struct LogExerciseDraft: Identifiable {
    let id = UUID()
    var exerciseId: UUID
    var feedback: ComplexFeedbackRating? = nil
    var sets: [LogSetDraft] = [LogSetDraft(), LogSetDraft(), LogSetDraft()]
}

private struct LogSetDraft: Identifiable {
    let id = UUID()
    var weight: Double = 0
    var reps: Int = 0
}

private enum LogWorkoutError: LocalizedError {
    case noActiveCycle
    case noLoggedSets

    var errorDescription: String? {
        switch self {
        case .noActiveCycle:
            return "Activate a cycle before logging an off-schedule workout."
        case .noLoggedSets:
            return "Enter at least one set with reps > 0."
        }
    }
}

#Preview {
    LogWorkoutView()
}
