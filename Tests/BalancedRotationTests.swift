import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import OpenLift

final class BalancedRotationTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("BalancedRotation", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    @MainActor
    private func fixture() throws -> (URL, ModelContainer, ModelContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BalancedRotation-\(UUID().uuidString)")
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
        let (old, _) = try active(context)
        let oldID = old.id
        let oldPointers = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.templateId == oldID }
            .sorted { $0.clusterID < $1.clusterID }.map { $0.positionIndex }
        var source: [String: [Program.ResolvedSlot]] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.chestBackVersionID) {
                source["\(cluster)|\(step)"] = try resolved(context, cluster: cluster, step: step)
            }
        }
        let result = try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(result.revision.didApply)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(result.backupURL)), before)
        let after = try databaseRows(at: url)
        let mutable: Set<String> = ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZROTATIONPOOL", "ZCLUSTERROTATIONSTATE", "ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ATRANSACTION", "ATRANSACTIONSTRING", "ACHANGE"]
        for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], after[table], "Changed \(table)") }
        // Existing templates, pointers and preferences remain archived verbatim.
        for table in ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZROTATIONPOOL", "ZCLUSTERROTATIONSTATE"] {
            XCTAssertTrue(Set(after[table] ?? []).isSuperset(of: Set(before[table] ?? [])), table)
        }
        let (template, cycle) = try active(context)
        XCTAssertTrue(Program.isProgramTemplate(template)); XCTAssertEqual(Program.versionID(for: template), Program.balancedVersionID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.templateId == template.id }
            .sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex), oldPointers)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        func name(_ id: UUID) -> String { catalog.first { $0.id == id }!.name }
        for step in 0..<49 {
            let rows = try resolved(context, cluster: .cluster2, step: step)
            XCTAssertEqual(name(rows[0].exerciseId), Program.balancedLegNames[step % 8])
            for slot in 1...2 {
                let previous = source["cluster2|\(step % 6)"]![slot]
                XCTAssertEqual(rows[slot].exerciseId, previous.exerciseId)
                XCTAssertEqual(rows[slot].progressionKey, previous.progressionKey)
                XCTAssertEqual(rows[slot].slot.defaultSetCount, previous.slot.defaultSetCount)
            }
        }
        for step in 0..<6 {
            let rows = try resolved(context, cluster: .cluster3, step: step)
            XCTAssertEqual(CompactExerciseName.display(name(rows[0].exerciseId)), [Program.sideDeltExerciseName, "Super ROM DB Lateral Raise", "Cable Lateral Raise"][step % 3])
            for slot in 1..<rows.count {
                XCTAssertEqual(rows[slot].exerciseId, source["cluster3|\(step)"]![slot].exerciseId)
                XCTAssertEqual(rows[slot].slot.defaultSetCount, source["cluster3|\(step)"]![slot].slot.defaultSetCount)
            }
        }
        for step in 0..<4 {
            let rows = try resolved(context, cluster: .cluster1, step: step)
            for slot in 0...1 {
                XCTAssertEqual(rows[slot].exerciseId, source["cluster1|\(step)"]![slot].exerciseId)
                XCTAssertEqual(rows[slot].progressionKey, source["cluster1|\(step)"]![slot].progressionKey)
                XCTAssertEqual(rows[slot].slot.defaultSetCount, source["cluster1|\(step)"]![slot].slot.defaultSetCount)
            }
        }
        for a in 0..<4 { for b in 0..<24 { for c in 0..<6 {
            let ids = try resolved(context, cluster: .cluster1, step: a).map(\.exerciseId)
                + resolved(context, cluster: .cluster2, step: b).map(\.exerciseId)
                + resolved(context, cluster: .cluster3, step: c).map(\.exerciseId)
            XCTAssertEqual(ids.count, Set(ids).count)
        } } }
        let next = try resolved(context, cluster: .cluster2, step: 25)
        XCTAssertEqual(next.map { CompactExerciseName.display(name($0.exerciseId)) }, ["Belt Squat", "Cable Pushdown", "DB Preacher Curl"])
        if real {
            for step in [0, 7] {
                let row = try resolved(context, cluster: .cluster2, step: step)[0]
                let prior = try XCTUnwrap(effort(context, item: row))
                XCTAssertFalse(prior.rows.isEmpty)
                XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: row.slot.defaultSetCount, effort: prior), prior.rows.count)
            }
            let superROM = try XCTUnwrap(effort(context, item: resolved(context, cluster: .cluster3, step: 1)[0]))
            XCTAssertEqual(superROM.rows.map(\.weight), [10, 10]); XCTAssertEqual(superROM.rows.map(\.reps), [12, 9])
            for step in [0, 2, 4] {
                let calf = try XCTUnwrap(effort(context, item: resolved(context, cluster: .cluster3, step: step)[1]))
                XCTAssertEqual(calf.rows.map(\.weight), [210, 210]); XCTAssertEqual(calf.rows.map(\.reps), [22, 20])
            }
        }
        XCTAssertFalse(try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Repeated backup") }).revision.didApply)
        _ = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let retainedExports: [SessionExportService.ExportPayload]
        if real {
            let url = root.appendingPathComponent("affected-legacy-export.json")
            retainedExports = [try XCTUnwrap(SessionExportService.decodeExportPayload(data: Data(contentsOf: url), fileURL: url))]
        } else { retainedExports = [] }
        _ = try BootstrapDataService.reconcileWorkoutExports(retainedExports, cycle: cycle, modelContext: context)
        let reopened = try container(at: url)
        let cold = ModelContext(reopened)
        XCTAssertEqual(try active(cold).0.id, template.id)
        XCTAssertEqual(try resolved(cold, cluster: .cluster2, step: 25).map(\.exerciseId), next.map(\.exerciseId))
        let coldRows = try databaseRows(at: url)
        for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], coldRows[table], "Cold changed \(table)") }
    }

    @MainActor
    func testFullRotationBackupAndColdReopen() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        try verify(root, context, real: false)
    }

    @MainActor
    func testCopiedPhoneStore() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedBalancedStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else { throw XCTSkip("Stage verified phone snapshot in OpenLiftCopiedBalancedStore") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BalancedReal-\(UUID().uuidString)")
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
            XCTAssertThrowsError(try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context,
                backupDirectory: root.appendingPathComponent("backups"), snapshot: snapshot))
            XCTAssertEqual(try databaseRows(at: root.appendingPathComponent("default.store")), before)
        }
        let (_, cycle) = try active(context); cycle.currentDayIndex = 99
        XCTAssertThrowsError(try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Pending edits") }))
        XCTAssertTrue(context.hasChanges); context.rollback()
        let fixed = Session(cycleInstanceId: cycle.id, cycleDayIndex: 1, status: .draft)
        context.insert(fixed); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Fixed draft") }))
        context.delete(fixed); try context.save()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID()); context.insert(adaptive); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Adaptive draft") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id, adaptive.id)
    }

    @MainActor
    func testMovementAliasesKeepUUIDProfileAndLatestLiteralRows() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let (old, cycle) = try active(context)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let superID = try XCTUnwrap(CompactExerciseName.resolve("Super ROM DB Lateral Raise", in: catalog)).id
        let inclineID = Program.sideDeltExerciseID
        let cableID = try XCTUnwrap(CompactExerciseName.resolve("Cable Lateral Raise", in: catalog)).id
        let calfID = try XCTUnwrap(CompactExerciseName.resolve("Stair Calves", in: catalog)).id
        @discardableResult
        func record(_ id: UUID, time: Double, rows: Int, key: String, role: MuscleGroup,
                    position: Int, profile: ResistanceProfileValue? = nil, version: String = Program.chestBackVersionID) throws -> Session {
            let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 9, dayLabelSnapshot: "Clustered Workout",
                finishedAt: Date(timeIntervalSince1970: time), status: .completed)
            context.insert(session)
            for index in 1...rows {
                context.insert(SetEntry(sessionId: session.id, exerciseId: id, setIndex: index, weight: time, reps: 10 + index, isLocked: true))
            }
            context.insert(try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: cycle.id,
                templateId: old.id, programVersionID: version, clusterID: "cluster-3", absoluteStep: Int(time),
                templateDayPosition: 9, dayLabel: "Shoulders", completedAt: session.finishedAt!,
                exerciseSnapshots: [ClusterExerciseProgressionSnapshot(position: position, exerciseId: id,
                    exerciseName: catalog.first { $0.id == id }!.name, muscle: role, prescribedSetCount: 2,
                    progressionKey: key, resistanceProfile: profile, completionStatus: .performed)]))
            try context.save()
            return session
        }
        let first = Program.progressionKey(cluster: .cluster3, effectiveStep: 0, slotPosition: 0)
        _ = try record(superID, time: 100, rows: 2, key: Program.sideDeltProgressionKey, role: .sideDelts, position: 0)
        let latest = try record(superID, time: 200, rows: 3, key: first, role: .sideDelts, position: 0)
        _ = try record(inclineID, time: 300, rows: 4, key: first, role: .sideDelts, position: 0)
        let calf = try record(calfID, time: 200, rows: 3,
            key: Program.progressionKey(cluster: .cluster3, effectiveStep: 4, slotPosition: 1), role: .calves, position: 1)
        let compatible = try record(cableID, time: 200, rows: 3, key: first, role: .sideDelts, position: 0, profile: .weightStack)
        _ = try record(cableID, time: 400, rows: 4, key: Program.sideDeltProgressionKey, role: .sideDelts, position: 0,
            profile: .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30))
        _ = try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        for step in [1, 4] {
            let item = try resolved(context, cluster: .cluster3, step: step)[0]
            let found = try XCTUnwrap(effort(context, item: item))
            XCTAssertEqual(found.sessionId, latest.id)
            XCTAssertEqual(found.rows.count, 3)
            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: item.slot.defaultSetCount, effort: found), 3)
        }
        for step in [0, 2, 4] { XCTAssertEqual(try effort(context, item: resolved(context, cluster: .cluster3, step: step)[1])?.sessionId, calf.id) }
        XCTAssertEqual(try effort(context, item: resolved(context, cluster: .cluster3, step: 2)[0], requirement: .cable(.weightStack))?.sessionId, compatible.id)
        let changed = try record(superID, time: 500, rows: 1,
            key: Program.balancedMovementKey(role: "shoulders", exerciseId: superID), role: .sideDelts, position: 0, version: Program.balancedVersionID)
        for step in [1, 4] {
            let found = try XCTUnwrap(effort(context, item: resolved(context, cluster: .cluster3, step: step)[0]))
            XCTAssertEqual(found.sessionId, changed.id); XCTAssertEqual(found.rows.map(\.weight), [500]); XCTAssertEqual(found.rows.map(\.reps), [11])
            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: found), 1)
        }
    }

    @MainActor
    func testVersionSevenExportRecoveryKeepsFutureSelectionsAndWrap() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        // This independent export fixture starts with no fabricated completion gap.
        for state in try context.fetch(FetchDescriptor<ClusterRotationState>()) { state.positionIndex = 0 }
        try context.save()
        _ = try BootstrapDataService.applyBalancedRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        let (template, cycle) = try active(context)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Clustered Workout", finishedAt: Date(timeIntervalSince1970: 1000), status: .completed)
        context.insert(session)
        for selection in try Program.selections(template: template, cycleInstanceId: cycle.id, states: states) {
            let items = Program.resolvedSlots(selection: selection, sessionId: session.id, preferences: [], overrides: [])
            let rows = items.map { SetEntry(sessionId: session.id, exerciseId: $0.exerciseId, setIndex: 1, weight: 20, reps: 12, isLocked: true) }
            rows.forEach(context.insert)
            let occurrence = try Program.makeOccurrence(session: session, selection: selection, exercises: catalog, entries: rows, resistanceProfiles: [])
            context.insert(occurrence)
            try Program.advanceCompletedCluster(selection: selection, occurrence: occurrence, states: states)
        }
        try context.save()
        let entries = try context.fetch(FetchDescriptor<SetEntry>())
        let occurrences = try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let metadata = SessionExportService.fixedCycleMetadata(session: session, template: template, day: template.days[0], exercises: catalog,
            setEntries: entries, readiness: [], overrides: [], clusterOccurrences: occurrences, clusterRotationStates: states)
        XCTAssertEqual(metadata.program_version, 7)
        XCTAssertEqual(metadata.cluster_exercise_preferences?.count, template.days.flatMap(\.slots).count)
        let payload = SessionExportService.ExportPayload(session_id: session.id.uuidString, cycle_name: template.name, cycle_day_index: 0,
            date: ISO8601DateFormatter().string(from: session.finishedAt!), exercises: entries.map { row in
                SessionExportService.ExportExercise(exercise_id: row.exerciseId.uuidString,
                    exercise_name: catalog.first { $0.id == row.exerciseId }!.name,
                    muscle: catalog.first { $0.id == row.exerciseId }!.primaryMuscle.rawValue,
                    sets: [SessionExportService.ExportSet(set_index: 1, weight: row.weight, reps: row.reps)])
            }, fixed_cycle: metadata)
        let unchangedEntries = try context.fetch(FetchDescriptor<SetEntry>()).map(\.id).sorted { $0.uuidString < $1.uuidString }
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: cycle, modelContext: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetEntry>()).map(\.id).sorted { $0.uuidString < $1.uuidString }, unchangedEntries)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.balancedVersionID }.isEmpty,
            "Same-store recovery must not create redundant resettable overlays")
        let recoveredStore = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let recovered = ModelContext(recoveredStore)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let destination = try active(recovered).1
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: destination, modelContext: recovered)
        let restored = try active(recovered).0
        XCTAssertEqual(Program.versionID(for: restored), Program.balancedVersionID)
        let recoveredCatalog = try recovered.fetch(FetchDescriptor<Exercise>())
        for cluster in Program.Cluster.allCases {
            for step in 0...Program.rotationLength(cluster, version: Program.balancedVersionID) {
                let source = try resolved(context, cluster: cluster, step: step)
                let copy = try resolved(recovered, cluster: cluster, step: step)
                XCTAssertEqual(copy.map { id in recoveredCatalog.first { $0.id == id.exerciseId }!.name }, source.map { id in catalog.first { $0.id == id.exerciseId }!.name })
            }
        }
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<SetEntry>()).count, entries.count)
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).count, 3)
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: destination, modelContext: recovered)
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<SetEntry>()).count, entries.count)
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
