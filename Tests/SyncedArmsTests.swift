import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import OpenLift

final class SyncedArmsTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("QuadPhase", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    @MainActor
    private func fixture() throws -> (URL, ModelContainer, ModelContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncedArms-\(UUID().uuidString)")
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
        _ = try BootstrapDataService.applyQuadPhaseWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("quad"))
        context.insert(Exercise(id: Program.singleArmOverheadID, name: "Overhead SA Cable Extension", primaryMuscle: .triceps, type: .isolation, equipment: .cable))
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
        var previous: [String: [Program.ResolvedSlot]] = [:]
        var priorEfforts: [String: ExerciseEffortLookupResult] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.balancedVersionID) {
                let items = try resolved(context, cluster: cluster, step: step)
                previous["\(cluster)|\(step)"] = items
                for item in items {
                    if let found = try effort(context, item: item) { priorEfforts["\(item.exerciseId)|\(item.progressionKey)"] = found }
                }
            }
        }
        let oldCounters = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.balancedVersionID }.sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex)
        let result = try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(result.revision.didApply)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(result.backupURL)), before)
        let appended: Set<String> = ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZROTATIONPOOL", "ZCLUSTERROTATIONSTATE", "ZEXERCISE"]
        let mutable = appended.union(["ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ATRANSACTION", "ATRANSACTIONSTRING", "ACHANGE"])
        func preserved(_ after: [String: [String]]) {
            for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], after[table], "Changed \(table)") }
            for table in appended { XCTAssertTrue(Set(after[table] ?? []).isSuperset(of: Set(before[table] ?? [])), "Removed/changed original \(table)") }
        }
        preserved(try databaseRows(at: url))
        func projection(_ context: ModelContext) throws {
            XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.syncedArmsVersionID }.sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex), oldCounters)
            // Full joint reachable LCM (24), including a wrap from the live pointer.
            for step in 25...50 {
                for cluster in Program.Cluster.allCases {
                    let items = try resolved(context, cluster: cluster, step: step)
                    let old = previous["\(cluster)|\(step % Program.rotationLength(cluster, version: Program.balancedVersionID))"]!
                    let comparisons = cluster == .cluster1 ? Array(zip(items.prefix(2), old))
                        : cluster == .cluster2 ? [(items[0], old[0])] : Array(zip(items, old))
                    for (new, original) in comparisons {
                        XCTAssertEqual(new.exerciseId, original.exerciseId)
                        XCTAssertEqual(new.progressionKey, original.progressionKey)
                        XCTAssertEqual(new.slot.defaultSetCount, original.slot.defaultSetCount)
                    }
                    if cluster == .cluster1 && step % 4 < 3 {
                        let arms = previous["cluster2|\(step % 4)"]!.dropFirst()
                        for (new, original) in zip(items.dropFirst(2), arms) {
                            XCTAssertEqual(new.exerciseId, original.exerciseId)
                            XCTAssertEqual(new.progressionKey, original.progressionKey)
                            XCTAssertEqual(new.slot.defaultSetCount, original.slot.defaultSetCount)
                        }
                    }
                    for item in items {
                        if let expected = priorEfforts["\(item.exerciseId)|\(item.progressionKey)"] {
                            let actual = try XCTUnwrap(effort(context, item: item))
                            XCTAssertEqual(actual.sessionId, expected.sessionId)
                            XCTAssertEqual(actual.rows.map(\.weight), expected.rows.map(\.weight))
                            XCTAssertEqual(actual.rows.map(\.reps), expected.rows.map(\.reps))
                            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: item.slot.defaultSetCount, effort: actual), expected.rows.count)
                        }
                    }
                }
            }
            let additions = try resolved(context, cluster: .cluster1, step: 27)
            XCTAssertEqual(additions[2].exerciseId, Program.singleArmOverheadID)
            XCTAssertEqual(additions[3].exerciseId, Program.hammerCurlID)
            XCTAssertNil(try effort(context, item: additions[3]))
            XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: additions[3].slot.defaultSetCount, effort: nil), 2)
            if real {
                let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
                let currentProfile = Program.initialResistanceProfile(forExerciseNamed: "Overhead SA Cable Extension", exerciseId: Program.singleArmOverheadID, existingProfiles: profiles)
                let historical = try XCTUnwrap(effort(context, item: additions[2], requirement: .cable(currentProfile)))
                XCTAssertEqual(historical.rows.map(\.weight), [15, 15, 15])
                XCTAssertEqual(historical.rows.map(\.reps), [17, 10, 8])
                XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: historical), 3)
            }
        }
        try projection(context)
        let after = try databaseRows(at: url)
        XCTAssertFalse(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, snapshot: { _, _ in XCTFail("Repeated backup") }).revision.didApply)
        XCTAssertEqual(try databaseRows(at: url), after)
        let reopened = try container(at: url)
        let cold = ModelContext(reopened)
        _ = try BootstrapDataService.ensureExerciseCatalog(modelContext: cold)
        _ = try BootstrapDataService.reconcileWorkoutExports([], cycle: active(cold).1, modelContext: cold)
        try projection(cold)
        preserved(try databaseRows(at: url))
    }

    @MainActor
    func testFullRotationBackupAndColdReopen() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        try verify(root, context, real: false)
    }

    @MainActor
    func testCopiedPhoneStore() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedSyncedArmsStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else { throw XCTSkip("Stage verified phone snapshot in OpenLiftCopiedSyncedArmsStore") }
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
            XCTAssertThrowsError(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context,
                backupDirectory: root.appendingPathComponent("backups"), snapshot: snapshot))
            XCTAssertEqual(try databaseRows(at: root.appendingPathComponent("default.store")), before)
        }
        let (_, cycle) = try active(context); cycle.currentDayIndex = 99
        XCTAssertThrowsError(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Pending edits") }))
        XCTAssertTrue(context.hasChanges); context.rollback()
        let fixed = Session(cycleInstanceId: cycle.id, cycleDayIndex: 1, status: .draft)
        context.insert(fixed); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Fixed draft") }))
        context.delete(fixed); try context.save()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID()); context.insert(adaptive); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Adaptive draft") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id, adaptive.id)
    }

    @MainActor
    func testArmsAdvanceOnlyWithChestBackAndSkippedRowsStayFrozen() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        let (template, cycle) = try active(context)
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.syncedArmsVersionID }
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let armsBefore = try resolved(context, cluster: .cluster1, step: 26).map(\.exerciseId)
        func complete(_ cluster: Program.Cluster) throws -> ClusterOccurrenceRecord {
            let selection = try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states)
            let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
            let occurrence = try Program.makeOccurrence(session: session, selection: selection, exercises: catalog, entries: [], resistanceProfiles: [])
            try Program.advanceCompletedCluster(selection: selection, occurrence: occurrence, states: states)
            return occurrence
        }
        let legOnly = try complete(.cluster2)
        XCTAssertEqual(legOnly.exerciseSnapshots.count, 1)
        XCTAssertEqual(states.first { $0.clusterID == "cluster-1" }?.positionIndex, 26)
        XCTAssertEqual(try Program.selection(cluster: .cluster1, template: template, cycleInstanceId: cycle.id, states: states).day.slots.sorted { $0.position < $1.position }.map(\.exerciseId), armsBefore)
        let upper = try complete(.cluster1)
        XCTAssertEqual(upper.exerciseSnapshots.map(\.muscle), [.chest, .back, .triceps, .biceps])
        XCTAssertTrue(upper.exerciseSnapshots.allSatisfy { $0.completionStatus == .skipped })
        XCTAssertEqual(states.first { $0.clusterID == "cluster-1" }?.positionIndex, 27)
        XCTAssertEqual(states.first { $0.clusterID == "cluster-2" }?.positionIndex, 27)
        XCTAssertEqual(states.first { $0.clusterID == "cluster-3" }?.positionIndex, 25)
        XCTAssertEqual(upper.exerciseSnapshots.map(\.exerciseId), armsBefore)
    }

    @MainActor
    func testIrreduciblePreferenceFailsWithoutDiscardingCustomization() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let (old, cycle) = try active(context)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let replacement = try XCTUnwrap(CompactExerciseName.resolve("Leg Curl", in: catalog))
        context.insert(ClusterExercisePreference(programVersionID: Program.balancedVersionID, templateDayPosition: 12, slotPosition: 0, exerciseId: replacement.id))
        try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups")))
        XCTAssertEqual(cycle.templateId, old.id)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Exercise>()).contains { $0.id == Program.hammerCurlID })
    }

    @MainActor
    func testRestoredOverheadKeepsProfilesAndLaterLiteralRowReduction() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, cycle) = try active(context)
        let bilateral = try resolved(context, cluster: .cluster2, step: 0)[1]
        // Legacy compatible SA history predates the new clustered identity.
        let legacy = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, dayLabelSnapshot: "Upper", finishedAt: Date(timeIntervalSince1970: 100), status: .completed)
        context.insert(legacy)
        for index in 1...3 { context.insert(SetEntry(sessionId: legacy.id, exerciseId: Program.singleArmOverheadID, setIndex: index, weight: 15, reps: 18 - index, isLocked: true)) }
        try context.save()
        _ = try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        let item = try resolved(context, cluster: .cluster1, step: 3)[2]
        XCTAssertEqual(try effort(context, item: item)?.sessionId, legacy.id)
        let (template, _) = try active(context)
        func record(_ exercise: UUID, time: Double, count: Int, profile: ResistanceProfileValue) throws -> UUID {
            let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, dayLabelSnapshot: "Clustered Workout", finishedAt: Date(timeIntervalSince1970: time), status: .completed)
            context.insert(session)
            for index in 1...count { context.insert(SetEntry(sessionId: session.id, exerciseId: exercise, setIndex: index, weight: time, reps: 12, isLocked: true)) }
            context.insert(try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.syncedArmsVersionID, clusterID: "cluster-1", absoluteStep: 3, templateDayPosition: 3, dayLabel: "Cluster 1 · D", completedAt: session.finishedAt!, exerciseSnapshots: [ClusterExerciseProgressionSnapshot(position: 2, exerciseId: exercise, exerciseName: "Overhead", muscle: .triceps, prescribedSetCount: 2, progressionKey: item.progressionKey, resistanceProfile: profile, completionStatus: .performed)]))
            try context.save()
            return session.id
        }
        let compatible = try record(Program.singleArmOverheadID, time: 200, count: 3, profile: .weightStack)
        _ = try record(Program.singleArmOverheadID, time: 300, count: 4, profile: .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30))
        _ = try record(bilateral.exerciseId, time: 400, count: 5, profile: .weightStack)
        let found = try XCTUnwrap(effort(context, item: item, requirement: .cable(.weightStack)))
        XCTAssertEqual(found.sessionId, compatible)
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: found), 3)
        let reduced = try record(Program.singleArmOverheadID, time: 500, count: 1, profile: .weightStack)
        let latest = try XCTUnwrap(effort(context, item: item, requirement: .cable(.weightStack)))
        XCTAssertEqual(latest.sessionId, reduced)
        XCTAssertEqual(latest.rows.map(\.weight), [500])
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: latest), 1)
    }

    @MainActor
    func testVersionEightExportRecoveryKeepsFutureSelectionsAndWrap() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        // This independent export fixture starts with no fabricated completion gap.
        for state in try context.fetch(FetchDescriptor<ClusterRotationState>()) { state.positionIndex = 0 }
        try context.save()
        _ = try BootstrapDataService.applySyncedArmsRevisionWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
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
        XCTAssertEqual(metadata.program_version, 8)
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
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.syncedArmsVersionID }.isEmpty,
            "Same-store recovery must not create redundant resettable overlays")
        let recoveredStore = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let recovered = ModelContext(recoveredStore)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let destination = try active(recovered).1
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: destination, modelContext: recovered)
        let restored = try active(recovered).0
        XCTAssertEqual(Program.versionID(for: restored), Program.syncedArmsVersionID)
        let recoveredCatalog = try recovered.fetch(FetchDescriptor<Exercise>())
        for cluster in Program.Cluster.allCases {
            for step in 0...Program.rotationLength(cluster, version: Program.syncedArmsVersionID) {
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
