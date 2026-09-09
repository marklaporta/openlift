import Foundation
import SwiftData
import XCTest
@testable import OpenLift

final class ClusterSquatSwapTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        return try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("SquatSwap", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    private func fixture() throws -> (URL, ModelContainer, ModelContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SquatSwap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try container(at: root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        _ = try BootstrapDataService.prepareSeptember2026ClusterRevision(modelContext: context, backupConfirmed: true)
        _ = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: context, backupConfirmed: true)
        return (root, store, context)
    }

    private func active(_ context: ModelContext) throws -> (CycleTemplate, ActiveCycleInstance) {
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycle = try XCTUnwrap(try context.fetch(FetchDescriptor<ActiveCycleInstance>()).first {
            c in templates.contains { $0.id == c.templateId && Program.versionID(for: $0) == Program.shrugVersionID }
        })
        return (try XCTUnwrap(templates.first { $0.id == cycle.templateId }), cycle)
    }

    private func resolved(_ context: ModelContext, step: Int) throws -> [Program.ResolvedSlot] {
        let (template, cycle) = try active(context)
        let states = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: Program.shrugVersionID)
        states.first { $0.clusterID == Program.Cluster.cluster2.rawValue }!.positionIndex = step
        let selection = try Program.selection(cluster: .cluster2, template: template, cycleInstanceId: cycle.id, states: states)
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

    @MainActor
    func testAtomicSwapPreservesEveryOtherSlotAndSameExerciseProgression() throws {
        let (root, store, context) = try fixture()
        _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let (template, cycle) = try active(context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        var oldLegs: [Int: Program.ResolvedSlot] = [:]
        for step in 0..<6 { oldLegs[step] = try resolved(context, step: step)[0] }
        for step in [3, 5] {
            let leg = oldLegs[step]!
            let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: step + 3,
                finishedAt: Date(timeIntervalSince1970: Double(100 + step)), status: .completed)
            context.insert(session)
            for index in 1...(step == 3 ? 2 : 1) {
                context.insert(SetEntry(sessionId: session.id, exerciseId: leg.exerciseId,
                    setIndex: index, weight: step == 3 ? 225 : 45, reps: 8 + index, isLocked: true))
            }
            let occurrence = try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: cycle.id,
                templateId: template.id, programVersionID: Program.shrugVersionID,
                clusterID: Program.Cluster.cluster2.rawValue, absoluteStep: step, templateDayPosition: step + 3,
                dayLabel: "Cluster 2", completedAt: session.finishedAt!, exerciseSnapshots: [
                    ClusterExerciseProgressionSnapshot(position: 0, exerciseId: leg.exerciseId,
                        exerciseName: exercises.first { $0.id == leg.exerciseId }!.name, muscle: .quads,
                        prescribedSetCount: 3, progressionKey: leg.progressionKey, resistanceProfile: nil, completionStatus: .performed)
                ])
            context.insert(occurrence)
        }
        try context.save()
        let before = try unchangedState(context)
        let snapshots = try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).map(\.exerciseSnapshots)
        let result = try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(result.didApply)
        let backup = try XCTUnwrap(result.backupURL)
        let inspectionURL = root.appendingPathComponent("inspection.store")
        try FileManager.default.copyItem(at: backup, to: inspectionURL)
        let savedContainer = try container(at: inspectionURL)
        let saved = ModelContext(savedContainer)
        XCTAssertEqual(try unchangedState(saved), before)
        XCTAssertTrue(try saved.fetch(FetchDescriptor<ClusterExercisePreference>()).isEmpty)
        XCTAssertEqual(try unchangedState(context), before)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).map(\.exerciseSnapshots), snapshots)
        for step in 0..<6 {
            let leg = try resolved(context, step: step)[0]
            let sourceStep = step == 3 ? 5 : (step == 5 ? 3 : step)
            XCTAssertEqual(leg.exerciseId, oldLegs[sourceStep]?.exerciseId)
            XCTAssertEqual(leg.progressionKey, oldLegs[sourceStep]?.progressionKey)
            if [3, 5].contains(step) {
                let effort = ExerciseEffortLookupService.fixedCycleEffort(exerciseId: leg.exerciseId,
                    cycleInstanceId: cycle.id, cycleDayIndex: step + 3, adaptiveSessions: [], adaptiveSetEntries: [],
                    rotationSessions: try context.fetch(FetchDescriptor<Session>()),
                    rotationSetEntries: try context.fetch(FetchDescriptor<SetEntry>()), progressionKey: leg.progressionKey,
                    progressionOccurrences: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()))
                XCTAssertEqual(effort?.rows.map(\.weight), step == 3 ? [45] : [225, 225])
                XCTAssertEqual(effort?.rows.map(\.reps), step == 3 ? [9] : [9, 10])
            }
        }
        let repeatResult = try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("No repeat backup") })
        XCTAssertFalse(repeatResult.didApply)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).count, 2)
    }

    @MainActor
    func testBackupFailuresAndDraftsLeaveStateUntouched() throws {
        let (root, store, context) = try fixture()
        _ = store
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try unchangedState(context)
        enum Injected: Error { case failure }
        for snapshot: (URL, URL) throws -> Void in [
            { _, _ in throw Injected.failure },
            { _, target in try Data("invalid".utf8).write(to: target) }
        ] {
            XCTAssertThrowsError(try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context,
                backupDirectory: root.appendingPathComponent("backups"), snapshot: snapshot))
        }
        XCTAssertEqual(try unchangedState(context), before)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClusterExercisePreference>()).isEmpty)
        let (_, cycle) = try active(context)
        cycle.currentDayIndex = 99
        XCTAssertThrowsError(try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Unsaved edits must not reach backup") }))
        XCTAssertEqual(cycle.currentDayIndex, 99)
        XCTAssertTrue(context.hasChanges)
        context.rollback()
        let draft = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, status: .draft)
        context.insert(draft)
        try context.save()
        XCTAssertThrowsError(try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context,
            snapshot: { _, _ in XCTFail("Draft must not reach backup") }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).first?.id, draft.id)
    }

    /// Supplied personal store is never opened; test only mutates its scratch copy.
    @MainActor
    func testCopiedRealStoreSquatSwapWhenOptedIn() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let supplied = documents.appendingPathComponent("OpenLiftCopiedSquatSwapStore")
        guard FileManager.default.fileExists(atPath: supplied.appendingPathComponent("default.store").path) else {
            throw XCTSkip("Stage a verified v3 copy in Documents/OpenLiftCopiedSquatSwapStore")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SquatRealCopy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: supplied, to: root)
        let store = try container(at: root.appendingPathComponent("default.store"))
        let context = ModelContext(store)
        let before = try unchangedState(context)
        let occurrences = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).map { ($0.id, $0.exerciseSnapshots) })
        let profiles = ResistanceProfileService.snapshots(try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()))
        let oldPrefs = try context.fetch(FetchDescriptor<ClusterExercisePreference>()).map {
            "\($0.id)|\($0.key)|\($0.exerciseId)|\($0.updatedAt)"
        }.sorted()
        let d = try resolved(context, step: 3)[0]
        let f = try resolved(context, step: 5)[0]
        let result = try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context,
            backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(try unchangedState(context), before)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).map { ($0.id, $0.exerciseSnapshots) }), occurrences)
        XCTAssertEqual(ResistanceProfileService.snapshots(try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())), profiles)
        let prefs = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        XCTAssertEqual(prefs.filter { !($0.programVersionID == Program.shrugVersionID && [6, 8].contains($0.templateDayPosition) && $0.slotPosition == 0) }.map {
            "\($0.id)|\($0.key)|\($0.exerciseId)|\($0.updatedAt)"
        }.sorted(), oldPrefs)
        XCTAssertEqual(try resolved(context, step: 3)[0].exerciseId, f.exerciseId)
        XCTAssertEqual(try resolved(context, step: 5)[0].exerciseId, d.exerciseId)
        XCTAssertEqual(try resolved(context, step: 3)[0].progressionKey, f.progressionKey)
        XCTAssertEqual(try resolved(context, step: 5)[0].progressionKey, d.progressionKey)
        XCTAssertFalse(try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: context).didApply)
        let reopenURL = root.appendingPathComponent("post-swap-reopen.store")
        try StoreBackupService.snapshot(storeAt: root.appendingPathComponent("default.store"), into: reopenURL)
        let reopenedContainer = try container(at: reopenURL)
        let reopened = ModelContext(reopenedContainer)
        XCTAssertEqual(try unchangedState(reopened), before)
        XCTAssertEqual(try resolved(reopened, step: 3)[0].exerciseId, f.exerciseId)
        XCTAssertEqual(try resolved(reopened, step: 5)[0].exerciseId, d.exerciseId)
        XCTAssertEqual(try resolved(reopened, step: 3)[0].progressionKey, f.progressionKey)
        XCTAssertEqual(try resolved(reopened, step: 5)[0].progressionKey, d.progressionKey)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ClusterExercisePreference>()).count, prefs.count)
        XCTAssertFalse(try BootstrapDataService.applyClusterSquatSwapWithFreshBackup(modelContext: reopened,
            snapshot: { _, _ in XCTFail("Cold reopen must retain applied preferences") }).didApply)
        print("OPENLIFT_COPIED_SQUAT_SWAP_VERIFIED sessions=\(try context.fetch(FetchDescriptor<Session>()).count) sets=\(try context.fetch(FetchDescriptor<SetEntry>()).count) occurrences=\(occurrences.count) profiles=\(profiles.count) \(try BootstrapDataService.seatedShrugRevisionAudit(modelContext: context))")
    }
}
