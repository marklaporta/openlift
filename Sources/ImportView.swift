import SwiftUI
import SwiftData

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var exercises: [Exercise]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query private var sessions: [Session]

    @State private var importResult: ImportResult?
    @State private var importError: String?
    @State private var showingManualWorkout = false

    private var sortedExercises: [Exercise] {
        exercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Manual Workout") {
                    Text("Log an arbitrary off-schedule workout directly into history. This does not advance the active cycle.")
                    Button("Log Off-Schedule Workout") {
                        showingManualWorkout = true
                    }
                }

                Section("Off-Schedule Workout Files") {
                    Text("Drop workout JSON files into:")
                    Text("OpenLift/exports")
                        .font(.system(.callout, design: .monospaced))
                    Text("Then tap Import Workouts. These become completed history sessions and do not advance the active cycle.")

                    Button("Import Workouts") {
                        importWorkouts()
                    }

                    if let importResult {
                        LabeledContent("Imported", value: "\(importResult.imported)")
                        LabeledContent("Already Present", value: "\(importResult.skippedExisting)")
                        if importResult.skippedUnknownExercises > 0 {
                            LabeledContent("Unknown Exercises", value: "\(importResult.skippedUnknownExercises)")
                        }
                    }
                }

                Section("Off-Schedule JSON Shape") {
                    Text("""
                    {
                      "date": "2026-05-03T21:22:07Z",
                      "exercises": [
                        {
                          "exercise_name": "Incline Dumbbell Press",
                          "sets": [
                            { "weight": 75, "reps": 10 },
                            { "weight": 75, "reps": 9 },
                            { "weight": 75, "reps": 8 }
                          ]
                        }
                      ]
                    }
                    """)
                    .font(.system(.footnote, design: .monospaced))
                    Text("Optional fields: session_id, cycle_name, cycle_day_index, muscle, set_index. If session_id is omitted, OpenLift derives a stable one from the file name.")
                }

                Section("Published Folder") {
                    Text("Publish cycle JSON files to the OpenLift iCloud container:")
                    Text("OpenLift/cycles")
                        .font(.system(.callout, design: .monospaced))
                    Text("The app reads `.json` files from this folder.")
                }

                Section("Cycle JSON Shape") {
                    Text("""
                    {
                      "name": "Upper/Lower A",
                      "days": [
                        {
                          "label": "Day A",
                          "slots": [
                            {
                              "muscle": "chest",
                              "exerciseName": "Incline Dumbbell Press",
                              "defaultSetCount": 3
                            }
                          ]
                        }
                      ]
                    }
                    """)
                    .font(.system(.footnote, design: .monospaced))
                }

                Section("Notes") {
                    Text("Use either `exerciseName` or `exerciseId` per cycle slot.")
                    Text("`exerciseName` is recommended for readability.")
                    Text("Then open Cycle tab and tap Refresh, then Import or Import + Activate.")
                }
            }
            .navigationTitle("Import")
            .sheet(isPresented: $showingManualWorkout) {
                ManualWorkoutEntryView(exercises: sortedExercises) { input in
                    try saveManualWorkout(input)
                }
            }
            .alert("Import Error", isPresented: .constant(importError != nil), actions: {
                Button("OK") { importError = nil }
            }, message: {
                Text(importError ?? "Unknown error")
            })
        }
    }

    private func saveManualWorkout(_ input: ManualWorkoutInput) throws {
        guard let cycle = activeCycles.first else {
            throw ImportError.noActiveCycle
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
            }
        }

        try modelContext.save()

        do {
            try SessionExportService.export(
                session: session,
                cycleName: cycleName,
                exercises: exercises,
                setEntries: input.exercises.flatMap { exerciseInput in
                    exerciseInput.sets.enumerated().map { index, set in
                        SetEntry(
                            sessionId: session.id,
                            exerciseId: exerciseInput.exerciseId,
                            setIndex: index + 1,
                            weight: set.weight,
                            reps: set.reps,
                            isLocked: true
                        )
                    }
                },
                requireICloudMirror: true
            )
            session.exportStatus = .success
            try modelContext.save()
        } catch {
            session.exportStatus = .failed
            SessionExportService.scheduleBackgroundExportRetry()
            try? modelContext.save()
            throw error
        }
    }

    private func importWorkouts() {
        do {
            importResult = try importMissingWorkoutExports()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importMissingWorkoutExports() throws -> ImportResult {
        guard let cycle = activeCycles.first else {
            throw ImportError.noActiveCycle
        }

        let exports = BootstrapDataService.allExportSummaries()
        var existingSessionIds = Set(sessions.map { $0.id.uuidString.uppercased() })
        let exercisesByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name.lowercased(), $0) })
        var result = ImportResult()

        for export in exports {
            let exportSessionId = export.session_id.uppercased()
            guard !existingSessionIds.contains(exportSessionId) else {
                result.skippedExisting += 1
                continue
            }
            guard let sessionUUID = UUID(uuidString: export.session_id),
                  let finishedAt = SessionExportService.parseExportDate(export.date) else {
                continue
            }

            let imported = Session(
                id: sessionUUID,
                cycleInstanceId: cycle.id,
                cycleDayIndex: export.cycle_day_index,
                cycleNameSnapshot: export.cycle_name,
                dayLabelSnapshot: export.cycle_name == "Off-Schedule" ? "Off-Schedule" : "Day \(export.cycle_day_index + 1)",
                createdAt: finishedAt.addingTimeInterval(-60),
                finishedAt: finishedAt,
                status: .completed,
                exportStatus: .success
            )
            try imported.validate()
            modelContext.insert(imported)

            for exportExercise in export.exercises {
                guard let exercise = exercisesByName[exportExercise.exercise_name.lowercased()] else {
                    result.skippedUnknownExercises += 1
                    continue
                }
                for set in exportExercise.sets where set.reps > 0 {
                    let entry = SetEntry(
                        sessionId: imported.id,
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
            result.imported += 1
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        return result
    }
}

private struct ManualWorkoutEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let exercises: [Exercise]
    let onSave: (ManualWorkoutInput) throws -> Void

    @State private var name = "Off-Schedule"
    @State private var date = Date()
    @State private var exerciseDrafts: [ManualExerciseDraft]
    @State private var errorMessage: String?

    init(exercises: [Exercise], onSave: @escaping (ManualWorkoutInput) throws -> Void) {
        self.exercises = exercises
        self.onSave = onSave
        let firstExerciseId = exercises.first?.id ?? UUID()
        _exerciseDrafts = State(initialValue: [ManualExerciseDraft(exerciseId: firstExerciseId)])
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
                            exerciseDraft.sets.append(ManualSetDraft())
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
                        exerciseDrafts.append(ManualExerciseDraft(exerciseId: exercises.first?.id ?? UUID()))
                    }
                }
            }
            .navigationTitle("Manual Workout")
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
            let cleanedExercises = exerciseDrafts.compactMap { draft -> ManualExerciseInput? in
                let cleanedSets = draft.sets.filter { $0.weight >= 0 && $0.reps > 0 }
                guard !cleanedSets.isEmpty else { return nil }
                return ManualExerciseInput(exerciseId: draft.exerciseId, sets: cleanedSets.map { ManualSetInput(weight: $0.weight, reps: $0.reps) })
            }
            guard !cleanedExercises.isEmpty else {
                throw ImportError.noLoggedSets
            }
            try onSave(ManualWorkoutInput(name: name, date: date, exercises: cleanedExercises))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exerciseName(for id: UUID) -> String {
        exercises.first(where: { $0.id == id })?.name ?? "Exercise"
    }
}

private struct ManualWorkoutInput {
    let name: String
    let date: Date
    let exercises: [ManualExerciseInput]
}

private struct ManualExerciseInput {
    let exerciseId: UUID
    let sets: [ManualSetInput]
}

private struct ManualSetInput {
    let weight: Double
    let reps: Int
}

private struct ManualExerciseDraft: Identifiable {
    let id = UUID()
    var exerciseId: UUID
    var sets: [ManualSetDraft] = [ManualSetDraft(), ManualSetDraft(), ManualSetDraft()]
}

private struct ManualSetDraft: Identifiable {
    let id = UUID()
    var weight: Double = 0
    var reps: Int = 0
}

private struct ImportResult {
    var imported = 0
    var skippedExisting = 0
    var skippedUnknownExercises = 0
}

private enum ImportError: LocalizedError {
    case noActiveCycle
    case noLoggedSets

    var errorDescription: String? {
        switch self {
        case .noActiveCycle:
            return "Activate a cycle before importing workout exports."
        case .noLoggedSets:
            return "Enter at least one set with reps > 0."
        }
    }
}

#Preview {
    ImportView()
}
