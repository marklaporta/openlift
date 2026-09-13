import Foundation
import SwiftData
import SQLite3
import CryptoKit
import XCTest
@testable import OpenLift

final class SideDeltRevisionTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService
    private struct Fixture {
        let root: URL
        let store: ModelContainer
        let context: ModelContext
        var url: URL { root.appendingPathComponent("default.store") }
    }
    private func open(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("SideDelt", schema: schema, url: url, cloudKitDatabase: .none)])
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideDelt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try open(root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        _ = try BootstrapDataService.prepareSeptember2026ClusterRevision(modelContext: context, backupConfirmed: true)
        _ = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: context, backupConfirmed: true)
        let (template, cycle) = try active(context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        for step in 0..<6 {
            _ = try completeSession(context: context, template: template, cycle: cycle, exercises: exercises,
                timestamp: Double(1000 + step))
        }
        return Fixture(root: root, store: store, context: context)
    }
    private func active(_ context: ModelContext) throws -> (CycleTemplate, ActiveCycleInstance) {
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first {
            cycle in templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        })
        return (try XCTUnwrap(templates.first { $0.id == cycle.templateId }), cycle)
    }
    @discardableResult
    private func completeSession(context: ModelContext, template: CycleTemplate, cycle: ActiveCycleInstance,
                                 exercises: [Exercise], timestamp: Double, shrugRows: Int = 1,
                                 clusters: [Program.Cluster] = Program.Cluster.allCases) throws -> Session {
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        let preferences = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Clustered Workout", finishedAt: Date(timeIntervalSince1970: timestamp), status: .completed)
        context.insert(session)
        for selection in try Program.selections(template: template, cycleInstanceId: cycle.id, states: states) where clusters.contains(selection.cluster) {
            let resolved = Program.resolvedSlots(selection: selection, sessionId: session.id, preferences: preferences, overrides: [])
            let entries = resolved.flatMap { item in
                (1...(item.slot.muscle == .traps ? shrugRows : 2)).map {
                    SetEntry(sessionId: session.id, exerciseId: item.exerciseId, setIndex: $0,
                        weight: item.slot.muscle == .traps ? 45 : 20, reps: 15 - $0, isLocked: true)
                }
            }
            entries.forEach(context.insert)
            for item in resolved where exercises.first(where: { $0.id == item.exerciseId })?.equipment == .cable {
                context.insert(ExerciseResistanceProfile(workoutKind: .fixed, sessionId: session.id, exerciseId: item.exerciseId,
                    resistanceSource: .voltra, chainType: .inverseChains, chainPounds: 7, eccentricPounds: 3,
                    frozenAt: session.finishedAt, createdAt: session.finishedAt!, updatedAt: session.finishedAt!))
            }
            let occurrence = try Program.makeOccurrence(session: session, selection: selection, exercises: exercises,
                entries: entries, resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()),
                preferences: preferences, completedAt: session.finishedAt!)
            context.insert(occurrence)
            try Program.advanceCompletedCluster(selection: selection, occurrence: occurrence, states: states)
        }
        try context.save()
        return session
    }


    private func resolved(_ context: ModelContext, cluster: Program.Cluster = .cluster3, step: Int) throws -> [Program.ResolvedSlot] {
        let (template, cycle) = try active(context)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id,
            programVersionID: Program.versionID(for: template))
        states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
        let selection = try Program.selection(cluster: cluster, template: template, cycleInstanceId: cycle.id, states: states)
        return Program.resolvedSlots(selection: selection, sessionId: UUID(),
            preferences: try context.fetch(FetchDescriptor<ClusterExercisePreference>()), overrides: [])
    }
    private func effort(_ context: ModelContext, item: Program.ResolvedSlot) throws -> ExerciseEffortLookupResult? {
        let (_, cycle) = try active(context)
        return ExerciseEffortLookupService.fixedCycleEffort(exerciseId: item.exerciseId,
            cycleInstanceId: cycle.id, cycleDayIndex: 9, adaptiveSessions: [], adaptiveSetEntries: [],
            rotationSessions: try context.fetch(FetchDescriptor<Session>()),
            rotationSetEntries: try context.fetch(FetchDescriptor<SetEntry>()), progressionKey: item.progressionKey,
            progressionOccurrences: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()),
            resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()))
    }
    @MainActor
    private func verifyRevision(_ f: Fixture) throws {
        let before = try databaseRows(at: f.url)
        let (oldTemplate, cycle) = try active(f.context)
        let oldTemplateID = oldTemplate.id
        let oldCycleDay = cycle.currentDayIndex
        let oldStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.shrugVersionID }
        var oldSlots: [String: [Program.ResolvedSlot]] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength {
                oldSlots["\(cluster.rawValue)|\(step)"] = try resolved(f.context, cluster: cluster, step: step)
            }
        }
        let oldSuper = oldSlots["cluster-3|0"]![0]
        let oldCable = oldSlots["cluster-3|1"]![0]
        let oldSuperRows = try effort(f.context, item: oldSuper)?.rows
        let oldCableRows = try effort(f.context, item: oldCable)?.rows
        let result = try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("backups"))
        XCTAssertTrue(result.revision.didApply)
        XCTAssertEqual(result.revision.cycleId, cycle.id)
        XCTAssertEqual(cycle.currentDayIndex, oldCycleDay)
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: backup))
        XCTAssertEqual(try databaseRows(at: backup), before)
        let after = try databaseRows(at: f.url)
        // Only new catalog/template/overlay/state/marker rows and the active
        // template reference may change. Existing rows of append-only tables
        // (including archived pointers and templates) remain byte-for-byte.
        let appendOnly: Set<String> = ["ZEXERCISE", "ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT",
            "ZCLUSTERROTATIONSTATE", "ZCLUSTEREXERCISEPREFERENCE", "ZROTATIONPOOL"]
        let mutable: Set<String> = ["ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY",
            "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys {
            if appendOnly.contains(table) {
                XCTAssertTrue(Set(before[table]!).isSubset(of: Set(after[table] ?? [])), "Rewrote old \(table) rows")
            } else if !mutable.contains(table) {
                XCTAssertEqual(after[table], before[table], "Unexpected changes to \(table)")
            }
        }
        let (template, _) = try active(f.context)
        XCTAssertNotEqual(template.id, oldTemplateID)
        XCTAssertEqual(Program.versionID(for: template), Program.sideDeltVersionID)
        let newStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.sideDeltVersionID }
        for old in oldStates {
            let new = try XCTUnwrap(newStates.first { $0.clusterID == old.clusterID })
            XCTAssertEqual(new.positionIndex, old.positionIndex)
            XCTAssertEqual(new.lastCompletedOccurrenceID, old.lastCompletedOccurrenceID)
            XCTAssertEqual(new.updatedAt, old.updatedAt)
            XCTAssertEqual(new.isDerived, old.isDerived)
        }
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength {
                let new = try resolved(f.context, cluster: cluster, step: step)
                let old = oldSlots["\(cluster.rawValue)|\(step)"]!
                XCTAssertEqual(new.count, old.count)
                for index in old.indices where cluster != .cluster3 || index != 0 {
                    XCTAssertEqual(new[index].exerciseId, old[index].exerciseId)
                    XCTAssertEqual(new[index].progressionKey, old[index].progressionKey)
                    XCTAssertEqual(new[index].slot.defaultSetCount, old[index].slot.defaultSetCount)
                }
                if cluster == .cluster3 {
                    let item = new[0]
                    if step % 3 == 1 {
                        XCTAssertEqual(item.exerciseId, Program.sideDeltExerciseID)
                        XCTAssertEqual(item.progressionKey, Program.sideDeltProgressionKey)
                        XCTAssertEqual(item.slot.defaultSetCount, 2)
                        XCTAssertNil(try effort(f.context, item: item), "New movement must have no prior-performance cue")
                    } else {
                        let prior = step % 3 == 0 ? oldSuper : oldCable
                        XCTAssertEqual(item.exerciseId, prior.exerciseId)
                        XCTAssertEqual(item.progressionKey, prior.progressionKey)
                        let rows = try effort(f.context, item: item)?.rows
                        let beforeRows = step % 3 == 0 ? oldSuperRows : oldCableRows
                        XCTAssertEqual(rows?.map(\.weight), beforeRows?.map(\.weight))
                        XCTAssertEqual(rows?.map(\.reps), beforeRows?.map(\.reps))
                    }
                }
            }
        }
        let repeated = try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Repeat activation must not create another snapshot") })
        XCTAssertFalse(repeated.revision.didApply)
        XCTAssertEqual(try databaseRows(at: f.url), after)
        // Consolidate, then open a different container without any activation.
        let reopenedURL = f.root.appendingPathComponent("cold-reopen.store")
        try StoreBackupService.snapshot(storeAt: f.url, into: reopenedURL)
        let reopenedStore = try open(reopenedURL)
        let reopened = ModelContext(reopenedStore)
        XCTAssertEqual(try BootstrapDataService.sideDeltRevisionAudit(modelContext: reopened),
            try BootstrapDataService.sideDeltRevisionAudit(modelContext: f.context))
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength {
                let fresh = try resolved(reopened, cluster: cluster, step: step)
                let current = try resolved(f.context, cluster: cluster, step: step)
                XCTAssertEqual(fresh.map(\.exerciseId), current.map(\.exerciseId))
                XCTAssertEqual(fresh.map(\.progressionKey), current.map(\.progressionKey))
            }
        }
        XCTAssertFalse(try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: reopened,
            snapshot: { _, _ in XCTFail("Cold reopen must retain activation marker") }).revision.didApply)
    }

    @MainActor
    func testPreservesHistoriesProfilesKeysAndIndependentPointersThroughColdReopen() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("swap-backups"))
        try verifyRevision(f)
    }

    @MainActor
    func testConsistentShoulderPreferencesFollowIdentityAndConflictingPreferencesFailClosed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let exercise = try XCTUnwrap(f.context.fetch(FetchDescriptor<Exercise>()).first { $0.name == "Dumbbell Lateral Raise" })
        f.context.insert(ClusterExercisePreference(programVersionID: Program.shrugVersionID,
            templateDayPosition: 9, slotPosition: 0, exerciseId: exercise.id))
        try f.context.save()
        let before = try databaseRows(at: f.url)
        XCTAssertThrowsError(try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true))
        XCTAssertEqual(try databaseRows(at: f.url), before)
        for position in [11, 13] {
            f.context.insert(ClusterExercisePreference(programVersionID: Program.shrugVersionID,
                templateDayPosition: position, slotPosition: 0, exerciseId: exercise.id))
        }
        try f.context.save()
        try verifyRevision(f)
        let carried = try f.context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.sideDeltVersionID }
        XCTAssertEqual(Set(carried.map(\.templateDayPosition)), [9, 12])
        XCTAssertEqual(Set(carried.map(\.exerciseId)), [exercise.id])
    }

    @MainActor
    func testBackupFailurePendingEditsAndDraftsCannotApply() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try databaseRows(at: f.url)
        XCTAssertThrowsError(try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context))
        enum Injected: Error { case failed }
        for snapshot: (URL, URL) throws -> Void in [
            { _, _ in throw Injected.failed }, { _, target in try Data("invalid".utf8).write(to: target) }
        ] {
            XCTAssertThrowsError(try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
                backupDirectory: f.root.appendingPathComponent("backups"), snapshot: snapshot))
            XCTAssertEqual(try databaseRows(at: f.url), before)
        }
        let (_, cycle) = try active(f.context)
        cycle.currentDayIndex = 55
        XCTAssertThrowsError(try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Pending writes must not reach backup") }))
        XCTAssertTrue(f.context.hasChanges)
        XCTAssertEqual(cycle.currentDayIndex, 55)
        f.context.rollback()
        let draft = Session(cycleInstanceId: cycle.id, cycleDayIndex: 9, status: .draft)
        f.context.insert(draft)
        try f.context.save()
        let withDraft = try databaseRows(at: f.url)
        XCTAssertThrowsError(try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Draft must not reach backup") }))
        XCTAssertEqual(try databaseRows(at: f.url), withDraft)
    }

    @MainActor
    func testCatalogBootstrapPreservesNewExerciseIdentityAndUserEditedSetupNotes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let exercise = try XCTUnwrap(f.context.fetch(FetchDescriptor<Exercise>()).first { $0.id == Program.sideDeltExerciseID })
        exercise.notes = "My preferred bench setting"
        exercise.name = "Side-lying lateral raise"
        try f.context.save()
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: f.context)
        XCTAssertEqual(catalog.filter { $0.id == exercise.id }.count, 1)
        XCTAssertEqual(exercise.notes, "My preferred bench setting")
        XCTAssertEqual(exercise.name, "Side-lying lateral raise")
        XCTAssertFalse(catalog.contains { $0.name == Program.sideDeltExerciseName })
        let template = try Program.makeTemplate(exercises: catalog, thirdSideDelt: true)
        XCTAssertEqual(template.days.first { $0.position == 10 }?.slots.first { $0.position == 0 }?.exerciseId, exercise.id)
        XCTAssertTrue(try BootstrapDataService.applySideDeltRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("backups")).revision.didApply)
        XCTAssertEqual(exercise.notes, "My preferred bench setting")
        XCTAssertEqual(exercise.name, "Side-lying lateral raise")
    }

    @MainActor
    func testCopiedRealStoreSideDeltRevisionWhenOptedIn() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let supplied = documents.appendingPathComponent("OpenLiftCopiedSideDeltStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Stage a verified v3 copy in Documents/OpenLiftCopiedSideDeltStore")
        }
        func hashes() throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: supplied,
                includingPropertiesForKeys: nil).map { ($0.lastPathComponent,
                    SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined()) })
        }
        let beforeHashes = try hashes()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideDeltRealCopy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: supplied, to: root)
        let store = try open(root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 67)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 7)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 686)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 78)
        let oldStates = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.shrugVersionID }
        XCTAssertEqual(oldStates.sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex), [19, 19, 18])
        try verifyRevision(Fixture(root: root, store: store, context: context))
        XCTAssertEqual(try hashes(), beforeHashes)
        print("OPENLIFT_COPIED_SIDE_DELT_VERIFIED historyPreserved=true pointersPreserved=true freshBackup=true coldReopen=true sourceHashesUnchanged=true")
    }
    func testV4ExportHydrationRetainsAllThreeShoulderIdentitiesAndOlderHistory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (_, sourceCycle) = try active(f.context)
        let sourceExercises = try f.context.fetch(FetchDescriptor<Exercise>())
        let result = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        let template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == result.templateId })
        _ = try completeSession(context: f.context, template: template, cycle: sourceCycle, exercises: sourceExercises, timestamp: 3_000)
        _ = try completeSession(context: f.context, template: template, cycle: sourceCycle, exercises: sourceExercises, timestamp: 4_000)
        let occurrences = try f.context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let states = try f.context.fetch(FetchDescriptor<ClusterRotationState>())
        let preferences = try f.context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let entries = try f.context.fetch(FetchDescriptor<SetEntry>())
        let templates = try f.context.fetch(FetchDescriptor<CycleTemplate>())
        let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ShrugExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let environment = SessionExportService.ExportEnvironment(containerIdentifier: nil, iCloudContainerURL: nil,
            localDocumentsURL: exportRoot, coordinatedWrite: { data, url in try data.write(to: url, options: .atomic) },
            ubiquityMetadata: { _ in SessionExportService.UbiquityMetadata(isUbiquitousItem: false,
                isUploaded: false, isUploading: false, uploadingErrorDescription: nil) })
        let exports = try f.context.fetch(FetchDescriptor<Session>()).map { session in
            let owner = templates.first { $0.id == occurrences.first { $0.sessionId == session.id }!.templateId }!
            let metadata = SessionExportService.fixedCycleMetadata(session: session, template: owner, day: owner.days[0],
                exercises: sourceExercises, setEntries: entries, readiness: [], overrides: [],
                clusterOccurrences: occurrences, clusterRotationStates: states, clusterExercisePreferences: preferences)
            let written = try SessionExportService.export(session: session, cycleName: owner.name, exercises: sourceExercises,
                setEntries: entries.filter { $0.sessionId == session.id }, fixedCycleMetadata: metadata, environment: environment)
            return try JSONDecoder().decode(SessionExportService.ExportPayload.self,
                from: Data(contentsOf: XCTUnwrap(written.localMirrorURL)))
        }
        XCTAssertEqual(Set(exports.compactMap { $0.fixed_cycle?.program_version }), [3, 4])
        let encoded = try JSONEncoder().encode(exports)
        let roundTripped = try JSONDecoder().decode([SessionExportService.ExportPayload].self, from: encoded)
        let destination = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let recovered = ModelContext(destination)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let cycle = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped, cycle: cycle, modelContext: recovered)
        let recoveredTemplates = try recovered.fetch(FetchDescriptor<CycleTemplate>())
        let active = try XCTUnwrap(recoveredTemplates.first { $0.id == cycle.templateId })
        XCTAssertEqual(Program.versionID(for: active), Program.sideDeltVersionID)
        XCTAssertEqual(Set(recoveredTemplates.map { Program.versionNumber(for: $0) }), [1, 3, 4])
        let restoredStates = try recovered.fetch(FetchDescriptor<ClusterRotationState>())
        XCTAssertEqual(try Program.selections(template: active, cycleInstanceId: cycle.id, states: restoredStates).map(\.absoluteStep), [8, 8, 8])
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<SetEntry>()).count, entries.count)
        let restored = try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        XCTAssertEqual(restored.count, occurrences.count)
        for original in occurrences {
            let copy = try XCTUnwrap(restored.first { $0.sessionId == original.sessionId && $0.clusterID == original.clusterID })
            XCTAssertEqual(copy.programVersionID, original.programVersionID)
            XCTAssertEqual(copy.exerciseSnapshots.map(\.progressionKey), original.exerciseSnapshots.map(\.progressionKey))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.exerciseName), original.exerciseSnapshots.map(\.exerciseName))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.prescribedSetCount), original.exerciseSnapshots.map(\.prescribedSetCount))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.resistanceProfile), original.exerciseSnapshots.map(\.resistanceProfile))
        }
        let recoveredProfile = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first { $0.chainPounds == 7 })
        XCTAssertEqual(recoveredProfile.eccentricPounds, 3)
        let count = restored.count
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped.filter { $0.fixed_cycle?.program_version == 3 }, cycle: cycle, modelContext: recovered)
        XCTAssertEqual(cycle.templateId, active.id, "Older exports must not downgrade the active program")
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).count, count)
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
