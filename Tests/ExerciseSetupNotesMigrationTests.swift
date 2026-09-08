import CryptoKit
import SQLite3
import SwiftData
import XCTest
@testable import OpenLift

final class ExerciseSetupNotesMigrationTests: XCTestCase {
    private typealias Migration = ExerciseSetupNotesMigration

    private struct Fixture {
        let root: URL
        let store: URL
        let context: ModelContext
        var backups: URL { root.appendingPathComponent("revision-backups") }
    }

    private func open(_ store: URL) throws -> ModelContext {
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        let container = try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)])
        return ModelContext(container)
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SetupNotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("default.store")
        let context = try open(store)
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        for note in Migration.reviewedNotes {
            let exercise = try XCTUnwrap(exercises.first { $0.name == note.exerciseName })
            exercise.id = note.exerciseID
        }
        context.insert(Exercise(name: "SLDL", primaryMuscle: .hamstrings,
            type: .compound, equipment: .barbell, notes: "Unrelated custom setup"))
        try context.save()
        let program = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        let session = Session(cycleInstanceId: program.cycleId, cycleDayIndex: 0,
            finishedAt: Date(timeIntervalSince1970: 1788907390), status: .completed)
        let draft = Session(cycleInstanceId: program.cycleId, cycleDayIndex: 1, status: .draft)
        context.insert(session)
        context.insert(draft)
        context.insert(SetEntry(sessionId: session.id, exerciseId: Migration.reviewedNotes[0].exerciseID,
            setIndex: 1, weight: 130, reps: 12, isLocked: true))
        context.insert(SetEntry(sessionId: draft.id, exerciseId: Migration.reviewedNotes[0].exerciseID,
            setIndex: 1, weight: 135, reps: 10, isLocked: true))
        try context.save()
        return Fixture(root: root, store: store, context: context)
    }

    @MainActor
    func testImportsOnlyFourCatalogNotesWithFreshBackupAndDurableMarker() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try verifyImportAndPreservation(f)
    }

    @MainActor
    func testExistingNotesWinAndSubsequentEditOrClearIsNeverReseeded() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let targetID = Migration.reviewedNotes[0].exerciseID
        let exercise = try XCTUnwrap(f.context.fetch(FetchDescriptor<Exercise>()).first { $0.id == targetID })
        exercise.notes = "  My newer setup\nKeep this exactly  "
        try f.context.save()
        let first = try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups)
        XCTAssertEqual(first.updatedCount, 3)
        XCTAssertEqual(exercise.notes, "  My newer setup\nKeep this exactly  ")
        try ExerciseNotesService.save("Edited after import", for: exercise, modelContext: f.context)
        let reopened = try open(f.store)
        XCTAssertEqual(try Migration.runAtStartup(modelContext: reopened, snapshot: { _, _ in XCTFail("Must not reseed") }).status, .alreadyApplied)
        let persisted = try XCTUnwrap(reopened.fetch(FetchDescriptor<Exercise>()).first { $0.id == targetID })
        XCTAssertEqual(persisted.notes, "Edited after import")
        try ExerciseNotesService.save("", for: persisted, modelContext: reopened)
        let cleared = try open(f.store)
        XCTAssertEqual(try Migration.runAtStartup(modelContext: cleared, snapshot: { _, _ in XCTFail("Must not reseed") }).status, .alreadyApplied)
        XCTAssertEqual(try cleared.fetch(FetchDescriptor<Exercise>()).first { $0.id == targetID }?.notes, "")
    }

    @MainActor
    func testSnapshotAndSaveFailuresLeaveNotesAndMarkerUnchangedThenRetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try databaseRows(at: f.store)
        enum Injected: Error { case failure }
        XCTAssertThrowsError(try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups,
            snapshot: { _, _ in throw Injected.failure }))
        XCTAssertThrowsError(try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups,
            snapshot: { _, target in try Data("invalid SQLite".utf8).write(to: target) }))
        XCTAssertEqual(try databaseRows(at: f.store), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: f.backups, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertThrowsError(try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups,
            save: { _ in throw Injected.failure }))
        XCTAssertFalse(f.context.hasChanges)
        XCTAssertEqual(try databaseRows(at: f.store), before)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == Migration.markerKey })
        XCTAssertTrue(try f.context.fetch(FetchDescriptor<Exercise>()).filter {
            Migration.reviewedNotes.map(\.exerciseID).contains($0.id)
        }.allSatisfy { $0.notes.isEmpty })
        XCTAssertEqual(try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups).updatedCount, 4)
    }

    @MainActor
    func testUnmatchedIdentityOrNameAndPendingEditsNeverMutateStore() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let exercise = try XCTUnwrap(f.context.fetch(FetchDescriptor<Exercise>()).first {
            $0.id == Migration.reviewedNotes[0].exerciseID
        })
        let originalID = exercise.id
        exercise.id = UUID()
        try f.context.save()
        let before = try databaseRows(at: f.store)
        XCTAssertEqual(try Migration.runAtStartup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Other stores must not reach backup") }).status, .notApplicable)
        XCTAssertEqual(try databaseRows(at: f.store), before)
        exercise.id = originalID
        exercise.name = "User renamed exercise"
        try f.context.save()
        XCTAssertThrowsError(try Migration.runAtStartup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Identity mismatch must not reach backup") }))
        exercise.notes = "Unsaved input"
        XCTAssertThrowsError(try Migration.runAtStartup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Pending edits must not reach backup") }))
        XCTAssertTrue(f.context.hasChanges)
        XCTAssertEqual(exercise.notes, "Unsaved input")
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == Migration.markerKey })
    }

    /// Stage a verified copy only. Neither SwiftData nor SQLite opens the supplied
    /// fixture: the test makes a second disposable copy and checks source hashes.
    @MainActor
    func testCopiedRealStoreSetupNotesWhenOptedIn() throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let supplied = documents.appendingPathComponent("OpenLiftCopiedSetupNotesStore", isDirectory: true)
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Stage verified store files in Documents/OpenLiftCopiedSetupNotesStore.")
        }
        func hashes() throws -> [String: String] {
            let files = try FileManager.default.contentsOfDirectory(at: supplied, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map {
                ($0.lastPathComponent, SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined())
            })
        }
        let before = try hashes()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopiedSetupNotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: supplied, to: root)
        let store = root.appendingPathComponent("default.store")
        let f = Fixture(root: root, store: store, context: try open(store))
        try verifyImportAndPreservation(f)
        XCTAssertEqual(try hashes(), before)
        print("OPENLIFT_COPIED_SETUP_NOTES_VERIFIED updated=4 allOtherTablesUnchanged=true sourceHashesUnchanged=true")
    }

    @MainActor
    private func verifyImportAndPreservation(_ f: Fixture) throws {
        let before = try databaseRows(at: f.store)
        let exercises = try f.context.fetch(FetchDescriptor<Exercise>())
        let catalog = catalogIdentity(exercises)
        let notes = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.notes) })
        let preferences = Dictionary(uniqueKeysWithValues: try f.context.fetch(FetchDescriptor<TrainingPreference>()).map { ($0.key, $0.modeRawValue) })
        let result = try Migration.runAtStartup(modelContext: f.context, backupDirectory: f.backups)
        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.updatedCount, 4)
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: backup))
        XCTAssertTrue(try databaseRows(at: backup) == before, "Fresh backup must include the latest workout and every pre-import value")
        let backupHash = SHA256.hash(data: try Data(contentsOf: backup))
        let reopened = try open(f.store)
        let afterExercises = try reopened.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(catalogIdentity(afterExercises), catalog)
        for exercise in afterExercises {
            let intended = Migration.reviewedNotes.first { $0.exerciseID == exercise.id }
            XCTAssertEqual(exercise.notes, intended?.text ?? notes[exercise.id])
        }
        let afterPreferences = Dictionary(uniqueKeysWithValues: try reopened.fetch(FetchDescriptor<TrainingPreference>()).map { ($0.key, $0.modeRawValue) })
        XCTAssertEqual(afterPreferences[Migration.markerKey], "applied")
        XCTAssertEqual(afterPreferences.filter { $0.key != Migration.markerKey }, preferences)
        let after = try databaseRows(at: f.store)
        // Core Data appends internal persistent-history rows for the note save.
        // All other entity/relationship rows and store metadata stay identical.
        let changedTables: Set<String> = ["ZEXERCISE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY",
            "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for table in before.keys where !changedTables.contains(table) {
            XCTAssertTrue(after[table] == before[table], "Unexpected changes in \(table)")
        }
        XCTAssertEqual(try Migration.runAtStartup(modelContext: reopened,
            snapshot: { _, _ in XCTFail("Repeat launch must not create backup churn") }).status, .alreadyApplied)
        XCTAssertEqual(try databaseRows(at: f.store), after)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: backup)), backupHash)
    }

    private func catalogIdentity(_ exercises: [Exercise]) -> [String] {
        exercises.map { "\($0.id)|\($0.name)|\($0.primaryMuscle.rawValue)|\($0.type.rawValue)|\($0.equipment.rawValue)|\($0.isActive)" }.sorted()
    }

    /// Logical rows from every table, including relationship and metadata tables.
    /// Read-only SQLite observes committed WAL state without opening the source in SwiftData.
    private func databaseRows(at url: URL) throws -> [String: [String]] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { throw NSError(domain: "SetupNotesSQLite", code: 1) }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "SetupNotesSQLite", code: 2)
            }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    let type = sqlite3_column_type(statement, column)
                    guard let bytes = sqlite3_column_blob(statement, column) else { return "\(type):" }
                    return "\(type):" + Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))).base64EncodedString()
                })
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw NSError(domain: "SetupNotesSQLite", code: 3) }
            return result
        }
        var tableStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &tableStatement, nil) == SQLITE_OK else {
            throw NSError(domain: "SetupNotesSQLite", code: 4)
        }
        defer { sqlite3_finalize(tableStatement) }
        var result: [String: [String]] = [:]
        while sqlite3_step(tableStatement) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(tableStatement, 0))
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            result[name] = try rows("SELECT * FROM \"\(quoted)\"").map { $0.joined(separator: "|") }.sorted()
        }
        return result
    }
}
