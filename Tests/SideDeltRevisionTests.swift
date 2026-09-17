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

    @MainActor
    func testChestBackExportHydrationPreservesFourStepProgramAndHistory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (_, sourceCycle) = try active(f.context)
        _ = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        for (index, item) in Program.recoveryMovements.enumerated() {
            f.context.insert(Exercise(id: item.0, name: item.1, primaryMuscle: index % 2 == 0 ? .chest : .back,
                type: index % 2 == 0 ? .isolation : .compound, equipment: index < 2 ? .cable : .dumbbell))
        }
        try f.context.save()
        let sourceExercises = try f.context.fetch(FetchDescriptor<Exercise>())
        let result = try BootstrapDataService.prepareChestBackRevision(modelContext: f.context, backupConfirmed: true)
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
        XCTAssertEqual(Set(exports.compactMap { $0.fixed_cycle?.program_version }), [3, 6])
        let encoded = try JSONEncoder().encode(exports)
        let roundTripped = try JSONDecoder().decode([SessionExportService.ExportPayload].self, from: encoded)
        let destination = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let recovered = ModelContext(destination)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let cycle = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped, cycle: cycle, modelContext: recovered)
        let recoveredTemplates = try recovered.fetch(FetchDescriptor<CycleTemplate>())
        let active = try XCTUnwrap(recoveredTemplates.first { $0.id == cycle.templateId })
        XCTAssertEqual(Program.versionID(for: active), Program.chestBackVersionID)
        XCTAssertEqual(Set(recoveredTemplates.map { Program.versionNumber(for: $0) }), [1, 3, 6])
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

    @MainActor
    private func verifyPermanentOrder(_ f: Fixture) throws {
        let before = try databaseRows(at: f.url)
        let (oldTemplate, cycle) = try active(f.context)
        XCTAssertEqual(Program.versionID(for: oldTemplate), Program.sideDeltVersionID)
        let oldCycleDay = cycle.currentDayIndex
        let oldStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.sideDeltVersionID }
        var prior: [String: [Program.ResolvedSlot]] = [:]
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength { prior["\(cluster.rawValue)|\(step)"] = try resolved(f.context, cluster: cluster, step: step) }
        }
        let applied = try BootstrapDataService.applySideDeltOrderWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("order-backups"))
        XCTAssertTrue(applied.revision.didApply)
        XCTAssertEqual(applied.revision.cycleId, cycle.id)
        XCTAssertEqual(cycle.currentDayIndex, oldCycleDay)
        XCTAssertEqual(try databaseRows(at: XCTUnwrap(applied.backupURL)), before)
        let after = try databaseRows(at: f.url)
        let appendOnly: Set<String> = ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZCLUSTERROTATIONSTATE", "ZCLUSTEREXERCISEPREFERENCE", "ZROTATIONPOOL"]
        let mutable: Set<String> = ["ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys {
            if appendOnly.contains(table) { XCTAssertTrue(Set(before[table]!).isSubset(of: Set(after[table] ?? [])), "Rewrote old \(table)") }
            else if !mutable.contains(table) { XCTAssertEqual(after[table], before[table], "Changed \(table)") }
        }
        let (template, _) = try active(f.context)
        XCTAssertEqual(Program.versionID(for: template), Program.sideDeltOrderVersionID)
        let newStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.sideDeltOrderVersionID }
        for old in oldStates {
            let new = try XCTUnwrap(newStates.first { $0.clusterID == old.clusterID })
            XCTAssertEqual(new.positionIndex, old.positionIndex)
            XCTAssertEqual(new.lastCompletedOccurrenceID, old.lastCompletedOccurrenceID)
            XCTAssertEqual(new.updatedAt, old.updatedAt)
            XCTAssertEqual(new.isDerived, old.isDerived)
        }
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength {
                let current = try resolved(f.context, cluster: cluster, step: step)
                for index in current.indices {
                    let sourceStep = cluster == .cluster3 && index == 0 ? [1, 0, 2, 4, 3, 5][step] : step
                    let old = prior["\(cluster.rawValue)|\(sourceStep)"]![index]
                    let new = current[index]
                    XCTAssertEqual(new.exerciseId, old.exerciseId)
                    XCTAssertEqual(new.progressionKey, old.progressionKey)
                    XCTAssertEqual(new.slot.defaultSetCount, old.slot.defaultSetCount)
                    // Lookup must return the identical same-exercise evidence.
                    let oldEffort = try effort(f.context, item: old)
                    let newEffort = try effort(f.context, item: new)
                    XCTAssertEqual(newEffort?.rows.map(\.weight), oldEffort?.rows.map(\.weight))
                    XCTAssertEqual(newEffort?.rows.map(\.reps), oldEffort?.rows.map(\.reps))
                    if new.exerciseId == Program.sideDeltExerciseID {
                        XCTAssertEqual(new.progressionKey, Program.sideDeltProgressionKey)
                        XCTAssertEqual(new.slot.defaultSetCount, 2)
                        XCTAssertNil(newEffort)
                    }
                }
            }
        }
        XCTAssertFalse(try BootstrapDataService.applySideDeltOrderWithFreshBackup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Repeat must not create a backup") }).revision.didApply)
        XCTAssertEqual(try databaseRows(at: f.url), after)
        let reopenedURL = f.root.appendingPathComponent("order-cold.store")
        try StoreBackupService.snapshot(storeAt: f.url, into: reopenedURL)
        let reopenedStore = try open(reopenedURL)
        let reopened = ModelContext(reopenedStore)
        XCTAssertEqual(try BootstrapDataService.sideDeltRevisionAudit(modelContext: reopened),
            try BootstrapDataService.sideDeltRevisionAudit(modelContext: f.context))
        for step in 0..<6 {
            XCTAssertEqual(try resolved(reopened, step: step).map(\.progressionKey), try resolved(f.context, step: step).map(\.progressionKey))
        }
        XCTAssertFalse(try BootstrapDataService.applySideDeltOrderWithFreshBackup(modelContext: reopened,
            snapshot: { _, _ in XCTFail("Cold repeat must not create a backup") }).revision.didApply)
    }

    @MainActor
    func testPermanentOrderPreservesAllOtherSlotsHistoryAndKeys() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("swap-backups"))
        _ = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        try verifyPermanentOrder(f)
    }

    @MainActor
    func testPermanentOrderCarriesExactShoulderPreferencesAndFallbackDose() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        let (template, _) = try active(f.context)
        let replacement = try XCTUnwrap(f.context.fetch(FetchDescriptor<Exercise>()).first { $0.name == "Dumbbell Lateral Raise" })
        for position in [9, 12] {
            template.days.first { $0.position == position }?.slots.first { $0.position == 0 }?.defaultSetCount = position == 9 ? 1 : 4
            f.context.insert(ClusterExercisePreference(programVersionID: Program.sideDeltVersionID,
                templateDayPosition: position, slotPosition: 0, exerciseId: replacement.id))
        }
        try f.context.save()
        try verifyPermanentOrder(f)
    }

    @MainActor
    func testCopiedRealStorePermanentOrderWhenOptedIn() throws {
        let supplied = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftCopiedSideDeltOrderStore")
        let source = supplied.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Stage verified v4 copy in Documents/OpenLiftCopiedSideDeltOrderStore") }
        let hash = SHA256.hash(data: try Data(contentsOf: source))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideDeltOrderReal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: supplied, to: root)
        let store = try open(root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 67)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 7)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 686)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 78)
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.sideDeltVersionID }
        XCTAssertEqual(states.sorted { $0.clusterID < $1.clusterID }.map(\.positionIndex), [19, 19, 18])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.sideDeltVersionID }.count, 5)
        try verifyPermanentOrder(Fixture(root: root, store: store, context: context))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), hash)
        print("OPENLIFT_COPIED_SIDE_DELT_ORDER_VERIFIED historyPreserved=true pointersPreserved=true freshBackup=true coldReopen=true sourceHashUnchanged=true")
    }

    /// Logical rows from every table, including relationship and metadata tables.
    /// Read-only SQLite observes committed WAL state without opening the source in SwiftData.

    @MainActor
    func testChestBackRevisionBackupDraftAndInitialDoseGuards() throws {
        let f = try fixture()
        _ = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        for (index, item) in Program.recoveryMovements.enumerated() {
            f.context.insert(Exercise(id: item.0, name: item.1, primaryMuscle: index % 2 == 0 ? .chest : .back,
                type: index % 2 == 0 ? .isolation : .compound, equipment: index < 2 ? .cable : .dumbbell))
        }
        try f.context.save()
        let before = try databaseRows(at: f.url)
        XCTAssertThrowsError(try BootstrapDataService.prepareChestBackRevision(modelContext: f.context))
        XCTAssertEqual(try databaseRows(at: f.url), before)
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("failed"), snapshot: { _, _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(try databaseRows(at: f.url), before)
        let (_, cycle) = try active(f.context)
        let draft = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, status: .draft)
        f.context.insert(draft)
        try f.context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context))
        XCTAssertEqual(draft.status, .draft)
        f.context.delete(draft)
        try f.context.save()
        let adaptiveDraft = AdaptiveWorkoutSession(generatedPlanId: UUID())
        f.context.insert(adaptiveDraft)
        try f.context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context))
        XCTAssertEqual(adaptiveDraft.status, .draft)
        f.context.delete(adaptiveDraft)
        try f.context.save()
        let pending = TrainingPreference(key: "pending-test", modeRawValue: "unchanged")
        f.context.insert(pending)
        XCTAssertThrowsError(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context))
        f.context.rollback()
        try verifyChestBackRevision(f)
        let (template, activeCycle) = try active(f.context)
        let states = try f.context.fetch(FetchDescriptor<ClusterRotationState>())
        let selection = try Program.selection(cluster: .cluster1, template: template, cycleInstanceId: activeCycle.id, states: states)
        let item = Program.resolvedSlots(selection: selection, sessionId: UUID(), preferences: [], overrides: [])[0]
        let session = Session(cycleInstanceId: activeCycle.id, cycleDayIndex: 0, finishedAt: .now, status: .completed)
        f.context.insert(session)
        let manual = (1...3).map { SetEntry(sessionId: session.id, exerciseId: item.exerciseId,
            setIndex: $0, weight: 25, reps: 12, isLocked: true) }
        manual.forEach(f.context.insert)
        let occurrence = try Program.makeOccurrence(session: session, selection: selection,
            exercises: f.context.fetch(FetchDescriptor<Exercise>()), entries: manual, resistanceProfiles: [])
        f.context.insert(occurrence)
        try f.context.save()
        let prior = try XCTUnwrap(effort(f.context, item: item))
        XCTAssertEqual(prior.rows.count, 3)
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: prior,
            selection: selection, exerciseId: item.exerciseId, progressionKey: item.progressionKey, occurrences: [occurrence]), 3,
            "An explicit later v6 three-set choice must carry forward normally")
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: prior,
            selection: selection, exerciseId: item.exerciseId, progressionKey: item.progressionKey, occurrences: []), 2)
        XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: prior), 3,
            "No global cap outside this revision")
    }

    @MainActor
    func testChestBackCopiedRealStore() throws {
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftCopiedChestBackStore/default.store")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Stage verified phone copy in Documents/OpenLiftCopiedChestBackStore") }
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChestBackReal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("default.store"))
        let store = try open(root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 72)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 767)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 7)
        try verifyChestBackRevision(Fixture(root: root, store: store, context: context))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), before)
        print("OPENLIFT_CHEST_BACK_COPY_VERIFIED history=true overlays=true rawPointers=true dose=true freshBackup=true noOp=true coldReopen=true")
    }

    @MainActor
    private func verifyChestBackRevision(_ f: Fixture) throws {
        let before = try databaseRows(at: f.url)
        let (old, cycle) = try active(f.context)
        let oldStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.templateId == old.id }
        let preferences = try f.context.fetch(FetchDescriptor<ClusterExercisePreference>())
        var other: [String: [Program.ResolvedSlot]] = [:]
        for cluster in [Program.Cluster.cluster2, .cluster3] {
            for step in 0..<6 { other["\(cluster.rawValue)|\(step)"] = try resolved(f.context, cluster: cluster, step: step) }
        }
        let previousRow = try resolved(f.context, cluster: .cluster1, step: 1)[1]
        let result = try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: f.root.appendingPathComponent("backups"))
        XCTAssertTrue(result.revision.didApply)
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try databaseRows(at: backup), before)
        let after = try databaseRows(at: f.url)
        let appendOnly: Set<String> = ["ZCYCLETEMPLATE", "ZCYCLEDAY", "ZCYCLESLOT", "ZCLUSTERROTATIONSTATE", "ZCLUSTEREXERCISEPREFERENCE", "ZROTATIONPOOL"]
        let mutable: Set<String> = ["ZACTIVECYCLEINSTANCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys {
            if appendOnly.contains(table) { XCTAssertTrue(Set(before[table]!).isSubset(of: Set(after[table] ?? [])), table) }
            else if !mutable.contains(table) { XCTAssertEqual(after[table], before[table], table) }
        }
        let (template, _) = try active(f.context)
        XCTAssertEqual(Program.versionID(for: template), Program.chestBackVersionID)
        for cluster in [Program.Cluster.cluster2, .cluster3] {
            for step in 0..<6 {
                let slots = try resolved(f.context, cluster: cluster, step: step)
                let expected = other["\(cluster.rawValue)|\(step)"]!
                XCTAssertEqual(slots.map(\.exerciseId), expected.map(\.exerciseId))
                XCTAssertEqual(slots.map(\.progressionKey), expected.map(\.progressionKey))
                XCTAssertEqual(slots.map { $0.slot.defaultSetCount }, expected.map { $0.slot.defaultSetCount })
            }
        }
        let row = try resolved(f.context, cluster: .cluster1, step: 1)[1]
        XCTAssertEqual(row.exerciseId, previousRow.exerciseId)
        XCTAssertEqual(row.progressionKey, previousRow.progressionKey)
        let newStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.templateId == template.id }
        for oldState in oldStates {
            let new = try XCTUnwrap(newStates.first { $0.clusterID == oldState.clusterID })
            XCTAssertEqual(new.positionIndex, oldState.positionIndex)
            XCTAssertEqual(new.lastCompletedOccurrenceID, oldState.lastCompletedOccurrenceID)
        }
        for step in 0..<4 {
            let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.chestBackVersionID)
            states.first { $0.clusterID == "cluster-1" }!.positionIndex = 24 + step
            let selection = try Program.selection(cluster: .cluster1, template: template, cycleInstanceId: cycle.id, states: states)
            XCTAssertEqual(selection.effectiveStep, step)
            let items = Program.resolvedSlots(selection: selection, sessionId: UUID(), preferences: try f.context.fetch(FetchDescriptor<ClusterExercisePreference>()), overrides: [])
            for item in items {
                XCTAssertEqual(item.slot.defaultSetCount, 2)
                let prior = try effort(f.context, item: item)
                XCTAssertEqual(FixedCycleWorkoutService.draftSetCount(defaultSetCount: 2, effort: prior,
                    selection: selection, exerciseId: item.exerciseId, progressionKey: item.progressionKey,
                    occurrences: try f.context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())), 2)
                print("CHEST_BACK_PREFILL step=\(step) id=\(item.exerciseId) key=\(item.progressionKey) rows=\(prior?.rows.count ?? 0)")
            }
        }
        XCTAssertEqual(try resolved(f.context, cluster: .cluster1, step: 1)[0].exerciseId, Program.recoveryMovements[0].0)
        XCTAssertEqual(try resolved(f.context, cluster: .cluster1, step: 2)[1].exerciseId, Program.singleArmPulldownID)
        XCTAssertEqual(try resolved(f.context, cluster: .cluster1, step: 3).map(\.exerciseId), [Program.recoveryMovements[2].0, Program.recoveryMovements[3].0])
        XCTAssertFalse(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: f.context,
            snapshot: { _, _ in XCTFail("Repeat activation must not snapshot") }).revision.didApply)
        XCTAssertEqual(try databaseRows(at: f.url), after)
        let reopenedStore = try open(f.url)
        let reopened = ModelContext(reopenedStore)
        let (reopenedTemplate, _) = try active(reopened)
        XCTAssertEqual(reopenedTemplate.id, template.id)
        XCTAssertFalse(try BootstrapDataService.applyChestBackRevisionWithFreshBackup(modelContext: reopened).revision.didApply)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<ClusterExercisePreference>()), preferences.count + preferences.filter { $0.programVersionID == Program.sideDeltVersionID && $0.templateDayPosition != 2 }.count)
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

