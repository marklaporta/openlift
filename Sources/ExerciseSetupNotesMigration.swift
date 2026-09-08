import Foundation
import SwiftData

/// One-time import of the four setup notes supplied on September 8, 2026.
/// Reviewed catalog IDs scope personal values to the intended existing store.
enum ExerciseSetupNotesMigration {
    static let markerKey = "exercise-setup-notes-2026-09-08-v1"

    struct Note {
        let exerciseID: UUID
        let exerciseName: String
        let text: String
    }

    static let reviewedNotes = [
        Note(exerciseID: UUID(uuidString: "55B44E05-2ADC-4680-AB4B-FA10592ECF49")!,
             exerciseName: "Stiff-Leg Deadlift", text: "Pin hole: 12 · visible number: 14"),
        Note(exerciseID: UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!,
             exerciseName: "Bayesian Curl", text: "Seated · VOLTRAs: one above lowest · visible number: 4"),
        Note(exerciseID: UUID(uuidString: "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3")!,
             exerciseName: "Cable Lateral Raise", text: "Rack: 10 visible"),
        Note(exerciseID: UUID(uuidString: "D83E0EAC-E567-4F70-9153-D8F6E049A5AA")!,
             exerciseName: "Bench-Supported Cable Wrist Curl (Supinated)", text: "Bench: 30° · VOLTRA: 4 visible")
    ]

    struct Result {
        enum Status: String { case applied, alreadyApplied, notApplicable }
        let status: Status
        let updatedCount: Int
        let backupURL: URL?
    }

    enum MigrationError: LocalizedError {
        case pendingChanges, targetMismatch, persistentStoreRequired, invalidBackup

        var errorDescription: String? {
            switch self {
            case .pendingChanges: return "Save pending changes before importing exercise setup notes."
            case .targetMismatch: return "The reviewed exercise identities do not match this catalog. No setup notes were imported."
            case .persistentStoreRequired: return "The workout store is unavailable for a fresh backup. No setup notes were imported."
            case .invalidBackup: return "The fresh workout backup could not be verified. No setup notes were imported."
            }
        }
    }

    /// Runs before workout UI opens, with a dedicated clean context. The notes and
    /// store-resident completion marker share one save, so later clears stay clear
    /// after relaunch or full-store restore. Existing nonblank notes always win.
    @MainActor
    static func runAtStartup(
        modelContext: ModelContext,
        backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Result {
        guard !modelContext.hasChanges else { throw MigrationError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == markerKey }) {
            return Result(status: .alreadyApplied, updatedCount: 0, backupURL: nil)
        }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let targets = reviewedNotes.compactMap { note in
            exercises.first { $0.id == note.exerciseID }.map { (exercise: $0, note: note) }
        }
        // Fresh installs and other testers must not inherit personal setup values.
        guard targets.count == reviewedNotes.count else {
            return Result(status: .notApplicable, updatedCount: 0, backupURL: nil)
        }
        guard targets.allSatisfy({ $0.exercise.name == $0.note.exerciseName }) else {
            throw MigrationError.targetMismatch
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else {
            throw MigrationError.persistentStoreRequired
        }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenLift/revision-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("before-exercise-setup-notes-\(UUID().uuidString).sqlite")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { throw MigrationError.invalidBackup }
        do {
            try snapshot(storeURL, backupURL)
            guard StoreBackupService.isValidSnapshot(at: backupURL) else { throw MigrationError.invalidBackup }
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
        do {
            let empty = targets.filter { $0.exercise.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for target in empty { target.exercise.notes = target.note.text }
            modelContext.insert(TrainingPreference(key: markerKey, modeRawValue: "applied"))
            try save(modelContext)
            return Result(status: .applied, updatedCount: empty.count, backupURL: backupURL)
        } catch {
            // The clean-context guard makes rollback safe; retain the verified
            // snapshot and leave the marker absent so a later launch can retry.
            modelContext.rollback()
            throw error
        }
    }
}
