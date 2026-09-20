import SwiftUI
import UIKit
import SwiftData

/// Raw input is deliberately not Observable: keystrokes belong to UITextField,
/// not the workout's SwiftData queries or SwiftUI body. Flush reads these strings
/// synchronously, including the final character of an immediately completed set.
@MainActor
final class WorkoutTextBuffer {
    enum Kind: Hashable { case weight, reps }
    struct Key: Hashable { let entryID: UUID; let kind: Kind }
    struct Edit { let key: Key; var text: String; var order: Int }
    private(set) var edits: [Key: Edit] = [:]
    private var sequence = 0
    private var pendingCommit: Task<Void, Never>?

    func scheduleCommit(_ commit: @escaping @MainActor () -> Void) {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            pendingCommit = nil
            commit()
        }
    }
    func cancelCommit() { pendingCommit?.cancel(); pendingCommit = nil }

    func set(_ text: String, for key: Key) {
        sequence += 1
        edits[key] = Edit(key: key, text: text, order: sequence)
    }
    func text(for key: Key) -> String? { edits[key]?.text }
    func didSave() { edits.removeAll() }

    func applying(to entries: [(id: UUID, state: WorkoutEntryEditing.EntryState)]) throws -> [WorkoutEntryEditing.EntryState] {
        var states = entries.map(\.state)
        for edit in edits.values.sorted(by: { $0.order < $1.order }) {
            guard let entry = entries.first(where: { $0.id == edit.key.entryID }), !entry.state.isLocked else { continue }
            switch edit.key.kind {
            case .weight:
                WorkoutEntryEditing.applyWeightEdit(to: &states, setIndex: entry.state.setIndex,
                    newWeight: try Self.weight(edit.text))
            case .reps:
                WorkoutEntryEditing.applyRepsEdit(to: &states, setIndex: entry.state.setIndex,
                    newReps: try Self.reps(edit.text))
            }
        }
        return states
    }

    enum InputError: LocalizedError {
        case weight, reps, positiveRepsRequired
        var errorDescription: String? {
            switch self {
            case .weight: return "Enter a valid, nonnegative weight. Your entry has been kept for correction."
            case .reps: return "Enter a whole, nonnegative rep count. Your entry has been kept for correction."
            case .positiveRepsRequired: return "Enter the reps you performed before completing this set."
            }
        }
    }
    static func weight(_ raw: String) throws -> Double {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        let decimal = Locale.current.decimalSeparator ?? "."
        let normalized = text.replacingOccurrences(of: decimal, with: ".")
        guard normalized.allSatisfy({ $0.isNumber || $0 == "." }),
              let number = Double(normalized), number.isFinite, number >= 0,
              WeightFormatting.normalized(number).isFinite else { throw InputError.weight }
        return number
    }
    static func reps(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        guard text.allSatisfy(\.isNumber), let number = Int(text), number >= 0 else { throw InputError.reps }
        return number
    }
}

/// A supported UIKit text field, not introspection of SwiftUI's private views.
/// Selecting existing text on focus allows type-to-replace while leaving an
/// untouched prefilled weight intact. Partial decimal text is never reformatted
/// under the cursor. Done dismisses; Complete Set both commits and completes.
struct WorkoutNumericField: UIViewRepresentable {
    let key: WorkoutTextBuffer.Key
    let buffer: WorkoutTextBuffer
    let value: String
    let placeholder: String
    let identifier: String
    let isEnabled: Bool
    let onChange: () -> Void
    let onCommit: () -> Bool
    let onComplete: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = key.kind == .weight ? .decimalPad : .numberPad
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let complete = UIBarButtonItem(title: "Complete Set", style: .plain, target: context.coordinator, action: #selector(Coordinator.complete))
        complete.accessibilityIdentifier = "fixed.keyboard.complete"
        toolbar.items = [complete, UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.accessibilityIdentifier = identifier
        field.placeholder = placeholder
        field.isEnabled = isEnabled
        field.textColor = .label
        if !field.isFirstResponder { field.text = buffer.text(for: key) ?? value }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WorkoutNumericField
        weak var field: UITextField?
        init(_ parent: WorkoutNumericField) { self.parent = parent }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            // UIKit finishes placing its insertion point after this delegate call.
            DispatchQueue.main.async { [weak textField] in
                guard let textField, textField.isFirstResponder else { return }
                textField.selectAll(nil)
            }
        }
        @objc func changed(_ field: UITextField) {
            parent.buffer.set(field.text ?? "", for: parent.key)
            parent.onChange()
        }
        func textFieldDidEndEditing(_ textField: UITextField) { _ = parent.onCommit() }
        @objc func done() {
            if parent.onCommit() { field?.resignFirstResponder() }
        }
        @objc func complete() {
            if parent.onComplete() { field?.resignFirstResponder() }
        }
    }
}

@MainActor
enum WorkoutInputPersistence {
    /// Parsing precedes mutation. Failed saves retain raw input for an explicit
    /// retry; rollback never substitutes an older number for the user's edit.
    @discardableResult
    static func commit(_ buffer: WorkoutTextBuffer, entries: [SetEntry], context: ModelContext,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Bool {
        guard !buffer.edits.isEmpty else { return false }
        let states = try buffer.applying(to: entries.map { ($0.id, .init(entry: $0)) })
        let prior = entries.map { ($0, $0.numericWeight, $0.gripperModel, $0.reps) }
        do {
            var changed = false
            for (entry, state) in zip(entries, states) where !entry.isLocked {
                if entry.weight != state.weight { entry.weight = state.weight; changed = true }
                if entry.reps != state.reps { entry.reps = state.reps; changed = true }
            }
            if changed { try save(context) }
            buffer.didSave()
            return changed
        } catch {
            context.processPendingChanges()
            context.rollback()
            // Registered SwiftData objects can retain changed scalar values even
            // after rollback. Restore them so retry cannot mistake them for saved.
            for (entry, weight, model, reps) in prior {
                entry.numericWeight = weight; entry.gripperModel = model; entry.reps = reps
            }
            throw error
        }
    }

    static func toggleComplete(_ entry: SetEntry, profile: ExerciseResistanceProfile? = nil,
                               requiresProfile: Bool = false, context: ModelContext,
                               save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard entry.isLocked || entry.reps > 0 else { throw WorkoutTextBuffer.InputError.positiveRepsRequired }
        if !entry.isLocked && requiresProfile {
            guard let profile, ResistanceProfileService.value(profile) != nil else {
                throw ResistanceProfileError.profileRequiredBeforeLock
            }
            guard profile.workoutKind == .fixed, profile.sessionId == entry.sessionId,
                  profile.exerciseId == entry.exerciseId, profile.occurrenceId == nil else {
                throw ResistanceProfileError.invalidOccurrenceIdentity
            }
        }
        let oldLocked = entry.isLocked, oldLockedAt = entry.lockedAt
        let oldFrozenAt = profile?.frozenAt, oldUpdatedAt = profile?.updatedAt
        do {
            if !entry.isLocked, let profile, profile.frozenAt == nil {
                profile.frozenAt = .now; profile.updatedAt = .now
            }
            WorkoutEntryEditing.setLocked(!entry.isLocked, entry: entry)
            try save(context)
        } catch {
            context.processPendingChanges(); context.rollback()
            entry.isLocked = oldLocked; entry.lockedAt = oldLockedAt
            if let profile, let oldUpdatedAt {
                profile.frozenAt = oldFrozenAt; profile.updatedAt = oldUpdatedAt
            }
            throw error
        }
    }
}
