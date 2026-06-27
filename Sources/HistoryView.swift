import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query private var setEntries: [SetEntry]
    @Query private var exercises: [Exercise]
    @State private var exportedSessions: [ExportedSessionSummary] = []
    @State private var showingManualWorkout = false
    @State private var manualWorkoutError: String?

    private var completedSessions: [Session] {
        let candidates = sessions.filter {
            $0.status == .completed || $0.finishedAt != nil || $0.exportStatus == .success
        }

        let grouped = Dictionary(grouping: candidates, by: dedupeKey(for:))
        let deduped = grouped.compactMap { _, group -> Session? in
            group.max { lhs, rhs in
                let lhsSetCount = lockedSetCount(for: lhs.id)
                let rhsSetCount = lockedSetCount(for: rhs.id)
                if lhsSetCount != rhsSetCount {
                    return lhsSetCount < rhsSetCount
                }
                return (lhs.finishedAt ?? lhs.createdAt) < (rhs.finishedAt ?? rhs.createdAt)
            }
        }

        return deduped.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    private var exportedBySessionId: [String: ExportedSessionSummary] {
        Dictionary(uniqueKeysWithValues: exportedSessions.map { ($0.id, $0) })
    }

    private var sortedExercises: [Exercise] {
        exercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if completedSessions.isEmpty {
                    if exportedSessions.isEmpty {
                        ContentUnavailableView(
                            "No Completed Sessions",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Finish a workout to see it in history.")
                        )
                    } else {
                        Section("Exported Workouts") {
                            ForEach(exportedSessions) { exported in
                                NavigationLink {
                                    ExportedSessionDetailView(session: exported)
                                } label: {
                                    ExportedSessionRowView(session: exported)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(completedSessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRowView(
                                session: session,
                                cycleName: cycleName(for: session),
                                dayLabel: dayLabel(for: session),
                                exerciseCount: exerciseCount(for: session)
                            )
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingManualWorkout = true
                    } label: {
                        Label("Log Workout", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManualWorkout) {
                HistoryManualWorkoutEntryView(exercises: sortedExercises) { input in
                    try saveManualWorkout(input)
                }
            }
            .alert("Cannot Save Workout", isPresented: .constant(manualWorkoutError != nil), actions: {
                Button("OK") { manualWorkoutError = nil }
            }, message: {
                Text(manualWorkoutError ?? "Unknown error")
            })
            .task {
                reloadExportedSessions()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    reloadExportedSessions()
                }
            }
        }
    }

    private func cycleName(for session: Session) -> String {
        if let snapshot = session.cycleNameSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        if let exported = exportedBySessionId[session.id.uuidString] {
            return exported.cycleName
        }
        return OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func dayLabel(for session: Session) -> String {
        if let snapshot = session.dayLabelSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        if let exported = exportedBySessionId[session.id.uuidString] {
            return exported.dayLabel
        }
        return OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func exerciseCount(for session: Session) -> Int {
        Set(setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked }.map(\.exerciseId)).count
    }

    private func reloadExportedSessions() {
        exportedSessions = ExportedSessionSummary.loadAll()
    }

    private func dedupeKey(for session: Session) -> String {
        let timestamp = Int((session.finishedAt ?? session.createdAt).timeIntervalSince1970)
        let cycle = (session.cycleNameSnapshot ?? "").lowercased()
        let day = (session.dayLabelSnapshot ?? "").lowercased()
        return "\(timestamp)|\(session.cycleDayIndex)|\(cycle)|\(day)"
    }

    private func lockedSetCount(for sessionId: UUID) -> Int {
        setEntries.filter { $0.sessionId == sessionId && $0.reps > 0 && $0.isLocked }.count
    }

    private func saveManualWorkout(_ input: HistoryManualWorkoutInput) throws {
        guard let cycle = activeCycles.first else {
            throw HistoryManualWorkoutError.noActiveCycle
        }

        let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cycleName = trimmedName.isEmpty ? "Off-Schedule" : trimmedName
        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: cycle.currentDayIndex,
            cycleNameSnapshot: cycleName,
            dayLabelSnapshot: "Off-Schedule",
            createdAt: input.date.addingTimeInterval(-60),
            finishedAt: input.date,
            status: .completed,
            exportStatus: .pending
        )
        try session.validate()
        modelContext.insert(session)

        var insertedEntries: [SetEntry] = []
        for exerciseInput in input.exercises {
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
        }

        do {
            try SessionExportService.export(
                session: session,
                cycleName: cycleName,
                exercises: exercises,
                setEntries: insertedEntries,
                requireICloudMirror: true
            )
            session.exportStatus = .success
            try modelContext.save()
            reloadExportedSessions()
        } catch {
            session.exportStatus = .failed
            try? modelContext.save()
            throw error
        }
    }
}

private struct HistoryManualWorkoutEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let exercises: [Exercise]
    let onSave: (HistoryManualWorkoutInput) throws -> Void

    @State private var name = "Off-Schedule"
    @State private var date = Date()
    @State private var exerciseDrafts: [HistoryManualExerciseDraft]
    @State private var errorMessage: String?

    init(exercises: [Exercise], onSave: @escaping (HistoryManualWorkoutInput) throws -> Void) {
        self.exercises = exercises
        self.onSave = onSave
        _exerciseDrafts = State(initialValue: [HistoryManualExerciseDraft(exerciseId: exercises.first?.id ?? UUID())])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    TextField("Name", text: $name)
                    DatePicker("Date", selection: $date)
                }

                ForEach($exerciseDrafts) { $exerciseDraft in
                    Section {
                        Picker("Exercise", selection: $exerciseDraft.exerciseId) {
                            ForEach(exercises) { exercise in
                                Text(exercise.name).tag(exercise.id)
                            }
                        }

                        ForEach($exerciseDraft.sets) { $set in
                            HStack {
                                Text("Set")
                                TextField("Weight", value: $set.weight, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("×")
                                TextField("Reps", value: $set.reps, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .onDelete { offsets in
                            exerciseDraft.sets.remove(atOffsets: offsets)
                        }

                        Button("Add Set") {
                            exerciseDraft.sets.append(HistoryManualSetDraft())
                        }
                    } header: {
                        Text(exerciseName(for: exerciseDraft.exerciseId))
                    }
                }
                .onDelete { offsets in
                    exerciseDrafts.remove(atOffsets: offsets)
                }

                Section {
                    Button("Add Exercise") {
                        exerciseDrafts.append(HistoryManualExerciseDraft(exerciseId: exercises.first?.id ?? UUID()))
                    }
                    .disabled(exercises.isEmpty)
                }
            }
            .navigationTitle("Log Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(exercises.isEmpty)
                }
            }
            .alert("Cannot Save Workout", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "Unknown error")
            })
        }
    }

    private func save() {
        do {
            let cleanedExercises = exerciseDrafts.compactMap { draft -> HistoryManualExerciseInput? in
                let cleanedSets = draft.sets.filter { $0.weight >= 0 && $0.reps > 0 }
                guard !cleanedSets.isEmpty else { return nil }
                return HistoryManualExerciseInput(
                    exerciseId: draft.exerciseId,
                    sets: cleanedSets.map { HistoryManualSetInput(weight: $0.weight, reps: $0.reps) }
                )
            }
            guard !cleanedExercises.isEmpty else {
                throw HistoryManualWorkoutError.noLoggedSets
            }
            try onSave(HistoryManualWorkoutInput(name: name, date: date, exercises: cleanedExercises))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exerciseName(for id: UUID) -> String {
        exercises.first(where: { $0.id == id })?.name ?? "Exercise"
    }
}

private struct HistoryManualWorkoutInput {
    let name: String
    let date: Date
    let exercises: [HistoryManualExerciseInput]
}

private struct HistoryManualExerciseInput {
    let exerciseId: UUID
    let sets: [HistoryManualSetInput]
}

private struct HistoryManualSetInput {
    let weight: Double
    let reps: Int
}

private struct HistoryManualExerciseDraft: Identifiable {
    let id = UUID()
    var exerciseId: UUID
    var sets: [HistoryManualSetDraft] = [HistoryManualSetDraft(), HistoryManualSetDraft(), HistoryManualSetDraft()]
}

private struct HistoryManualSetDraft: Identifiable {
    let id = UUID()
    var weight: Double = 0
    var reps: Int = 0
}

private enum HistoryManualWorkoutError: LocalizedError {
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

private struct SessionRowView: View {
    let session: Session
    let cycleName: String
    let dayLabel: String
    let exerciseCount: Int

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.finishedAt ?? session.createdAt, style: .date)
                    .font(.headline)
                Text(cycleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(exerciseCount) exercises")
                    .font(.caption)
                Text(session.exportStatus.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(session.exportStatus == .success ? .green.opacity(0.2) : .orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}

private struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var exercises: [Exercise]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query private var setEntries: [SetEntry]

    let session: Session
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Date") {
                    Text(session.finishedAt ?? session.createdAt, style: .date)
                }
                LabeledContent("Cycle") {
                    Text(cycleName)
                }
                LabeledContent("Day") {
                    Text(dayLabel)
                }
                LabeledContent("Export Status") {
                    Text(session.exportStatus.rawValue)
                }
            }

            ForEach(groupedExercises, id: \.exercise.id) { group in
                Section(group.exercise.name) {
                    ForEach(group.sets) { set in
                        HStack {
                            Text("Set \(set.setIndex)")
                            Spacer()
                            Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) x \(set.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if session.exportStatus == .failed {
                Section {
                    Button("Retry Export") {
                        retryExport()
                    }
                }
            }
        }
        .navigationTitle("Session Detail")
        .alert("Export Error", isPresented: .constant(exportError != nil), actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "Unknown error")
        })
    }

    private var cycleName: String {
        OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private var dayLabel: String {
        OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private var groupedExercises: [(exercise: Exercise, sets: [SetEntry])] {
        let sessionSets = setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked }
        let grouped = Dictionary(grouping: sessionSets, by: { $0.exerciseId })
        return grouped.compactMap { exerciseId, sets in
            guard let exercise = exercises.first(where: { $0.id == exerciseId }) else { return nil }
            return (exercise: exercise, sets: sets.sorted { $0.setIndex < $1.setIndex })
        }
        .sorted { $0.exercise.name < $1.exercise.name }
    }

    private func retryExport() {
        do {
            try SessionExportService.export(
                session: session,
                cycleName: cycleName,
                exercises: exercises,
                setEntries: setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked },
                requireICloudMirror: true
            )
            session.exportStatus = .success
            try modelContext.save()
        } catch {
            session.exportStatus = .failed
            SessionExportService.scheduleBackgroundExportRetry()
            exportError = error.localizedDescription
        }
    }
}

#Preview {
    HistoryView()
}

private struct ExportedSessionSummary: Identifiable {
    let id: String
    let date: Date
    let cycleName: String
    let cycleDayIndex: Int
    let exerciseCount: Int
    let exercises: [SessionExportService.ExportExercise]

    var dayLabel: String {
        "Day \(cycleDayIndex + 1)"
    }

    static func loadAll() -> [ExportedSessionSummary] {
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

        var results: [ExportedSessionSummary] = []

        for dir in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in urls where fileURL.pathExtension == "json" && fileURL.lastPathComponent.hasPrefix("workout-") {
                guard let data = try? Data(contentsOf: fileURL),
                      let payload = SessionExportService.decodeExportPayload(data: data, fileURL: fileURL),
                      let date = SessionExportService.parseExportDate(payload.date) else { continue }

                results.append(
                    ExportedSessionSummary(
                        id: payload.session_id,
                        date: date,
                        cycleName: payload.cycle_name,
                        cycleDayIndex: payload.cycle_day_index,
                        exerciseCount: payload.exercises.count,
                        exercises: payload.exercises
                    )
                )
            }
        }

        // Keep newest unique sessions if file mirrors exist in iCloud and local docs.
        let deduped = Dictionary(grouping: results, by: \.id).compactMap { _, grouped in
            grouped.max(by: { $0.date < $1.date })
        }

        return deduped.sorted { $0.date > $1.date }
    }
}

private struct ExportedSessionRowView: View {
    let session: ExportedSessionSummary

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date, style: .date)
                    .font(.headline)
                Text(session.cycleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(session.dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(session.exerciseCount) exercises")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExportedSessionDetailView: View {
    let session: ExportedSessionSummary

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Date") {
                    Text(session.date, style: .date)
                }
                LabeledContent("Cycle") {
                    Text(session.cycleName)
                }
                LabeledContent("Day") {
                    Text(session.dayLabel)
                }
            }

            ForEach(session.exercises, id: \.exercise_name) { exercise in
                Section(exercise.exercise_name) {
                    ForEach(exercise.sets, id: \.set_index) { set in
                        HStack {
                            Text("Set \(set.set_index)")
                            Spacer()
                            Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) x \(set.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Session Detail")
    }
}