extension SideDeltRevisionTests {
    @MainActor
    func testCSDBRowCopiedStoreConsolidationGuardsAliasesHistoryAndColdReopen() throws {
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLiftCopiedCSDBRowStore/default.store")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Stage verified phone copy in Documents/OpenLiftCopiedCSDBRowStore") }
        let sourceHash = SHA256.hash(data: try Data(contentsOf: source))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CSDBRow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: source, to: url)
        let store = try open(url)
        let context = ModelContext(store)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let canonical = try XCTUnwrap(catalog.first { $0.id == CSDBRowIdentity.canonicalID })
        let before = try databaseRows(at: url)
        XCTAssertEqual(catalog.count, 77)
        canonical.notes += "pending"
        XCTAssertThrowsError(try BootstrapDataService.consolidateCSDBRow(modelContext: context))
        context.rollback()
        let draft = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        context.insert(draft); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.consolidateCSDBRow(modelContext: context))
        context.delete(draft); try context.save()
        XCTAssertThrowsError(try BootstrapDataService.consolidateCSDBRow(modelContext: context, backupDirectory: root,
            snapshot: { _, _ in throw NSError(domain: "test-backup", code: 1) }))
        XCTAssertEqual(canonical.name, "Chest-Supported Dumbbell Row")
        let result = try BootstrapDataService.consolidateCSDBRow(modelContext: context, backupDirectory: root)
        XCTAssertTrue(result.didApply)
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: try XCTUnwrap(result.backupURL)))
        let after = try databaseRows(at: url)
        let mutable: Set<String> = ["ZEXERCISE", "ZCYCLESLOT", "ZROTATIONPOOLENTRY", "ZCLUSTEREXERCISEPREFERENCE", "ZADAPTIVECOMPLEXCOMPONENT", "ZADAPTIVEEXERCISESELECTIONPREFERENCE", "ZTRAININGPREFERENCE", "Z_PRIMARYKEY", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"]
        for table in before.keys where !mutable.contains(table) { XCTAssertEqual(before[table], after[table], table) }
        XCTAssertEqual(canonical.name, "CS DB Row")
        XCTAssertEqual(canonical.equipment, .dumbbell)
        XCTAssertTrue(canonical.notes.contains("Rogue multi-use lat seat"))
        XCTAssertTrue(canonical.notes.contains("Helms Row"))
        XCTAssertEqual(catalog.filter { $0.isActive && CSDBRowIdentity.matches($0.name) }.map(\.id), [canonical.id])
        XCTAssertEqual(catalog.filter { CSDBRowIdentity.legacyIDs.contains($0.id) }.filter(\.isActive).count, 0)
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let entries = try context.fetch(FetchDescriptor<SetEntry>())
        let adaptive = try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        let adaptiveEntries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        func history(_ query: String) -> [HistoryExerciseOccurrence] {
            HistoryExerciseSearchService.results(query: query, sessions: sessions, setEntries: entries,
                adaptiveSessions: adaptive, adaptiveSetEntries: adaptiveEntries, exercises: catalog)
        }
        XCTAssertEqual(history("CS DB Row").count, 9)
        XCTAssertEqual(history("CS DB Row").flatMap(\.sets).count, 18)
        XCTAssertEqual(history("Helms Row"), history("CS DB Row"))
        XCTAssertTrue(history("CS DB Row").allSatisfy { $0.exerciseName == "CS DB Row" })
        let expectedLatest = try XCTUnwrap(history("CS DB Row").first)
        let effort = try XCTUnwrap(ExerciseEffortLookupService.globalEffort(exerciseId: canonical.id,
            adaptiveSessions: adaptive, adaptiveSetEntries: adaptiveEntries, rotationSessions: sessions,
            rotationSetEntries: entries, resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()), exercises: catalog))
        XCTAssertEqual(effort.completedAt, expectedLatest.date)
        XCTAssertEqual(effort.rows.map(\.weight), expectedLatest.sets.map(\.weight))
        let template = try active(context).0
        XCTAssertEqual(Program.versionID(for: template), Program.chestBackVersionID)
        XCTAssertEqual(try resolved(context, cluster: .cluster1, step: 3)[1].exerciseId, canonical.id)
        XCTAssertEqual(try resolved(context, cluster: .cluster1, step: 3)[1].slot.defaultSetCount, 2)
        XCTAssertEqual(try resolved(context, cluster: .cluster1, step: 3)[1].progressionKey, Program.chestBackProgressionKey(step: 3, slotPosition: 1))
        for name in CSDBRowIdentity.names {
            XCTAssertThrowsError(try ExerciseCatalogService.makeExercise(name: name, primaryMuscle: .back, type: .compound, equipment: .dumbbell, existingExercises: catalog))
            let doc = root.appendingPathComponent("alias.json")
            try "{\"name\":\"alias\",\"days\":[{\"label\":\"A\",\"slots\":[{\"muscle\":\"back\",\"exerciseName\":\"\(name)\",\"defaultSetCount\":2}]}]}".write(to: doc, atomically: true, encoding: .utf8)
            XCTAssertEqual(try PublishedCycleService.parseTemplate(at: doc, exercises: catalog).days[0].slots[0].exerciseId, canonical.id)
        }
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0) })
        for id in CSDBRowIdentity.legacyIDs {
            // Historical ID imports preserve frozen snapshots; future template imports canonicalize.
            XCTAssertEqual(BootstrapDataService.resolveImportedExercise(id: id, name: "Helms Row", byId: byID, byName: byName)?.id, id)
            XCTAssertEqual(CSDBRowIdentity.resolve(id: id, name: nil, exercises: catalog)?.id, canonical.id)
        }
        XCTAssertEqual(BootstrapDataService.resolveImportedExercise(id: nil, name: "Helms Row", byId: byID, byName: byName)?.id, canonical.id)
        XCTAssertEqual(try BootstrapDataService.ensureExerciseCatalog(modelContext: context).count, 77)
        XCTAssertFalse(try BootstrapDataService.consolidateCSDBRow(modelContext: context, snapshot: { _, _ in XCTFail("Repeat must not back up") }).didApply)
        let reopened = ModelContext(try open(url))
        XCTAssertFalse(try BootstrapDataService.consolidateCSDBRow(modelContext: reopened).didApply)
        XCTAssertEqual(CSDBRowIdentity.canonical(in: try BootstrapDataService.ensureExerciseCatalog(modelContext: reopened))?.id, canonical.id)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), sourceHash)
        print("OPENLIFT_CS_DB_ROW_COPY_VERIFIED history9sets18=true snapshotsUnchanged=true profilesUnchanged=true draftBackupGuards=true noDuplicateSeed=true coldReopen=true")
    }
}

