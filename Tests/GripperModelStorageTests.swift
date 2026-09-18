import XCTest
import SwiftData
import SQLite3
import CryptoKit
@testable import OpenLift

final class GripperModelStorageTests: XCTestCase {
    private func open(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    }

    @MainActor
    func testNewSavesUseSemanticModelsAndColdReopenPreservesPrefill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("default.store")
        let store = try open(url), context = ModelContext(store)
        let id = UUID(), session = UUID()
        context.insert(Exercise(id: id, name: "CoC Gripper", primaryMuscle: .forearms, type: .isolation, equipment: .machine))
        for (index, value) in [1.0, 2, 3, 1.01].enumerated() {
            let row = SetEntry(sessionId: session, exerciseId: id, setIndex: index + 1, weight: value,
                reps: 10 + index, isLocked: true, loadExerciseName: "CoC Gripper")
            context.insert(row)
        }
        let adaptive = AdaptiveSetEntry(adaptiveSessionId: UUID(), occurrenceId: UUID(), exerciseId: GripperLoadPresentation.exerciseId,
            setIndex: 1, weight: 3, reps: 6, isLocked: true)
        context.insert(adaptive)
        try context.save()
        let reopened = ModelContext(try open(url))
        let rows = try reopened.fetch(FetchDescriptor<SetEntry>()).sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(rows.map(\.gripperModel), ["G", "T", "1", nil])
        XCTAssertEqual(rows.map(\.numericWeight), [0, 0, 0, 1.01])
        XCTAssertEqual(rows.map(\.weight), [1, 2, 3, 1.01]) // transient prefill adapter, never stored
        XCTAssertEqual(rows.map(\.reps), [10, 11, 12, 13])
        rows[0].weight = 3; try reopened.save()
        XCTAssertEqual(rows[0].gripperModel, "1")
        XCTAssertEqual(rows[0].numericWeight, 0)
        // Changing an editable row to an ordinary movement must not retain model semantics.
        let ordinary = Exercise(name: "DB Curl", primaryMuscle: .biceps, type: .isolation, equipment: .dumbbell)
        reopened.insert(ordinary)
        rows[0].exerciseId = ordinary.id; rows[0].weight = 3
        XCTAssertNil(rows[0].gripperModel); XCTAssertEqual(rows[0].numericWeight, 3)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<AdaptiveSetEntry>()).first?.gripperModel, "1")
    }

    @MainActor
    func testCopiedPhoneStoreMigrationBackupGuardsPreservationAndIdempotency() throws {
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftCopiedGripperStore/default.store")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Stage verified phone store in OpenLiftCopiedGripperStore") }
        let hash = SHA256.hash(data: try Data(contentsOf: source))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: source, to: url)
        let store = try open(url), context = ModelContext(store)
        let rows = try context.fetch(FetchDescriptor<SetEntry>())
        let adaptive = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(rows.count + adaptive.count, 845)
        let target = rows.filter { $0.exerciseId == GripperLoadPresentation.exerciseId }
        XCTAssertEqual(target.count, 20)
        XCTAssertTrue(target.allSatisfy { $0.gripperModel == nil }) // schema migration is not history activation
        let before = try databaseRows(at: url)
        let evidence = rows.map { "\($0.id)|\($0.sessionId)|\($0.exerciseId)|\($0.setIndex)|\($0.weight)|\($0.reps)|\($0.isLocked)|\(String(describing: $0.lockedAt))" }.sorted()
        target[0].reps += 1
        XCTAssertThrowsError(try GripperModelStorage.migrate(modelContext: context))
        context.rollback()
        let draft = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        context.insert(draft); try context.save()
        XCTAssertThrowsError(try GripperModelStorage.migrate(modelContext: context))
        context.delete(draft); try context.save()
        XCTAssertThrowsError(try GripperModelStorage.migrate(modelContext: context, backupDirectory: root,
            snapshot: { _, _ in throw NSError(domain: "backup", code: 1) }))
        XCTAssertTrue(target.allSatisfy { $0.gripperModel == nil })
        XCTAssertThrowsError(try GripperModelStorage.migrate(modelContext: context, backupDirectory: root,
            snapshot: { _, output in try Data("bad".utf8).write(to: output) }))
        XCTAssertTrue(target.allSatisfy { $0.gripperModel == nil })
        let justBefore = try databaseRows(at: url)
        let result = try GripperModelStorage.migrate(modelContext: context, backupDirectory: root)
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(result.converted, 20); XCTAssertEqual(result.unknown, 0)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(result.backupURL)), justBefore)
        XCTAssertEqual(rows.map { "\($0.id)|\($0.sessionId)|\($0.exerciseId)|\($0.setIndex)|\($0.weight)|\($0.reps)|\($0.isLocked)|\(String(describing: $0.lockedAt))" }.sorted(), evidence)
        XCTAssertTrue(target.allSatisfy { $0.numericWeight == 0 && $0.gripperModel != nil })
        let after = try databaseRows(at: url)
        let mutable: Set<String> = ["ZSETENTRY", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], after[table], table) }
        XCTAssertFalse(try GripperModelStorage.migrate(modelContext: context, snapshot: { _, _ in XCTFail("No repeat backup") }).didApply)
        let reopened = ModelContext(try open(url))
        XCTAssertFalse(try GripperModelStorage.migrate(modelContext: reopened).didApply)
        let restored = try reopened.fetch(FetchDescriptor<SetEntry>()).filter { $0.exerciseId == GripperLoadPresentation.exerciseId }
        XCTAssertEqual(restored.count, 20); XCTAssertTrue(restored.allSatisfy { $0.numericWeight == 0 && $0.gripperModel != nil })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), hash)
    }

    @MainActor
    func testLegacyUnknownValuesAndAdaptiveRowsArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try open(root.appendingPathComponent("default.store")), context = ModelContext(store)
        for (index, value) in [1.0, 2, 3, 1.01, 0, 5].enumerated() {
            let row = AdaptiveSetEntry(adaptiveSessionId: UUID(), occurrenceId: UUID(), exerciseId: GripperLoadPresentation.exerciseId, setIndex: index + 1, weight: value, reps: 10)
            row.gripperModel = nil; row.numericWeight = value // fixture reproduces legacy storage
            context.insert(row)
        }
        let ordinary = SetEntry(sessionId: UUID(), exerciseId: UUID(), setIndex: 1, weight: 225, reps: 12)
        context.insert(ordinary); try context.save()
        let draft = AdaptiveWorkoutSession(generatedPlanId: UUID())
        context.insert(draft); try context.save()
        XCTAssertThrowsError(try GripperModelStorage.migrate(modelContext: context, backupDirectory: root))
        context.delete(draft); try context.save()
        let result = try GripperModelStorage.migrate(modelContext: context, backupDirectory: root)
        XCTAssertEqual(result.converted, 3); XCTAssertEqual(result.unknown, 3)
        let rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(rows.map(\.gripperModel), ["G", "T", "1", nil, nil, nil])
        XCTAssertEqual(rows.map(\.numericWeight), [0, 0, 0, 1.01, 0, 5])
        XCTAssertEqual(ordinary.numericWeight, 225); XCTAssertNil(ordinary.gripperModel)
    }

    @MainActor
    func testSemanticAndLegacyExportsHydrateWithoutModelOneAmbiguity() throws {
        let legacy = Data(#"{"set_index":1,"weight":1,"reps":12}"#.utf8)
        let old = try JSONDecoder().decode(SessionExportService.ExportSet.self, from: legacy)
        XCTAssertNil(old.gripper_model); XCTAssertEqual(old.weight, 1)
        let semantic = SessionExportService.ExportSet(set_index: 2, weight: 3, reps: 6, gripperModel: "1")
        let data = try JSONEncoder().encode(semantic)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["gripper_model"] as? String, "1")
        XCTAssertEqual(json["weight"] as? Double, 0)
        XCTAssertEqual(json["load_encoding"] as? String, GripperLoadPresentation.semanticEncoding)
        let decoded = try JSONDecoder().decode(SessionExportService.ExportSet.self, from: data)
        XCTAssertEqual(decoded.weight, 3); XCTAssertEqual(decoded.gripper_model, "1")
        let malformed = Data(#"{"set_index":1,"weight":1,"reps":12,"gripper_model":"1","load_encoding":"coc_model_identity_v2"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionExportService.ExportSet.self, from: malformed))
        let fallback = Data(#"{"date":"2026-09-17T12:00:00Z","exercises":[{"name":"CoC Gripper","sets":[{"weight":1,"reps":12,"gripper_model":"1","load_encoding":"coc_model_identity_v2"}]}]}"#.utf8)
        XCTAssertNil(SessionExportService.decodeExportPayload(data: fallback))
        let store = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let context = ModelContext(store)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        let cycle = try XCTUnwrap(try context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        let exercise = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>()).first { $0.name == "Captain of Crush" })
        let payload = SessionExportService.ExportPayload(session_id: UUID().uuidString, cycle_name: "Off-Schedule", cycle_day_index: 0,
            date: "2026-09-17T12:00:00Z", exercises: [.init(exercise_id: exercise.id.uuidString, exercise_name: exercise.name, muscle: "forearms", sets: [old, decoded])], workout_kind: "ad_hoc")
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: cycle, modelContext: context)
        let rows = try context.fetch(FetchDescriptor<SetEntry>()).sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(rows.map(\.gripperModel), ["G", "1"])
        XCTAssertEqual(rows.map(\.numericWeight), [0, 0])
        XCTAssertEqual(rows.map(\.reps), [12, 6])
    }
    @MainActor
    func testAdaptiveSemanticExportRecoveryAndLegacyModelOne() throws {
        let exercise = Exercise(id: GripperLoadPresentation.exerciseId, name: "Captain of Crush",
            primaryMuscle: .forearms, type: .isolation, equipment: .machine)
        let snapshot = PlannedExerciseSnapshot(position: 0, exerciseId: exercise.id,
            exerciseName: exercise.name, primaryMuscle: .forearms, difficulty: .easy, prescribedSetCount: 3)
        let complex = PlannedComplexSnapshot(sourceDefinitionId: UUID(), sourceVersion: 1,
            position: 0, name: "Grippers", primaryMuscle: .forearms, reasonCodes: [], exercises: [snapshot])
        let readiness = DailyReadinessCheck(localDateKey: "2026-09-17", timeZoneIdentifier: "America/Los_Angeles",
            revision: 1, adaptiveProgramId: UUID(), adaptiveProgramVersion: 1, responses: [])
        let plan = GeneratedWorkoutPlan(localDateKey: "2026-09-17", timeZoneIdentifier: "America/Los_Angeles", status: .completed,
            adaptiveProgramId: readiness.adaptiveProgramId, adaptiveProgramVersion: 1, readinessCheckId: readiness.id,
            plannerVersion: 1, reasonCodes: [], complexes: [complex])
        let session = AdaptiveWorkoutSession(generatedPlanId: plan.id, finishedAt: .now, status: .completed)
        let entries = [1.0, 2, 3].enumerated().map { index, value in
            AdaptiveSetEntry(adaptiveSessionId: session.id, occurrenceId: snapshot.occurrenceId,
                exerciseId: exercise.id, setIndex: index + 1, weight: value, reps: 10 + index, isLocked: true)
        }
        let payload = AdaptiveExportService.makePayload(plan: plan, session: session, readiness: readiness,
            setEntries: entries, exercises: [exercise], overrides: [], feedback: [])
        let data = try AdaptiveExportService.encode(payload)
        let decoded = try XCTUnwrap(AdaptiveExportService.decode(data))
        let sets = decoded.plan.complexes[0].exercises[0].sets
        XCTAssertEqual(sets.map(\.numericWeight), [0, 0, 0])
        XCTAssertEqual(sets.map(\.gripper_model), ["G", "T", "1"])
        XCTAssertTrue(sets.allSatisfy { $0.load_encoding == GripperLoadPresentation.semanticEncoding })
        let store = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let context = ModelContext(store)
        XCTAssertTrue(try AdaptiveExportService.hydrate(decoded, modelContext: context))
        let restored = try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(restored.map(\.id), entries.map(\.id))
        XCTAssertEqual(restored.map(\.numericWeight), [0, 0, 0])
        XCTAssertEqual(restored.map(\.gripperModel), ["G", "T", "1"])
        XCTAssertFalse(try AdaptiveExportService.hydrate(decoded, modelContext: context))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sets[0])) as? [String: Any])
        object.removeValue(forKey: "gripper_model"); object.removeValue(forKey: "load_encoding"); object["weight"] = 1
        let legacy = try JSONDecoder().decode(AdaptiveExportService.SetV2.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.gripper_model); XCTAssertEqual(legacy.weight, 1) // old numeric 1 still means G
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
            result[name] = try rows("SELECT * FROM \"\(quoted)\"").map { $0.joined(separator: "|") }.sorted()
        }
        return result
    }
}
