import Foundation
import SwiftData
import XCTest
@testable import OpenLift

final class SeatedShrugActivationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let cycle: ActiveCycleInstance
        let templateID: UUID
        let exerciseID: UUID
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShrugActivation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        let container = try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("ShrugActivation", schema: schema,
                url: root.appendingPathComponent("default.store"), cloudKitDatabase: .none)])
        let context = ModelContext(container)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        let revision = try BootstrapDataService.prepareSeptember2026ClusterRevision(modelContext: context, backupConfirmed: true)
        let cycle = try XCTUnwrap(try context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        let exercise = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>()).first)
        return Fixture(root: root, container: container, context: context, cycle: cycle,
            templateID: revision.templateId, exerciseID: exercise.id)
    }

    private func addHistory(_ f: Fixture, reps: Int) throws -> UUID {
        let session = Session(cycleInstanceId: f.cycle.id, cycleDayIndex: 0,
            finishedAt: Date(timeIntervalSince1970: Double(reps)), status: .completed)
        f.context.insert(session)
        f.context.insert(SetEntry(sessionId: session.id, exerciseId: f.exerciseID,
            setIndex: 1, weight: 40, reps: reps, isLocked: true))
        try f.context.save()
        return session.id
    }

    @MainActor
    func testFreshSnapshotContainsLatestPreRevisionStateAndRepeatDoesNotCreateAnotherBackup() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let earlierID = try addHistory(f, reps: 10)
        let backups = f.root.appendingPathComponent("revision-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stale = backups.appendingPathComponent("before-alternating-shrugs-older.sqlite")
        try StoreBackupService.snapshot(storeAt: f.root.appendingPathComponent("default.store"), into: stale)
        let staleBytes = try Data(contentsOf: stale)
        let latestID = try addHistory(f, reps: 14)
        let applied = try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context, backupDirectory: backups)
        XCTAssertTrue(applied.revision.didApply)
        let backup = try XCTUnwrap(applied.backupURL)
        XCTAssertNotEqual(backup, stale)
        XCTAssertTrue(StoreBackupService.isValidSnapshot(at: backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-shm"))
        XCTAssertEqual(try Data(contentsOf: stale), staleBytes)
        let inspection = f.root.appendingPathComponent("inspection.store")
        try FileManager.default.copyItem(at: backup, to: inspection)
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        let inspectionContainer = try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [ModelConfiguration("Inspection", schema: schema, url: inspection, cloudKitDatabase: .none)])
        let saved = ModelContext(inspectionContainer)
        XCTAssertEqual(Set(try saved.fetch(FetchDescriptor<Session>()).map(\.id)), [earlierID, latestID])
        XCTAssertEqual(try saved.fetch(FetchDescriptor<SetEntry>()).map(\.reps).sorted(), [10, 14])
        XCTAssertEqual(try saved.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.templateId, f.templateID)
        XCTAssertFalse(try saved.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == BootstrapDataService.seatedShrugRevisionMarker })
        let repeated = try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context, backupDirectory: backups,
            snapshot: { _, _ in XCTFail("Already-applied revisions must not create backup churn") })
        XCTAssertFalse(repeated.revision.didApply)
        XCTAssertNil(repeated.backupURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).count, 2)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Session>()).count, 2)
    }

    @MainActor
    func testSnapshotFailureAndInvalidSnapshotLeaveProgramUntouched() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try addHistory(f, reps: 12)
        let backups = f.root.appendingPathComponent("revision-backups")
        enum Injected: Error { case snapshotFailure }
        XCTAssertThrowsError(try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: backups, snapshot: { _, _ in throw Injected.snapshotFailure }))
        XCTAssertThrowsError(try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: backups, snapshot: { _, target in try Data("not SQLite".utf8).write(to: target) }))
        XCTAssertEqual(f.cycle.templateId, f.templateID)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ClusterRotationState>()).count, 6)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Session>()).count, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<SetEntry>()).first?.reps, 12)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == BootstrapDataService.seatedShrugRevisionMarker })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor
    func testPendingChangesAndDraftAreRefusedBeforeBackupWithoutDiscardingWork() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let backups = f.root.appendingPathComponent("revision-backups")
        f.cycle.currentDayIndex = 1
        XCTAssertThrowsError(try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: backups, snapshot: { _, _ in XCTFail("Pending edits cannot reach backup") }))
        XCTAssertTrue(f.context.hasChanges)
        XCTAssertEqual(f.cycle.currentDayIndex, 1, "Do not roll back unrelated pending edits")
        f.context.rollback()
        let draft = Session(cycleInstanceId: f.cycle.id, cycleDayIndex: 0, status: .draft)
        f.context.insert(draft)
        let entered = SetEntry(sessionId: draft.id, exerciseId: f.exerciseID, setIndex: 1, weight: 50, reps: 13, isLocked: true)
        f.context.insert(entered)
        try f.context.save()
        XCTAssertThrowsError(try BootstrapDataService.applySeatedShrugRevisionWithFreshBackup(modelContext: f.context,
            backupDirectory: backups, snapshot: { _, _ in XCTFail("A draft cannot reach backup") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(f.cycle.templateId, f.templateID)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Session>()).first?.id, draft.id)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<SetEntry>()).first?.id, entered.id)
        XCTAssertEqual(entered.reps, 13)
        XCTAssertTrue(entered.isLocked)
    }
}
