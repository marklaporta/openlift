import SwiftUI
import SwiftData

/// Catalog-level setup notes, independent of workout sessions and template slots.
enum ExerciseNotesService {
    static func save(_ notes: String, for exercise: Exercise, modelContext: ModelContext) throws {
        let previousNotes = exercise.notes
        exercise.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try modelContext.save()
        } catch {
            // Do not roll back unrelated workout edits in the shared context.
            exercise.notes = previousNotes
            throw error
        }
    }
}

struct ExerciseNotesControl: View {
    let exercise: Exercise
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                if exercise.notes.isEmpty {
                    Text("Add exercise note")
                        .foregroundStyle(.secondary)
                } else {
                    Text(exercise.notes)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(exercise.name) exercise note")
        .accessibilityValue(exercise.notes.isEmpty ? "No note" : exercise.notes)
        .accessibilityHint("Edit setup notes shared across all workouts")
        .accessibilityIdentifier("exercise.notes.\(exercise.name)")
        .sheet(isPresented: $isEditing) {
            ExerciseNotesEditor(exercise: exercise)
        }
    }
}

private struct ExerciseNotesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let exercise: Exercise
    @State private var draft: String
    @State private var errorMessage: String?

    init(exercise: Exercise) {
        self.exercise = exercise
        _draft = State(initialValue: exercise.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .accessibilityLabel("Exercise note")
                        .accessibilityIdentifier("exercise.notes.editor")
                    if !draft.isEmpty {
                        Button("Clear Note", role: .destructive) {
                            draft = ""
                        }
                        .accessibilityIdentifier("exercise.notes.clear")
                    }
                } header: {
                    Text(exercise.name)
                } footer: {
                    Text("Setup details like rack pin height or bench position. Shared across all workouts for this exercise.")
                }
            }
            .navigationTitle("Exercise Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("exercise.notes.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try ExerciseNotesService.save(draft, for: exercise, modelContext: modelContext)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .accessibilityIdentifier("exercise.notes.save")
                }
            }
            .interactiveDismissDisabled(draft != exercise.notes)
            .alert("Cannot Save Note", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }
}
