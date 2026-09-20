import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import OpenLift

final class ProgramImportTests: XCTestCase {
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
        _ = try BootstrapDataService.prepareSyncedArmsRevision(modelContext: context, backupConfirmed: true)
        return (root, store, context)
    }


    @MainActor
    func testParserAndReadOnlyPreview() throws {
        let (_, _, context) = try fixture()
        let package = try ProgramImportService.revisionStarter(context: context)
        XCTAssertEqual(try ProgramImportService.decode(JSONEncoder().encode(package)), package)
        let before = try context.fetchCount(FetchDescriptor<CycleTemplate>())
        let preview = try ProgramImportService.preview(package, context: context)
        XCTAssertEqual(preview.upcoming.count, 3)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CycleTemplate>()), before)
        XCTAssertThrowsError(try ProgramImportService.decode(Data(repeating: 0, count: 262145)))
        XCTAssertThrowsError(try ProgramImportService.decode(Data("{}".utf8)))
    }

    @MainActor
    func testBackupFailureSaveFailureAndRepeatedApply() throws {
        let (root, _, context) = try fixture()
        let package = try ProgramImportService.revisionStarter(context: context)
        let preview = try ProgramImportService.preview(package, context: context)
        let cycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        let old = cycle.templateId
        XCTAssertThrowsError(try ProgramImportService.apply(preview, context: context, backupDirectory: root, snapshot: { _,_ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(cycle.templateId, old)
        XCTAssertThrowsError(try ProgramImportService.apply(preview, context: context, backupDirectory: root, save: { _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(cycle.templateId, old)
        XCTAssertFalse(context.hasChanges)
        let applied = try ProgramImportService.apply(preview, context: context, backupDirectory: root)
        XCTAssertTrue(applied.didApply)
        XCTAssertNotEqual(cycle.templateId, old)
        XCTAssertFalse(try ProgramImportService.apply(preview, context: context, backupDirectory: root).didApply)
        let fresh = try container(at: root.appendingPathComponent("default.store"))
        let newContext = ModelContext(fresh)
        let template = try XCTUnwrap(newContext.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == cycle.templateId })
        XCTAssertEqual(ClusterProgramDefinition.embedded(in: template), package.definition)
        let states = try newContext.fetch(FetchDescriptor<ClusterRotationState>())
        for cluster in Program.Cluster.allCases {
            let selection = try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states)
            XCTAssertEqual(selection.definition, package.definition)
            XCTAssertEqual(selection.absoluteStep, package.counters.first { $0.clusterID == cluster.rawValue }!.resumePosition)
        }
    }
    @MainActor
    func testInvalidReferencesTransitionsAndDraftProtection() throws {
        let (root, _, context) = try fixture()
        let package = try ProgramImportService.revisionStarter(context: context)
        let preview = try ProgramImportService.preview(package, context: context)
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID())
        context.insert(adaptive); try context.save()
        XCTAssertTrue(try ProgramImportService.preview(package, context: context).blockedByDraft)
        XCTAssertThrowsError(try ProgramImportService.apply(preview, context: context, backupDirectory: root))
        XCTAssertEqual(adaptive.status, .draft)
        context.delete(adaptive); try context.save()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(package)) as? [String: Any])
        object["carry"] = []
        let missingCarry = try ProgramImportService.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ProgramImportService.preview(missingCarry, context: context))
        var definition = try XCTUnwrap(object["definition"] as? [String: Any])
        definition["clusters"] = []
        object["definition"] = definition
        XCTAssertThrowsError(try ProgramImportService.decode(JSONSerialization.data(withJSONObject: object)))
        let state = try XCTUnwrap(context.fetch(FetchDescriptor<ClusterRotationState>()).first { $0.programVersionID == Program.syncedArmsVersionID })
        state.positionIndex += 1; try context.save()
        XCTAssertThrowsError(try ProgramImportService.apply(preview, context: context, backupDirectory: root))
    }


    @MainActor
    func testChangedRotationLengthOrderAndSourceInvalidation() throws {
        let (root, _, context) = try fixture()
        let starter = try ProgramImportService.revisionStarter(context: context)
        let original = starter.definition.clusters[1]
        let extra = ClusterProgramDefinition.Step(templatePosition: 100, label: "Cluster 2 · Extra", slots: original.steps[0].slots)
        let changed = ClusterProgramDefinition.Cluster(id: original.id, steps: Array(original.steps.reversed()) + [extra])
        var clusters = starter.definition.clusters; clusters[1] = changed
        let d = starter.definition
        let definition = ClusterProgramDefinition(formatVersion: d.formatVersion, programVersionID: d.programVersionID, templateName: d.templateName, identityKey: d.identityKey, exercises: d.exercises, clusters: clusters)
        let mappings = starter.carry + extra.slots.indices.map { ProgramRevisionPackage.Carry(targetDay: 100, targetSlot: $0, sourceDay: original.steps[0].templatePosition, sourceSlot: $0) }
        let package = ProgramRevisionPackage(formatVersion: 1, sourceProgramVersionID: starter.sourceProgramVersionID, definition: definition, counters: starter.counters, carry: mappings)
        let preview = try ProgramImportService.preview(package, context: context)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let exercise = try XCTUnwrap(catalog.first)
        let notes = exercise.notes; exercise.notes += " Updated setup"; try context.save()
        XCTAssertThrowsError(try ProgramImportService.apply(preview, context: context, backupDirectory: root))
        exercise.notes = notes; try context.save()
        _ = try ProgramImportService.apply(ProgramImportService.preview(package, context: context), context: context, backupDirectory: root)
        let (template, cycle) = try active(context)
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        XCTAssertEqual(Program.rotationLength(.cluster2, version: definition.programVersionID, definition: ClusterProgramDefinition.embedded(in: template)), 9)
        for index in 0..<18 {
            let rows = try resolved(context, cluster: .cluster2, step: index)
            let expected = changed.steps[index % 9].slots
            XCTAssertEqual(rows.map(\.progressionKey), expected.map { $0.progression.resolve(exerciseID: definition.exercises[$0.exercise]!.resolve(in: catalog)!.id) })
            XCTAssertEqual(rows.map(\.exerciseId), expected.map { definition.exercises[$0.exercise]!.resolve(in: catalog)!.id })
        }
        let selection = try Program.selection(cluster: .cluster2, template: template, cycleInstanceId: cycle.id, states: states)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        context.insert(session)
        let slot = try XCTUnwrap(Program.resolvedSlots(selection: selection, sessionId: session.id, preferences: [], overrides: []).first)
        context.insert(SetEntry(sessionId: session.id, exerciseId: slot.exerciseId, setIndex: 1, weight: 10, reps: 10, isLocked: true))
        try context.save()
        try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context)
        let updated = try Program.selection(cluster: .cluster2, template: template, cycleInstanceId: cycle.id, states: states)
        XCTAssertEqual(updated.absoluteStep, selection.absoluteStep + 1)
        XCTAssertEqual(updated.day.position, changed.steps[updated.absoluteStep % 9].templatePosition)
    }


    @MainActor
    func testImportedRuleRetainsFutureSubstitutionIdentities() throws {
        let (root, _, context) = try fixture()
        let (source, cycle) = try active(context)
        let package = try ProgramImportService.revisionStarter(context: context)
        _ = try ProgramImportService.apply(ProgramImportService.preview(package, context: context), context: context, backupDirectory: root)
        let target = try active(context).0
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let oldStates = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: source.id, programVersionID: Program.syncedArmsVersionID)
        let newStates = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: target.id, programVersionID: package.definition.programVersionID)
        let session = UUID()
        for cluster in Program.Cluster.allCases {
            for step in 0..<Program.rotationLength(cluster, version: Program.syncedArmsVersionID) {
                oldStates.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
                newStates.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
                let old = try Program.selection(cluster: cluster, template: source, cycleInstanceId: cycle.id, states: oldStates)
                let new = try Program.selection(cluster: cluster, template: target, cycleInstanceId: cycle.id, states: newStates)
                for slot in old.day.slots {
                    for exercise in catalog where exercise.primaryMuscle == slot.muscle {
                        let previousOverride = ClusterExerciseOccurrenceOverride(sessionId: session, programVersionID: old.programVersionID, templateDayPosition: old.day.position, slotPosition: slot.position, exerciseId: exercise.id)
                        let futureOverride = ClusterExerciseOccurrenceOverride(sessionId: session, programVersionID: new.programVersionID, templateDayPosition: new.day.position, slotPosition: slot.position, exerciseId: exercise.id)
                        let previous = Program.resolvedSlots(selection: old, sessionId: session, preferences: [], overrides: [previousOverride]).first { $0.slot.position == slot.position }!
                        let future = Program.resolvedSlots(selection: new, sessionId: session, preferences: [], overrides: [futureOverride]).first { $0.slot.position == slot.position }!
                        XCTAssertEqual(future.progressionKey, previous.progressionKey, "\(cluster) \(step) \(exercise.name)")
                    }
                }
            }
        }
        XCTAssertFalse(context.hasChanges)
    }

    private func active(_ context: ModelContext) throws -> (CycleTemplate, ActiveCycleInstance) {
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first { cycle in templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) } })
        let template = try XCTUnwrap(templates.first { $0.id == cycle.templateId })
        return (template, cycle)
    }
    private func resolved(_ context: ModelContext, cluster: Program.Cluster, step: Int) throws -> [Program.ResolvedSlot] {
        let (template, cycle) = try active(context)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.versionID(for: template))
        states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
        return Program.resolvedSlots(selection: try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states), sessionId: UUID(), preferences: try context.fetch(FetchDescriptor<ClusterExercisePreference>()), overrides: [])
    }
    @MainActor
    func testImportedProgramCompletionExportRecoveryAndWrap() throws {
        let (root, store, context) = try fixture(); _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        // This independent export fixture starts with no fabricated completion gap.
        for state in try context.fetch(FetchDescriptor<ClusterRotationState>()) { state.positionIndex = 0 }
        try context.save()
        let package = try ProgramImportService.revisionStarter(context: context)
        _ = try ProgramImportService.apply(ProgramImportService.preview(package, context: context), context: context, backupDirectory: root)
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
            session.status = .draft
            try context.save()
            try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context)
            session.status = .completed
        }
        try context.save()
        let entries = try context.fetch(FetchDescriptor<SetEntry>())
        let occurrences = try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let metadata = SessionExportService.fixedCycleMetadata(session: session, template: template, day: template.days[0], exercises: catalog,
            setEntries: entries, readiness: [], overrides: [], clusterOccurrences: occurrences, clusterRotationStates: states)
        XCTAssertEqual(metadata.program_version, 9)
        XCTAssertNotNil(metadata.program_definition)
        XCTAssertFalse(metadata.program_catalog?.isEmpty ?? true)
        let rebuilt = SessionExportService.fixedCycleMetadata(session: session, template: template, day: template.days[0], exercises: catalog,
            setEntries: entries, readiness: [], overrides: [], clusterOccurrences: occurrences, clusterRotationStates: states)
        XCTAssertEqual(metadata, rebuilt, "Stable export snapshots must acknowledge identical imported payloads")
        var incomplete = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        incomplete["program_catalog"] = Array((incomplete["program_catalog"] as! [[String: Any]]).prefix(1))
        let incompleteMetadata = try JSONDecoder().decode(SessionExportService.FixedCycleMetadata.self, from: JSONSerialization.data(withJSONObject: incomplete))
        XCTAssertThrowsError(try SessionExportService.validateImportedDefinitionEvidence(incompleteMetadata))
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
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == "openlift.clustered-hypertrophy.v9" }.isEmpty,
            "Same-store recovery must not create redundant resettable overlays")
        let recoveredStore = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let recovered = ModelContext(recoveredStore)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let destination = try active(recovered).1
        _ = try BootstrapDataService.reconcileWorkoutExports([payload], cycle: destination, modelContext: recovered)
        let restored = try active(recovered).0
        XCTAssertEqual(Program.versionID(for: restored), "openlift.clustered-hypertrophy.v9")
        let recoveredCatalog = try recovered.fetch(FetchDescriptor<Exercise>())
        for cluster in Program.Cluster.allCases {
            for step in 0...Program.rotationLength(cluster, version: "openlift.clustered-hypertrophy.v9", definition: package.definition) {
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


    @MainActor
    func testCopiedPhoneStoreDraftGuardAndActivationPreserveHistory() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenLiftCopiedProgramImportStore/default.store")
        guard FileManager.default.fileExists(atPath: supplied.path) else { throw XCTSkip("Stage verified phone store in OpenLiftCopiedProgramImportStore") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProgramImportReal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: supplied, to: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let bookkeeping: Set<String> = ["ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING", "Z_PRIMARYKEY"]
        let before = try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }
        let store = try container(at: url); let context = ModelContext(store); context.autosaveEnabled = false
        let package = try ProgramImportService.revisionStarter(context: context)
        let bridge = root.appendingPathComponent("bridge")
        let now = Date().timeIntervalSince1970
        let blockedPreview = try bridgeRequest(.init(id: UUID(), action: "preview", expiresAt: now + 600, revision: JSONEncoder().encode(package)), root: bridge, context: context)
        XCTAssertEqual(blockedPreview.blockedByDraft, true)
        let blockedRequest = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: blockedPreview.previewID, approvalToken: blockedPreview.approvalToken, revisionSHA256: blockedPreview.revisionSHA256)
        XCTAssertEqual(try bridgeRequest(blockedRequest, root: bridge, context: context).status, "rejected")
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, before)
        let sessions = try context.fetch(FetchDescriptor<Session>())
        XCTAssertEqual(sessions.filter { $0.status == .completed }.count, 74)
        XCTAssertEqual(sessions.filter { $0.status == .draft }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 819)
        // Only this disposable fixture retires the draft to exercise activation. Never touch the phone.
        for draft in sessions where draft.status == .draft {
            for row in try context.fetch(FetchDescriptor<SetEntry>()) where row.sessionId == draft.id { context.delete(row) }
            context.delete(draft)
        }
        try context.save()
        let activationBaseline = try databaseRows(at: url)
        XCTAssertEqual(try XCTUnwrap(ProgramAgentBridge.process(id: blockedRequest.id, context: context, root: bridge)).status, "rejected")
        let ready = try bridgeRequest(.init(id: UUID(), action: "preview", expiresAt: now + 600, revision: JSONEncoder().encode(package)), root: bridge, context: context)
        let apply = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: ready.previewID, approvalToken: ready.approvalToken, revisionSHA256: ready.revisionSHA256)
        XCTAssertEqual(try bridgeRequest(apply, root: bridge, context: context).status, "applied")
        XCTAssertEqual(try XCTUnwrap(ProgramAgentBridge.process(id: apply.id, context: context, root: bridge)).status, "applied")
        let permitted: Set<String> = ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZROTATIONPOOL", "ZCLUSTERROTATIONSTATE", "ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE"]
        let after = try databaseRows(at: url)
        for (table, rows) in activationBaseline where !bookkeeping.contains(table) && !permitted.contains(table) {
            XCTAssertEqual(after[table], rows, table)
        }
        for table in ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZROTATIONPOOL", "ZCLUSTERROTATIONSTATE"] {
            XCTAssertTrue(Set(activationBaseline[table] ?? []).isSubset(of: Set(after[table] ?? [])), table)
        }
        let reopened = try container(at: url); let cold = ModelContext(reopened)
        XCTAssertEqual(Program.versionID(for: try active(cold).0), package.definition.programVersionID)
        XCTAssertEqual(try cold.fetchCount(FetchDescriptor<SetEntry>()), 804)
        XCTAssertEqual(try cold.fetch(FetchDescriptor<Session>()).filter { $0.status == .completed }.count, 74)
        XCTAssertEqual(try databaseRows(at: url).filter { !bookkeeping.contains($0.key) }, after.filter { !bookkeeping.contains($0.key) })
        print("PROGRAM_IMPORT_REAL_STORE: draft blocked unchanged; scratch activation preserved 74 completed sessions, 804 historical rows and all non-activation application fields")
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