extension SideDeltRevisionTests {
    func testCSDBRowEquivalentHistoryDoesNotPoolDosesOrEraseProfiles() throws {
        let canonical = Exercise(id: CSDBRowIdentity.canonicalID, name: CSDBRowIdentity.name,
            primaryMuscle: .back, type: .compound, equipment: .dumbbell)
        let ids = CSDBRowIdentity.legacyIDs.sorted { $0.uuidString < $1.uuidString }
        let catalog = [canonical] + ids.map { Exercise(id: $0, name: "legacy", primaryMuscle: .back,
            type: .compound, equipment: .dumbbell, isActive: false) }
        let first = Session(cycleInstanceId: UUID(), cycleDayIndex: 0, finishedAt: Date(timeIntervalSince1970: 1), status: .completed)
        let latest = Session(cycleInstanceId: first.cycleInstanceId, cycleDayIndex: 0, finishedAt: Date(timeIntervalSince1970: 2), status: .completed)
        let entries = [
            SetEntry(sessionId: first.id, exerciseId: canonical.id, setIndex: 1, weight: 40, reps: 12, isLocked: true),
            SetEntry(sessionId: latest.id, exerciseId: ids[0], setIndex: 1, weight: 50, reps: 10, isLocked: true),
            SetEntry(sessionId: latest.id, exerciseId: ids[0], setIndex: 2, weight: 50, reps: 9, isLocked: true),
            SetEntry(sessionId: latest.id, exerciseId: ids[1], setIndex: 1, weight: 100, reps: 8, isLocked: true)
        ]
        let profile = ExerciseResistanceProfile(workoutKind: .fixed, sessionId: latest.id, exerciseId: ids[1],
            resistanceSource: .voltra, chainType: .inverseChains, chainPounds: 7, eccentricPounds: 3, frozenAt: latest.finishedAt)
        let result = try XCTUnwrap(ExerciseEffortLookupService.globalEffort(exerciseId: canonical.id,
            adaptiveSessions: [], adaptiveSetEntries: [], rotationSessions: [first, latest],
            rotationSetEntries: entries, resistanceProfiles: [profile], exercises: catalog))
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.map(\.weight), [50, 50])
        XCTAssertTrue(result.isComparable)
        let cableResult = try XCTUnwrap(ExerciseEffortLookupService.globalEffort(exerciseId: canonical.id,
            adaptiveSessions: [], adaptiveSetEntries: [], rotationSessions: [first, latest],
            rotationSetEntries: entries, resistanceRequirement: .cable(ResistanceProfileService.value(profile)),
            resistanceProfiles: [profile], exercises: catalog))
        XCTAssertEqual(cableResult.rows.count, 1)
        XCTAssertEqual(cableResult.rows[0].weight, 100)
        XCTAssertNotNil(cableResult.resistanceProfile)
        XCTAssertTrue(cableResult.isComparable)
        // Before explicit activation, the original catalog name leaves lookup unchanged.
        canonical.name = "Chest-Supported Dumbbell Row"
        XCTAssertEqual(ExerciseEffortLookupService.globalEffort(exerciseId: canonical.id,
            adaptiveSessions: [], adaptiveSetEntries: [], rotationSessions: [first, latest],
            rotationSetEntries: entries, resistanceProfiles: [profile], exercises: catalog)?.rows.map(\.weight), [40])
    }
}
