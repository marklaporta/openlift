import XCTest
import SwiftData
import SQLite3
@testable import OpenLift

final class ExerciseCatalogServiceTests: XCTestCase {
    func testMakeExerciseTrimsNameAndPreservesSelectedMetadata() throws {
        let exercise = try ExerciseCatalogService.makeExercise(
            name: "  Belt Squat  ",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine,
            existingExercises: []
        )

        XCTAssertEqual(exercise.name, "Belt Squat")
        XCTAssertEqual(exercise.primaryMuscle, .quads)
        XCTAssertEqual(exercise.type, .compound)
        XCTAssertEqual(exercise.equipment, .machine)
        XCTAssertTrue(exercise.isActive)
    }

    func testMakeExerciseRejectsCaseAndWhitespaceEquivalentDuplicate() {
        let existing = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )

        XCTAssertThrowsError(
            try ExerciseCatalogService.makeExercise(
                name: "  incline   DUMBBELL press ",
                primaryMuscle: .chest,
                type: .compound,
                equipment: .dumbbell,
                existingExercises: [existing]
            )
        ) { error in
            XCTAssertEqual(
                error as? ExerciseCatalogError,
                .duplicateName("incline   DUMBBELL press")
            )
        }
    }

    func testMakeExerciseRejectsEmptyNameThroughProductionValidator() {
        XCTAssertThrowsError(
            try ExerciseCatalogService.makeExercise(
                name: "   ",
                primaryMuscle: .back,
                type: .isolation,
                equipment: .cable,
                existingExercises: []
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenLiftValidationError,
                .emptyName(entity: "Exercise")
            )
        }
    }
    func testCompactAliasesPreserveSetupAndRejectAmbiguityWithoutConsolidation() throws {
        let canonical = Exercise(id: CSDBRowIdentity.canonicalID, name: "Chest-Supported Dumbbell Row", primaryMuscle: .back, type: .compound, equipment: .dumbbell)
        let legacy = CSDBRowIdentity.legacyIDs.map { Exercise(id: $0, name: $0 == CSDBRowIdentity.legacyIDs.sorted(by: { $0.uuidString < $1.uuidString })[0] ? "Helms Row" : "Chest Supported Row", primaryMuscle: .back, type: .compound, equipment: .dumbbell) }
        let first = Exercise(name: "Chest Supported Cable Row", primaryMuscle: .back, type: .compound, equipment: .cable)
        let second = Exercise(name: "Chest-Supported Cable Row", primaryMuscle: .back, type: .compound, equipment: .cable)
        let unilateral = Exercise(name: "Single-Arm Chest-Supported Cable Row", primaryMuscle: .back, type: .compound, equipment: .cable)
        let catalog = [canonical, first, second, unilateral] + legacy
        XCTAssertTrue(CompactExerciseName.normalize(catalog))
        XCTAssertEqual(canonical.name, "CS DB Row")
        XCTAssertEqual(unilateral.name, "SA CS Cable Row")
        XCTAssertNil(CSDBRowIdentity.canonical(in: catalog))
        XCTAssertEqual(CSDBRowIdentity.historicalIDs(for: canonical.id, exercises: catalog), [canonical.id])
        XCTAssertEqual(first.name, "Chest Supported Cable Row")
        XCTAssertEqual(second.name, "Chest-Supported Cable Row")
        XCTAssertNil(CompactExerciseName.resolve("CS Cable Row", in: catalog))
        XCTAssertEqual(CompactExerciseName.resolve("Chest Supported Cable Row", in: catalog)?.id, first.id)
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0) })
        for name in ["Single Arm Chest Supported Cable Row", "Single-Arm Chest-Supported Cable Row", "SA CS Cable Row"] {
            XCTAssertEqual(BootstrapDataService.resolveImportedExercise(id: nil, name: name, byId: byID, byName: byName)?.id, unilateral.id)
        }
        XCTAssertNil(BootstrapDataService.resolveImportedExercise(id: nil, name: "CS Cable Row", byId: byID, byName: byName))
        XCTAssertFalse(CompactExerciseName.normalize(catalog))
        XCTAssertEqual(CompactExerciseName.display("Incline Side-Lying Dumbbell Lateral Raise"), "Incline Side-Lying DB Lateral Raise")
    }

    @MainActor
    func testCompactBootstrapSeedsOnceAndTemplatesResolveOldNames() throws {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        let store = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        let context = ModelContext(store)
        let existing = Exercise(name: "Dumbbell Preacher Curl", primaryMuscle: .biceps, type: .isolation, equipment: .dumbbell)
        context.insert(existing); try context.save()
        let first = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        XCTAssertEqual(existing.name, "DB Preacher Curl")
        XCTAssertFalse(first.contains { $0.name.contains("Dumbbell") || $0.name.contains("Single-Arm") || $0.name.contains("Chest Supported") })
        let ids = Set(first.map(\.id))
        let second = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        XCTAssertEqual(ids, Set(second.map(\.id)))
        XCTAssertFalse(context.hasChanges)
        _ = try BootstrapDataService.defaultStarterTemplate(exercises: second)
        _ = try BootstrapDataService.pushPullABTemplate(exercises: second, sourceTemplate: nil)
        _ = try FixedCycleClusterProgramService.makeTemplate(exercises: second)
        XCTAssertThrowsError(try ExerciseCatalogService.makeExercise(name: "Dumbbell Preacher Curl", primaryMuscle: .biceps, type: .isolation, equipment: .dumbbell, existingExercises: second))
    }

    @MainActor
    func testCompactNamesCopiedRealStoreColdReopenWhenOptedIn() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedCompactNameStore/default.store")
        guard FileManager.default.fileExists(atPath: supplied.path) else { throw XCTSkip("Stage verified store in Documents/OpenLiftCopiedCompactNameStore") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompactNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: supplied, to: url)
        func open() throws -> ModelContainer {
            let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
            return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self, configurations: [ModelConfiguration("CompactNames", schema: schema, url: url, cloudKitDatabase: .none)])
        }
        let store = try open(); let context = ModelContext(store)
        let before = try catalogInvariantRows(at: url)
        let names = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Exercise>()).map { ($0.id, $0.name) })
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let changed = catalog.filter { names[$0.id] != $0.name }
        XCTAssertEqual(changed.count, 19)
        for exercise in changed { XCTAssertEqual(exercise.name, CompactExerciseName.display(try XCTUnwrap(names[exercise.id]))) }
        let after = try catalogInvariantRows(at: url)
        for table in Set(before.keys).union(after.keys) {
            XCTAssertTrue(after[table] == before[table], "Unexpected change in \(table)")
        }
        XCTAssertNil(CSDBRowIdentity.canonical(in: catalog))
        XCTAssertEqual(catalog.first { $0.id == CSDBRowIdentity.canonicalID }?.name, "CS DB Row")
        let renamed = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.name) })
        let reopenedStore = try open(); let reopened = ModelContext(reopenedStore)
        let again = try BootstrapDataService.ensureExerciseCatalog(modelContext: reopened)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: again.map { ($0.id, $0.name) }), renamed)
        XCTAssertFalse(reopened.hasChanges)
        let cold = try catalogInvariantRows(at: url)
        for table in Set(before.keys).union(cold.keys) {
            XCTAssertTrue(cold[table] == before[table], "Unexpected cold-reopen change in \(table)")
        }
    }

    private func catalogInvariantRows(at url: URL) throws -> [String: [String]] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else { throw NSError(domain: "CompactNamesSQLite", code: 1) }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "CompactNamesSQLite", code: 2) }
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
            guard status == SQLITE_DONE else { throw NSError(domain: "CompactNamesSQLite", code: 3) }
            return result
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "CompactNamesSQLite", code: 4) }
        defer { sqlite3_finalize(statement) }
        var result: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(statement, 0))
            if ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"].contains(name) { continue }
            var columns: OpaquePointer?
            sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(name)\")", -1, &columns, nil)
            var selected: [String] = []
            while sqlite3_step(columns) == SQLITE_ROW {
                let column = String(cString: sqlite3_column_text(columns, 1))
                if column != "Z_OPT" && !(name == "ZEXERCISE" && column == "ZNAME") { selected.append("\"\(column)\"") }
            }
            sqlite3_finalize(columns)
            let predicate = name == "Z_PRIMARYKEY" ? " WHERE Z_ENT < 16000" : ""
            result[name] = try rows("SELECT \(selected.joined(separator: ",")) FROM \"\(name)\"\(predicate)").map { $0.joined(separator: "|") }.sorted()
        }
        return result
    }

}