extension ProgramImportTests {
    @MainActor
    private func bridgeRequest(_ request: ProgramAgentBridge.Request, root: URL, context: ModelContext,
                               now: Double = Date().timeIntervalSince1970) throws -> ProgramAgentBridge.Receipt {
        try ProgramAgentBridge.write(request, to: ProgramAgentBridge.path("inbox", request.id, root: root))
        return try XCTUnwrap(ProgramAgentBridge.process(id: request.id, context: context, root: root, now: now))
    }

    @MainActor
    func testAgentBridgePreviewApplyReceiptReplayAndCrashRecovery() throws {
        let (root, _, context) = try fixture()
        let bridge = root.appendingPathComponent("bridge")
        let now = Date().timeIntervalSince1970
        let starter = try bridgeRequest(.init(id: UUID(), action: "starter", expiresAt: now + 600), root: bridge, context: context)
        let revision = try JSONEncoder().encode(XCTUnwrap(starter.starter))
        let previewRequest = ProgramAgentBridge.Request(id: UUID(), action: "preview", expiresAt: now + 600, revision: revision)
        let preview = try bridgeRequest(previewRequest, root: bridge, context: context)
        XCTAssertEqual(preview.status, "previewed")
        XCTAssertEqual(preview.revisionSHA256, ProgramAgentBridge.hash(revision))
        let apply = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        try ProgramAgentBridge.write(apply, to: ProgramAgentBridge.path("inbox", apply.id, root: bridge))
        let oldSelection = UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
        // Persist the transaction, then interrupt before ProgramImportService
        // can update its UserDefaults selection cache or response file.
        XCTAssertThrowsError(try ProgramAgentBridge.process(id: apply.id, context: context, root: bridge, save: { context in
            try context.save()
            throw CocoaError(.fileWriteUnknown)
        }))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId"), oldSelection)
        let reopened = try container(at: root.appendingPathComponent("default.store"))
        let fresh = ModelContext(reopened)
        try ProgramAgentBridge.restoreCommittedSelectionCache(context: fresh)
        let receipt = try XCTUnwrap(ProgramAgentBridge.process(id: apply.id, context: fresh, root: bridge))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId"), receipt.appliedTemplateID?.uuidString)
        XCTAssertEqual(receipt.status, "applied")
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: URL(fileURLWithPath: try XCTUnwrap(receipt.backupPath))))
        let count = try fresh.fetchCount(FetchDescriptor<CycleTemplate>())
        let repeated = try XCTUnwrap(ProgramAgentBridge.process(id: apply.id, context: fresh, root: bridge, now: now + 9000))
        XCTAssertEqual(repeated.backupPath, receipt.backupPath)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CycleTemplate>()), count)
        var collision = apply; collision.approvalToken = "changed"
        try ProgramAgentBridge.write(collision, to: ProgramAgentBridge.path("inbox", apply.id, root: bridge))
        XCTAssertThrowsError(try ProgramAgentBridge.process(id: apply.id, context: fresh, root: bridge))
    }

    @MainActor
    func testAgentBridgeDraftStaleApprovalAndTerminalRejection() throws {
        let (root, _, context) = try fixture()
        let bridge = root.appendingPathComponent("bridge")
        let now = Date().timeIntervalSince1970
        let revision = try JSONEncoder().encode(ProgramImportService.revisionStarter(context: context))
        let preview = try bridgeRequest(.init(id: UUID(), action: "preview", expiresAt: now + 600, revision: revision), root: bridge, context: context)
        let draft = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        context.insert(draft); try context.save()
        let apply = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        let blocked = try bridgeRequest(apply, root: bridge, context: context)
        XCTAssertEqual(blocked.status, "rejected")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).first?.id, draft.id)
        context.delete(draft); try context.save()
        XCTAssertEqual(try XCTUnwrap(ProgramAgentBridge.process(id: apply.id, context: context, root: bridge)).status, "rejected")
        XCTAssertEqual(try ProgramImportService.revisionStarter(context: context).sourceProgramVersionID, Program.syncedArmsVersionID)
        var wrong = apply
        wrong = .init(id: UUID(), action: "apply", expiresAt: now + 600, previewID: preview.previewID, approvalToken: "bad", revisionSHA256: preview.revisionSHA256)
        XCTAssertEqual(try bridgeRequest(wrong, root: bridge, context: context).status, "rejected")
        let wrongDigest = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: "wrong")
        XCTAssertEqual(try bridgeRequest(wrongDigest, root: bridge, context: context).status, "rejected")
        let expired = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now - 1,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        XCTAssertEqual(try bridgeRequest(expired, root: bridge, context: context).status, "expired")
        let active = try XCTUnwrap(context.fetch(FetchDescriptor<ClusterRotationState>()).first { $0.programVersionID == Program.syncedArmsVersionID })
        active.positionIndex += 1; try context.save()
        let stale = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        XCTAssertEqual(try bridgeRequest(stale, root: bridge, context: context).status, "rejected")
    }

    @MainActor
    func testAgentBridgeRejectsMalformedPendingAndFailedSaveWithoutMutation() throws {
        let (root, _, context) = try fixture()
        let bridge = root.appendingPathComponent("bridge")
        let now = Date().timeIntervalSince1970
        let initial = try ProgramImportService.revisionStarter(context: context)
        let preview = try bridgeRequest(.init(id: UUID(), action: "preview", expiresAt: now + 600, revision: JSONEncoder().encode(initial)), root: bridge, context: context)
        let bad = try bridgeRequest(.init(id: UUID(), action: "preview", expiresAt: now + 600, revision: Data("{}".utf8)), root: bridge, context: context)
        XCTAssertEqual(bad.status, "rejected")
        let marker = TrainingPreference(key: "scratch-pending", modeRawValue: "pending")
        context.insert(marker)
        XCTAssertEqual(try bridgeRequest(.init(id: UUID(), action: "status", expiresAt: now + 600), root: bridge, context: context).status, "rejected")
        context.rollback()
        let apply = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        try ProgramAgentBridge.write(apply, to: ProgramAgentBridge.path("inbox", apply.id, root: bridge))
        var failedBackupRequest = apply
        failedBackupRequest = .init(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        try ProgramAgentBridge.write(failedBackupRequest, to: ProgramAgentBridge.path("inbox", failedBackupRequest.id, root: bridge))
        let backupFailed = try XCTUnwrap(ProgramAgentBridge.process(id: failedBackupRequest.id, context: context, root: bridge,
            snapshot: { _, _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(backupFailed.status, "rejected")
        XCTAssertEqual(try ProgramImportService.revisionStarter(context: context), initial)
        let failed = try XCTUnwrap(ProgramAgentBridge.process(id: apply.id, context: context, root: bridge, save: { _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(failed.status, "rejected")
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try ProgramImportService.revisionStarter(context: context), initial)
        XCTAssertFalse(try context.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key.hasPrefix(ProgramAgentBridge.markerPrefix) })
        let interrupted = ProgramAgentBridge.Request(id: UUID(), action: "apply", expiresAt: now + 600,
            previewID: preview.previewID, approvalToken: preview.approvalToken, revisionSHA256: preview.revisionSHA256)
        let interruptedURL = ProgramAgentBridge.path("inbox", interrupted.id, root: bridge)
        try ProgramAgentBridge.write(interrupted, to: interruptedURL)
        let intent = ProgramAgentBridge.Receipt(requestID: interrupted.id,
            requestSHA256: ProgramAgentBridge.hash(try Data(contentsOf: interruptedURL)), status: "interrupted", message: "intent")
        try ProgramAgentBridge.write(intent, to: ProgramAgentBridge.path("receipts", interrupted.id, root: bridge))
        XCTAssertEqual(try XCTUnwrap(ProgramAgentBridge.process(id: interrupted.id, context: context, root: bridge)).status, "rejected")
        XCTAssertEqual(try ProgramImportService.revisionStarter(context: context), initial)
        XCTAssertNil(try ProgramAgentBridge.process(id: UUID(), context: context, root: bridge))
        for value in ["openlift-agent://request/../test", "openlift-agent://request/" + UUID().uuidString.lowercased() + "?apply=1", "openlift-agent://apply/" + UUID().uuidString.lowercased()] {
            XCTAssertNil(ProgramAgentBridge.requestID(from: try XCTUnwrap(URL(string: value))))
        }
    }
}


extension ProgramImportTests {
    @MainActor
    func testPrepareIsolatedBridgeTransportFixture() throws {
        let (_, _, context) = try fixture()
        let cycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        let template = try XCTUnwrap(context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == cycle.templateId })
        context.insert(Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, cycleNameSnapshot: template.name, dayLabelSnapshot: "Transport fixture", createdAt: .now, finishedAt: .now, status: .completed, exportStatus: .success))
        try context.save()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftAgentTransportFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try StoreBackupService.snapshot(storeAt: context.container.configurations.first!.url, into: directory.appendingPathComponent("default.store"))
        print("AGENT_TRANSPORT_FIXTURE=" + directory.path)
    }
}
