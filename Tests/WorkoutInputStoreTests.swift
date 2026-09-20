import XCTest
import SwiftData
import SQLite3
@testable import OpenLift

@MainActor
final class WorkoutInputStoreTests: XCTestCase {
    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("InputCopy", schema: schema, url: url, cloudKitDatabase: .none)])
    }
    func testCopiedPhoneStoreReadOnlyFlushFailureRetryAndColdReopen() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedInputStore/default.store")
        guard FileManager.default.fileExists(atPath: supplied.path) else { throw XCTSkip("Stage verified phone store in OpenLiftCopiedInputStore") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputCopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: supplied, to: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let bookkeeping: Set<String> = ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING", "Z_PRIMARYKEY"]
        let before = try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }
        let store = try container(at: url)
        let context = ModelContext(store); context.autosaveEnabled = false
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let draft = try XCTUnwrap(sessions.first { $0.status == .draft })
        let allEntries = try context.fetch(FetchDescriptor<SetEntry>())
        let entries = allEntries.filter { $0.sessionId == draft.id }
        XCTAssertEqual(sessions.count, 75); XCTAssertEqual(allEntries.count, 819)
        let buffer = WorkoutTextBuffer()
        XCTAssertFalse(try WorkoutInputPersistence.commit(buffer, entries: entries, context: context))
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, before,
            "Opening and flushing untouched existing draft must preserve every application field")
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let row = try XCTUnwrap(entries.first { entry in
            !entry.isLocked && exercises.first { $0.id == entry.exerciseId }?.equipment.supportsResistanceProfile == false
        })
        let originalReps = row.reps
        buffer.set(String(originalReps + 1), for: .init(entryID: row.id, kind: .reps))
        enum Failure: Error { case save }
        XCTAssertThrowsError(try WorkoutInputPersistence.commit(buffer, entries: entries, context: context,
            save: { _ in throw Failure.save }))
        XCTAssertEqual(row.reps, originalReps)
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, before)
        XCTAssertTrue(try WorkoutInputPersistence.commit(buffer, entries: entries, context: context))
        let edited = try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }
        XCTAssertThrowsError(try WorkoutInputPersistence.toggleComplete(row, context: context,
            save: { _ in throw Failure.save }))
        XCTAssertFalse(row.isLocked); XCTAssertNil(row.lockedAt)
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, edited)
        try WorkoutInputPersistence.toggleComplete(row, context: context)
        let after = try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }
        for (table, rows) in before where table != "ZSETENTRY" { XCTAssertEqual(after[table], rows, table) }
        XCTAssertEqual(Set(before["ZSETENTRY"]!).subtracting(Set(after["ZSETENTRY"]!)).count, 1)
        XCTAssertEqual(Set(after["ZSETENTRY"]!).subtracting(Set(before["ZSETENTRY"]!)).count, 1)
        let reopened = try container(at: url)
        let cold = ModelContext(reopened)
        let coldRow = try XCTUnwrap(cold.fetch(FetchDescriptor<SetEntry>()).first { $0.id == row.id })
        XCTAssertEqual(coldRow.reps, originalReps + 1)
        XCTAssertTrue(coldRow.isLocked); XCTAssertNotNil(coldRow.lockedAt)
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, after)
        print("INPUT_REAL_STORE: 75 sessions/819 rows preserved on no-op and failure; edit/complete retries change only chosen draft row, history/profiles/rotations unchanged after cold reopen")
    }
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
            var columnsStatement: OpaquePointer?
            let pragma = "SELECT name FROM pragma_table_info('\(name)') WHERE name != 'Z_OPT' ORDER BY cid"
            guard sqlite3_prepare_v2(db, pragma, -1, &columnsStatement, nil) == SQLITE_OK else { throw NSError(domain: "Columns", code: 1) }
            var columns: [String] = []
            while sqlite3_step(columnsStatement) == SQLITE_ROW { columns.append("\"" + String(cString: sqlite3_column_text(columnsStatement, 0)) + "\"") }
            sqlite3_finalize(columnsStatement)
            result[name] = try rows("SELECT \(columns.joined(separator: ",")) FROM \"\(quoted)\"").map { $0.joined(separator: "|") }.sorted()
        }
        return result
    }
}
