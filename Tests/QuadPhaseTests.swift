import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import OpenLift

final class QuadPhaseTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("QuadPhase", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    @MainActor
    private func fixture() throws -> (URL, ModelContainer, ModelContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuadPhase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try container(at: root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        _ = try BootstrapDataService.prepareSeptember2026ClusterRevision(modelContext: context, backupConfirmed: true)
        _ = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: context, backupConfirmed: true)
        _ = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: context, backupConfirmed: true)
        for (index, item) in Program.recoveryMovements.enumerated() {
            let exercise = Exercise(name: item.1, primaryMuscle: index % 2 == 0 ? .chest : .back,
                type: .compound, equipment: index < 2 ? .cable : .dumbbell)
            exercise.id = item.0; context.insert(exercise)
        }
        let cable = Exercise(name: "SA CS Cable Row", primaryMuscle: .back, type: .compound, equipment: .cable)
        cable.id = Program.pairedCableRowID; context.insert(cable)
        try context.save()
        _ = try BootstrapDataService.prepareChestBackRevision(modelContext: context, backupConfirmed: true)
        context.insert(ClusterExercisePreference(programVersionID: Program.chestBackVersionID,
            templateDayPosition: 1, slotPosition: 1, exerciseId: cable.id))
        try context.save()
        for state in try context.fetch(FetchDescriptor<ClusterRotationState>()) where state.programVersionID == Program.chestBackVersionID {
            state.positionIndex = state.clusterID == "cluster-3" ? 24 : 25
        }
        try context.save()
        _ = try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("pairing"))
        _ = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        _ = try BootstrapDataService.prepareBalancedRevision(modelContext: context, backupConfirmed: true)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        context.insert(ClusterExercisePreference(programVersionID: Program.balancedVersionID,
            templateDayPosition: 5, slotPosition: 0, exerciseId: CompactExerciseName.resolve("Leg Extension", in: catalog)!.id))
        for state in try context.fetch(FetchDescriptor<ClusterRotationState>()) where state.programVersionID == Program.balancedVersionID {
            state.positionIndex = state.clusterID == "cluster-3" ? 25 : 26
        }
        try context.save()
        return (root, store, context)
    }

    private func active(_ context: ModelContext) throws -> (CycleTemplate, ActiveCycleInstance) {
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first { c in templates.contains { $0.id == c.templateId && Program.isProgramTemplate($0) } })
        let template = try XCTUnwrap(templates.first { $0.id == cycle.templateId })
        return (template, cycle)
    }

    private func resolved(_ context: ModelContext, cluster: Program.Cluster, step: Int) throws -> [Program.ResolvedSlot] {
        let (template, cycle) = try active(context)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.versionID(for: template))
        states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
        return Program.resolvedSlots(selection: try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states),
            sessionId: UUID(), preferences: try context.fetch(FetchDescriptor<ClusterExercisePreference>()), overrides: [])
    }

    private func effort(_ context: ModelContext, item: Program.ResolvedSlot,
                        requirement: ResistanceProfileLookupRequirement = .notApplicable) throws -> ExerciseEffortLookupResult? {
        let (_, cycle) = try active(context)
        return ExerciseEffortLookupService.fixedCycleEffort(exerciseId: item.exerciseId, cycleInstanceId: cycle.id, cycleDayIndex: 1,
            adaptiveSessions: try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()),
            adaptiveSetEntries: try context.fetch(FetchDescriptor<AdaptiveSetEntry>()),
            rotationSessions: try context.fetch(FetchDescriptor<Session>()), rotationSetEntries: try context.fetch(FetchDescriptor<SetEntry>()),
            progressionKey: item.progressionKey, progressionOccurrences: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()),
            resistanceRequirement: requirement, resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()),
            exercises: try context.fetch(FetchDescriptor<Exercise>()))
    }

    @MainActor
    private func verify(_ root: URL, _ context: ModelContext, real: Bool) throws {
        let url = root.appendingPathComponent("default.store")
        let before = try databaseRows(at: url)
        var rowsBefore: [String: [Program.ResolvedSlot]] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.balancedVersionID) {
                rowsBefore["\(cluster)|\(step)"] = try resolved(context, cluster: cluster, step: step)
            }
        }
        let priorQuads = try [9, 3, 5, 7].map { try resolved(context, cluster: .cluster2, step: $0)[0] }
        let priorEfforts = try Dictionary(uniqueKeysWithValues: priorQuads.map { ($0.exerciseId, try effort(context, item: $0)) })
        let result = try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(result.backupURL)), before)
        let mutable: Set<String> = ["ZCLUSTEREXERCISEPREFERENCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ATRANSACTION", "ATRANSACTIONSTRING", "ACHANGE"]
        func unchanged(_ after: [String: [String]]) {
            for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], after[table], "Changed \(table)") }
        }
        let changed = try databaseRows(at: url)
        unchanged(changed)
        XCTAssertTrue(Set(changed["ZCLUSTEREXERCISEPREFERENCE"] ?? []).isSuperset(of: Set(before["ZCLUSTEREXERCISEPREFERENCE"] ?? [])))
        XCTAssertEqual((changed["ZCLUSTEREXERCISEPREFERENCE"] ?? []).count, (before["ZCLUSTEREXERCISEPREFERENCE"] ?? []).count + 11)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let names = ["Back Extension", "Leg Extension", "Stiff-Leg Deadlift", "Belt Squat", "Reverse Hyper", "Bulgarian Split Squat", "Leg Curl", "Safety Bar Squat"]
        func verifyProjection(_ context: ModelContext) throws {
            for cluster in Program.Cluster.allCases {
                for step in 26...50 {
                    let rows = try resolved(context, cluster: cluster, step: step)
                    let old = rowsBefore["\(cluster)|\(step % Program.rotationLength(cluster, version: Program.balancedVersionID))"]!
                    for index in rows.indices {
                        if cluster == .cluster2 && index == 0 && step % 2 == 1 {
                            XCTAssertEqual(catalog.first { $0.id == rows[0].exerciseId }?.name, names[step % 8])
                            XCTAssertEqual(rows[0].progressionKey, Program.balancedMovementKey(role: "legs", exerciseId: rows[0].exerciseId))
                            if let expected = priorEfforts[rows[0].exerciseId] ?? nil {
                                let actual = try XCTUnwrap(effort(context, item: rows[0]))
                                XCTAssertEqual(actual.sessionId, expected.sessionId)
                                XCTAssertEqual(actual.rows.map(\.weight), expected.rows.map(\.weight))
                                XCTAssertEqual(actual.rows.map(\.reps), expected.rows.map(\.reps))
                                XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: rows[0].slot.defaultSetCount, effort: actual), expected.rows.count)
                            }
                        } else {
                            XCTAssertEqual(rows[index].exerciseId, old[index].exerciseId)
                            XCTAssertEqual(rows[index].progressionKey, old[index].progressionKey)
                        }
                        XCTAssertEqual(rows[index].slot.defaultSetCount, old[index].slot.defaultSetCount)
                    }
                }
            }
        }
        try verifyProjection(context)
        if real {
            XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.balancedVersionID }.sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex), [26, 26, 25])
            // The copied phone has a compatible latest effort for every quad movement.
            for step in [27, 29, 31, 33] { XCTAssertNotNil(try effort(context, item: resolved(context, cluster: .cluster2, step: step)[0])) }
        }
        let after = try databaseRows(at: url)
        XCTAssertFalse(try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context, snapshot: { _, _ in XCTFail("Repeated backup") }).didApply)
        XCTAssertEqual(try databaseRows(at: url), after)
        let reopened = try container(at: url)
        let cold = ModelContext(reopened)
        _ = try BootstrapDataService.ensureExerciseCatalog(modelContext: cold)
        try verifyProjection(cold)
        unchanged(try databaseRows(at: url))
    }

    @MainActor
    func testFullRotationBackupAndColdReopen() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        try verify(root, context, real: false)
    }

    @MainActor
    func testCopiedPhoneStore() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedQuadPhaseStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else { throw XCTSkip("Stage verified phone snapshot in OpenLiftCopiedQuadPhaseStore") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuadPhaseReal-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: supplied, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try container(at: root.appendingPathComponent("default.store"))
        try verify(root, ModelContext(store), real: true)
    }

    @MainActor
    func testBackupFailurePendingEditsAndBothDraftKinds() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try databaseRows(at: root.appendingPathComponent("default.store"))
        enum Failure: Error { case injected }
        for snapshot: (URL, URL) throws -> Void in [{ _, _ in throw Failure.injected }, { _, url in try Data("invalid".utf8).write(to: url) }] {
            XCTAssertThrowsError(try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context,
                backupDirectory: root.appendingPathComponent("backups"), snapshot: snapshot))
            XCTAssertEqual(try databaseRows(at: root.appendingPathComponent("default.store")), before)
        }
        let (_, cycle) = try active(context); cycle.currentDayIndex = 99
        XCTAssertThrowsError(try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Pending edits") }))
        XCTAssertTrue(context.hasChanges); context.rollback()
        let fixed = Session(cycleInstanceId: cycle.id, cycleDayIndex: 1, status: .draft)
        context.insert(fixed); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Fixed draft") }))
        context.delete(fixed); try context.save()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID()); context.insert(adaptive); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Adaptive draft") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id, adaptive.id)
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
