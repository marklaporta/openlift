import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import OpenLift

final class ChestBackRowPairingTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("RowPairing", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    private func fixture() throws -> (URL, ModelContainer, ModelContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RowPairing-\(UUID().uuidString)")
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
        return (root, store, context)
    }

    private func active(_ context: ModelContext) throws -> (CycleTemplate, ActiveCycleInstance) {
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycle = try XCTUnwrap(try context.fetch(FetchDescriptor<ActiveCycleInstance>()).first {
            c in templates.contains { $0.id == c.templateId && Program.versionID(for: $0) == Program.chestBackVersionID }
        })
        return (try XCTUnwrap(templates.first { $0.id == cycle.templateId }), cycle)
    }

    private func resolved(_ context: ModelContext, cluster: Program.Cluster = .cluster1, step: Int) throws -> [Program.ResolvedSlot] {
        let (template, cycle) = try active(context)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.chestBackVersionID)
        states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
        let selection = try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states)
        return Program.resolvedSlots(selection: selection, sessionId: UUID(),
            preferences: try context.fetch(FetchDescriptor<ClusterExercisePreference>()), overrides: [])
    }

    private func unchangedState(_ context: ModelContext) throws -> [String] {
        var result = try context.fetch(FetchDescriptor<SetEntry>()).map {
            "set|\($0.id)|\($0.sessionId)|\($0.exerciseId)|\($0.setIndex)|\($0.weight)|\($0.reps)|\($0.isLocked)|\(String(describing: $0.lockedAt))"
        }
        result += try context.fetch(FetchDescriptor<ClusterRotationState>()).map {
            "pointer|\($0.id)|\($0.cycleInstanceId)|\($0.templateId)|\($0.programVersionID)|\($0.clusterID)|\($0.positionIndex)|\($0.updatedAt)|\(String(describing: $0.lastCompletedOccurrenceID))|\($0.isDerived)"
        }
        result += try context.fetch(FetchDescriptor<Session>()).map {
            "session|\($0.id)|\($0.cycleInstanceId)|\($0.cycleDayIndex)|\($0.status)|\(String(describing: $0.finishedAt))"
        }
        result += try context.fetch(FetchDescriptor<Exercise>()).map { "exercise|\($0.id)|\($0.name)|\($0.notes)" }
        for template in try context.fetch(FetchDescriptor<CycleTemplate>()) {
            for day in template.days {
                result += day.slots.map { "slot|\(template.id)|\(template.name)|\(day.position)|\(day.label)|\($0.position)|\($0.exerciseId)|\($0.defaultSetCount)|\($0.muscle)" }
            }
        }
        return result.sorted()
    }

    private func effort(_ context: ModelContext, item: Program.ResolvedSlot) throws -> ExerciseEffortLookupResult? {
        let (_, cycle) = try active(context)
        return ExerciseEffortLookupService.fixedCycleEffort(exerciseId: item.exerciseId,
            cycleInstanceId: cycle.id, cycleDayIndex: 1, adaptiveSessions: [], adaptiveSetEntries: [],
            rotationSessions: try context.fetch(FetchDescriptor<Session>()),
            rotationSetEntries: try context.fetch(FetchDescriptor<SetEntry>()), progressionKey: item.progressionKey,
            progressionOccurrences: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()),
            resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()))
    }

    @MainActor
    private func verify(_ root: URL, _ context: ModelContext) throws {
        let url = root.appendingPathComponent("default.store")
        let before = try databaseRows(at: url)
        let oldPrefs = try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter {
            !($0.programVersionID == Program.chestBackVersionID && [1, 15].contains($0.templateDayPosition) && $0.slotPosition == 1)
        }.map { "\($0.id)|\($0.key)|\($0.exerciseId)|\($0.updatedAt)" }.sorted()
        var old: [String: [Program.ResolvedSlot]] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.chestBackVersionID) {
                old["\(cluster)|\(step)"] = try resolved(context, cluster: cluster, step: step)
            }
        }
        let oldDB = try effort(context, item: old["cluster1|3"]![1])
        let oldCable = try effort(context, item: old["cluster1|1"]![1])
        let applied = try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(applied.didApply)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(applied.backupURL)), before)
        let after = try databaseRows(at: url)
        let mutable: Set<String> = ["ZCLUSTEREXERCISEPREFERENCE", "Z_PRIMARYKEY", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys where !mutable.contains(table) { XCTAssertEqual(after[table], before[table], "Changed \(table)") }
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter {
            !($0.programVersionID == Program.chestBackVersionID && [1, 15].contains($0.templateDayPosition) && $0.slotPosition == 1)
        }.map { "\($0.id)|\($0.key)|\($0.exerciseId)|\($0.updatedAt)" }.sorted(), oldPrefs)
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.chestBackVersionID) {
                let current = try resolved(context, cluster: cluster, step: step)
                for index in current.indices {
                    let source = cluster == .cluster1 && index == 1 && [1, 3].contains(step) ? 4 - step : step
                    let prior = old["\(cluster)|\(source)"]![index]
                    XCTAssertEqual(current[index].exerciseId, prior.exerciseId)
                    XCTAssertEqual(current[index].progressionKey, prior.progressionKey)
                    XCTAssertEqual(current[index].slot.defaultSetCount, prior.slot.defaultSetCount)
                }
            }
        }
        for (step, previous) in [(1, oldDB), (3, oldCable)] {
            let current = try effort(context, item: resolved(context, step: step)[1])
            XCTAssertEqual(current?.rows.map(\.weight), previous?.rows.map(\.weight))
            XCTAssertEqual(current?.rows.map(\.reps), previous?.rows.map(\.reps))
            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: current), previous?.rows.count ?? 2)
        }
        XCTAssertFalse(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Repeat backup") }).didApply)
        XCTAssertEqual(try databaseRows(at: url), after)
        let reopenURL = root.appendingPathComponent("row-pairing-cold.store")
        try StoreBackupService.snapshot(storeAt: url, into: reopenURL)
        let reopenedStore = try container(at: reopenURL)
        let reopened = ModelContext(reopenedStore)
        XCTAssertEqual(try unchangedState(reopened), try unchangedState(context))
        XCTAssertEqual(try resolved(reopened, step: 1)[1].exerciseId, Program.recoveryMovements[3].0)
        XCTAssertEqual(try resolved(reopened, step: 3)[1].exerciseId, Program.pairedCableRowID)
        for (step, previous) in [(1, oldDB), (3, oldCable)] {
            let current = try effort(reopened, item: resolved(reopened, step: step)[1])
            XCTAssertEqual(current?.rows.map(\.weight), previous?.rows.map(\.weight))
            XCTAssertEqual(current?.rows.map(\.reps), previous?.rows.map(\.reps))
            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: current), previous?.rows.count ?? 2)
        }
        XCTAssertFalse(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: reopened,
            snapshot: { _, _ in XCTFail("Cold repeat backup") }).didApply)
        print("OPENLIFT_ROW_PAIRING_VERIFIED tables=\(before.count) DBRows=\(oldDB?.rows.count ?? 0) cableRows=\(oldCable?.rows.count ?? 0)")
    }

    @MainActor
    func testSwapRetainsExerciseProgressionAndLiteralRowCounts() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let (template, cycle) = try active(context)
        for step in [1, 3] {
            let row = try resolved(context, step: step)[1]
            let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: step, finishedAt: Date(timeIntervalSince1970: 100), status: .completed)
            context.insert(session)
            for index in 1...(step == 1 ? 3 : 2) {
                context.insert(SetEntry(sessionId: session.id, exerciseId: row.exerciseId, setIndex: index,
                    weight: step == 1 ? 50 : 65, reps: 12 - index, isLocked: true))
            }
            context.insert(try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: cycle.id,
                templateId: template.id, programVersionID: Program.chestBackVersionID, clusterID: "cluster-1",
                absoluteStep: step, templateDayPosition: step == 1 ? 1 : 15, dayLabel: "Row",
                completedAt: session.finishedAt!, exerciseSnapshots: [ClusterExerciseProgressionSnapshot(position: 1,
                    exerciseId: row.exerciseId, exerciseName: "Row", muscle: .back, prescribedSetCount: 2,
                    progressionKey: row.progressionKey, resistanceProfile: nil, completionStatus: .performed)]))
        }
        try context.save()
        try verify(root, context)
        XCTAssertEqual(try effort(context, item: resolved(context, step: 1)[1])?.rows.count, 2)
        XCTAssertEqual(try effort(context, item: resolved(context, step: 3)[1])?.rows.count, 3)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id,
            programVersionID: Program.chestBackVersionID)
        states.first { $0.clusterID == "cluster-1" }!.positionIndex = 3
        let selection = try Program.selection(cluster: .cluster1, template: template, cycleInstanceId: cycle.id, states: states)
        let reduced = Session(cycleInstanceId: cycle.id, cycleDayIndex: 15, finishedAt: .now, status: .completed)
        context.insert(reduced)
        let entry = SetEntry(sessionId: reduced.id, exerciseId: Program.pairedCableRowID, setIndex: 1,
            weight: 55, reps: 9, isLocked: true)
        context.insert(entry)
        context.insert(try Program.makeOccurrence(session: reduced, selection: selection,
            exercises: context.fetch(FetchDescriptor<Exercise>()), entries: [entry], resistanceProfiles: [],
            preferences: context.fetch(FetchDescriptor<ClusterExercisePreference>())))
        try context.save()
        let latest = try XCTUnwrap(effort(context, item: resolved(context, step: 3)[1]))
        XCTAssertEqual(latest.sessionId, reduced.id)
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: latest), 1)
        XCTAssertEqual(latest.rows.map(\.weight), [55])
        XCTAssertEqual(latest.rows.map(\.reps), [9])
    }

    @MainActor
    func testDraftPendingChangesBackupFailureAndUnrelatedSubstitutionAreRejected() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try databaseRows(at: root.appendingPathComponent("default.store"))
        enum Failure: Error { case injected }
        for snapshot: (URL, URL) throws -> Void in [{ _, _ in throw Failure.injected }, { _, url in try Data("invalid".utf8).write(to: url) }] {
            XCTAssertThrowsError(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
                backupDirectory: root.appendingPathComponent("backups"), snapshot: snapshot))
            XCTAssertEqual(try databaseRows(at: root.appendingPathComponent("default.store")), before)
        }
        let (_, cycle) = try active(context)
        cycle.currentDayIndex = 99
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Pending changes") }))
        XCTAssertTrue(context.hasChanges); context.rollback()
        let fixed = Session(cycleInstanceId: cycle.id, cycleDayIndex: 1, status: .draft)
        context.insert(fixed); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Fixed draft") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).first?.id, fixed.id)
        context.delete(fixed); try context.save()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID())
        context.insert(adaptive); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Adaptive draft") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id, adaptive.id)
        context.delete(adaptive); try context.save()
        let preference = try XCTUnwrap(context.fetch(FetchDescriptor<ClusterExercisePreference>()).first)
        preference.exerciseId = UUID(); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRowPairingWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Unrelated substitution") }))
    }

    @MainActor
    func testCopiedRealStoreRowPairingWhenOptedIn() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let supplied = documents.appendingPathComponent("OpenLiftCopiedRowPairingStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Stage verified v6 store in Documents/OpenLiftCopiedRowPairingStore")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RowPairingReal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: supplied, to: root)
        let store = try container(at: root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        try verify(root, context)
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
