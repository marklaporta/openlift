import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import OpenLift

@Model
private final class UnsupportedMigrationMarker {
    var requiredValue: String

    init(requiredValue: String) {
        self.requiredValue = requiredValue
    }
}

private enum UnsupportedSchemaV99: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)
    static let models = OpenLiftSchemaV1.models + [UnsupportedMigrationMarker.self]
}

private enum UnsupportedMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        OpenLiftSchemaV1.self,
        UnsupportedSchemaV99.self
    ]
    static let stages: [MigrationStage] = [
        .custom(
            fromVersion: OpenLiftSchemaV1.self,
            toVersion: UnsupportedSchemaV99.self,
            willMigrate: { _ in
                throw NSError(
                    domain: "OpenLiftMigrationSafety",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Deliberate migration failure"]
                )
            },
            didMigrate: nil
        )
    ]
}

final class MigrationSafetyTests: XCTestCase {
    func testV5StoreMigratesToV6WithoutChangingWorkoutOrExportData() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let sessionId = UUID()
        let adaptiveProgramId = UUID()
        let readinessId = UUID()
        let adaptivePlanId = UUID()
        let adaptiveSessionId = UUID()
        let adaptiveSetEntryId = UUID()
        let exerciseId = UUID()

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV5.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V5AdaptiveDesignFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                Session(
                    id: sessionId,
                    cycleInstanceId: UUID(),
                    cycleDayIndex: 0,
                    finishedAt: Date(timeIntervalSince1970: 1_774_228_400),
                    status: .completed,
                    exportStatus: .success
                )
            )
            context.insert(
                ExportDiagnostic(
                    sessionId: sessionId,
                    sessionKind: .fixed,
                    status: .success,
                    filename: "workout-existing.json",
                    detail: "Uploaded to iCloud Drive."
                )
            )
            let exercise = Exercise(
                id: exerciseId,
                name: "Existing Cable Row",
                primaryMuscle: .back,
                type: .compound,
                equipment: .cable
            )
            let program = AdaptiveProgram(
                id: adaptiveProgramId,
                version: 3,
                name: "Existing Adaptive Profile",
                isReviewedForUse: true,
                globalMaxMovements: 4,
                maxDifficultyCost: 60,
                muscleRules: [],
                complexes: []
            )
            let readiness = DailyReadinessCheck(
                id: readinessId,
                localDateKey: "2026-07-20",
                timeZoneIdentifier: "America/Los_Angeles",
                revision: 2,
                adaptiveProgramId: adaptiveProgramId,
                adaptiveProgramVersion: 3,
                responses: [
                    AdaptiveReadinessResponse(
                        muscle: .back,
                        soreness: .none,
                        connectiveTissuePain: .none,
                        eagerness: .eager
                    )
                ]
            )
            let plannedExercise = PlannedExerciseSnapshot(
                position: 0,
                exerciseId: exerciseId,
                exerciseName: exercise.name,
                primaryMuscle: .back,
                difficulty: .hard,
                prescribedSetCount: 1
            )
            let plan = GeneratedWorkoutPlan(
                id: adaptivePlanId,
                localDateKey: "2026-07-20",
                timeZoneIdentifier: "America/Los_Angeles",
                status: .completed,
                adaptiveProgramId: adaptiveProgramId,
                adaptiveProgramVersion: 3,
                readinessCheckId: readinessId,
                plannerVersion: 4,
                reasonCodes: ["existing_workout"],
                sessionId: adaptiveSessionId,
                complexes: [
                    PlannedComplexSnapshot(
                        sourceDefinitionId: UUID(),
                        sourceVersion: 3,
                        position: 0,
                        name: "Existing Back",
                        primaryMuscle: .back,
                        reasonCodes: ["existing_workout"],
                        exercises: [plannedExercise]
                    )
                ]
            )
            let adaptiveSession = AdaptiveWorkoutSession(
                id: adaptiveSessionId,
                generatedPlanId: adaptivePlanId,
                finishedAt: Date(timeIntervalSince1970: 1_774_228_400),
                status: .completed,
                exportStatus: .success
            )
            let adaptiveSet = AdaptiveSetEntry(
                id: adaptiveSetEntryId,
                adaptiveSessionId: adaptiveSessionId,
                occurrenceId: plannedExercise.occurrenceId,
                exerciseId: exerciseId,
                setIndex: 1,
                weight: 120,
                reps: 8,
                isLocked: true
            )
            context.insert(exercise)
            context.insert(program)
            context.insert(readiness)
            context.insert(plan)
            context.insert(adaptiveSession)
            context.insert(adaptiveSet)
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV6.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V6AdaptiveDesignFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).map(\.id), [sessionId])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExportDiagnostic>()).first?.filename, "workout-existing.json")
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveProgram>()).first?.id, adaptiveProgramId)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyReadinessCheck>()).first?.id, readinessId)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GeneratedWorkoutPlan>()).first?.id, adaptivePlanId)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id, adaptiveSessionId)
        let migratedSet = try XCTUnwrap(context.fetch(FetchDescriptor<AdaptiveSetEntry>()).first)
        XCTAssertEqual(migratedSet.id, adaptiveSetEntryId)
        XCTAssertEqual(migratedSet.exerciseId, exerciseId)
        XCTAssertEqual(migratedSet.weight, 120)
        XCTAssertEqual(migratedSet.reps, 8)
        XCTAssertTrue(migratedSet.isLocked)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSizePreference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptivePlanDesignState>()), 0)
    }

    func testV4StoreMigratesToV5WithoutChangingWorkoutData() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let sessionId = UUID()

        do {
            let v4Schema = Schema(versionedSchema: OpenLiftSchemaV4.self)
            let v4Container = try ModelContainer(
                for: v4Schema,
                configurations: [
                    ModelConfiguration(
                        "V4ExportDiagnosticFixture",
                        schema: v4Schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let v4Context = ModelContext(v4Container)
            v4Context.insert(Session(
                id: sessionId,
                cycleInstanceId: UUID(),
                cycleDayIndex: 0,
                finishedAt: Date(timeIntervalSince1970: 1_774_228_400),
                status: .completed,
                exportStatus: .success
            ))
            try v4Context.save()
        }

        let v5Schema = Schema(versionedSchema: OpenLiftSchemaV5.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: v5Schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V5ExportDiagnosticFixture",
                schema: v5Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let v5Context = ModelContext(startup.container)
        XCTAssertEqual(try v5Context.fetch(FetchDescriptor<Session>()).map(\.id), [sessionId])
        XCTAssertEqual(try v5Context.fetchCount(FetchDescriptor<ExportDiagnostic>()), 0)
    }

    func testBackedUpDeviceStoreMigratesOnWorkingCopyWhenOptedIn() throws {
        let documentsDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let suppliedBackup = documentsDirectory.appendingPathComponent(
            "OpenLiftCopiedV1Store",
            isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: suppliedBackup.appendingPathComponent("default.store").path
        ) else {
            throw XCTSkip("Copied device-store migration readback is opt-in; no simulator-local fixture is present.")
        }

        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyWorking = fixture.root.appendingPathComponent("legacy-working", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyWorking, withIntermediateDirectories: true)
        try copyDirectoryContents(from: suppliedBackup, to: fixture.source)
        try copyDirectoryContents(from: suppliedBackup, to: legacyWorking)
        try copyDirectoryContents(from: suppliedBackup, to: fixture.working)
        let suppliedManifestBefore = try persistentStoreManifest(in: suppliedBackup)

        let legacySchema = Schema(OpenLiftSchemaV1.models)
        let legacyContainer = try ModelContainer(
            for: legacySchema,
            configurations: [
                ModelConfiguration(
                    "CopiedDeviceLegacyReadback",
                    schema: legacySchema,
                    url: legacyWorking.appendingPathComponent("default.store"),
                    cloudKitDatabase: .none
                )
            ]
        )
        let legacyCounts = try legacyEntityCounts(in: legacyContainer)

        let v5Schema = Schema(versionedSchema: OpenLiftSchemaV6.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: v5Schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "CopiedDeviceV6Readback",
                schema: v5Schema,
                url: fixture.working.appendingPathComponent("default.store"),
                cloudKitDatabase: .none
            )
        )
        XCTAssertNil(startup.issue)
        XCTAssertEqual(try legacyEntityCounts(in: startup.container), legacyCounts)

        let migratedContext = ModelContext(startup.container)
        try assertAdaptiveEntitiesAreEmpty(in: migratedContext)
        let preferences = try migratedContext.fetch(FetchDescriptor<TrainingPreference>())
        XCTAssertTrue(preferences.isEmpty)
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: preferences), .rotation)
        XCTAssertEqual(try persistentStoreManifest(in: suppliedBackup), suppliedManifestBefore)
    }

    func testUnversionedV1FixtureMigratesToV6AndRollsBack() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceStoreURL = fixture.source.appendingPathComponent("default.store")
        try createUnversionedV1Fixture(at: sourceStoreURL)
        try copyDirectoryContents(from: fixture.source, to: fixture.working)

        let sourceManifestBefore = try persistentStoreManifest(in: fixture.source)
        XCTAssertFalse(sourceManifestBefore.isEmpty)

        let versionedSchema = Schema(versionedSchema: OpenLiftSchemaV6.self)
        let workingStoreURL = fixture.working.appendingPathComponent("default.store")
        let workingConfiguration = ModelConfiguration(
            "MigrationFixture",
            schema: versionedSchema,
            url: workingStoreURL,
            cloudKitDatabase: .none
        )
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: versionedSchema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: workingConfiguration
        )

        XCTAssertNil(startup.issue)
        try assertFixtureContents(in: startup.container)
        let migratedContext = ModelContext(startup.container)
        try assertAdaptiveEntitiesAreEmpty(in: migratedContext)
        let preferences = try migratedContext.fetch(FetchDescriptor<TrainingPreference>())
        XCTAssertTrue(preferences.isEmpty)
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: preferences), .rotation)

        // Migration operates only on the backed-up working copy.
        XCTAssertEqual(try persistentStoreManifest(in: fixture.source), sourceManifestBefore)

        // The untouched source remains readable by the pre-versioning shape,
        // which is the rollback contract for this gate.
        let legacySchema = Schema(OpenLiftSchemaV1.models)
        let rollbackConfiguration = ModelConfiguration(
            "RollbackFixture",
            schema: legacySchema,
            url: sourceStoreURL,
            cloudKitDatabase: .none
        )
        let rollbackContainer = try ModelContainer(
            for: legacySchema,
            configurations: [rollbackConfiguration]
        )
        try assertFixtureContents(in: rollbackContainer)
    }

    func testUnsupportedMigrationPreservesStoreAndReturnsActionableIssue() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceStoreURL = fixture.source.appendingPathComponent("default.store")
        try createUnversionedV1Fixture(at: sourceStoreURL)
        let sourceManifestBefore = try persistentStoreManifest(in: fixture.source)

        let unsupportedSchema = Schema(versionedSchema: UnsupportedSchemaV99.self)
        let unsupportedConfiguration = ModelConfiguration(
            "UnsupportedMigrationFixture",
            schema: unsupportedSchema,
            url: sourceStoreURL,
            cloudKitDatabase: .none
        )
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: unsupportedSchema,
            migrationPlan: UnsupportedMigrationPlan.self,
            configuration: unsupportedConfiguration
        )

        let issue = try XCTUnwrap(startup.issue)
        XCTAssertEqual(issue.storeURL, sourceStoreURL)
        XCTAssertTrue(issue.userMessage.contains("left in place"))
        XCTAssertTrue(issue.userMessage.contains("preserve a backup"))
        XCTAssertEqual(try persistentStoreManifest(in: fixture.source), sourceManifestBefore)

        let legacySchema = Schema(OpenLiftSchemaV1.models)
        let rollbackConfiguration = ModelConfiguration(
            "FailureRollbackFixture",
            schema: legacySchema,
            url: sourceStoreURL,
            cloudKitDatabase: .none
        )
        let rollbackContainer = try ModelContainer(
            for: legacySchema,
            configurations: [rollbackConfiguration]
        )
        try assertFixtureContents(in: rollbackContainer)
    }

    private func assertAdaptiveEntitiesAreEmpty(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveProgram>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveMuscleRule>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveExerciseComplex>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveComplexComponent>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveReadinessResponse>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyReadinessCheck>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedExerciseSnapshot>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedComplexSnapshot>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GeneratedWorkoutPlan>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetOccurrenceLink>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ComplexFeedback>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdHocExerciseFeedback>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveOverrideEvent>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveExerciseSelectionPreference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportDiagnostic>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSizePreference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptivePlanDesignState>()), 0)
    }

    private func createUnversionedV1Fixture(at storeURL: URL) throws {
        let schema = Schema(OpenLiftSchemaV1.models)
        XCTAssertEqual(schema.version, OpenLiftSchemaV1.versionIdentifier)

        let configuration = ModelConfiguration(
            "LegacyV1Fixture",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let press = Exercise(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Fixture Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let fly = Exercise(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Fixture Fly",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let slot = CycleSlot(position: 0, muscle: .chest, exerciseId: press.id, defaultSetCount: 3)
        let day = CycleDay(label: "Upper Fixture", slots: [slot], position: 0)
        let poolEntry = RotationPoolEntry(exerciseId: fly.id)
        let pool = RotationPool(key: RotationPoolKey.quadsCompound.rawValue, entries: [poolEntry])
        let template = CycleTemplate(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Synthetic Legacy Cycle",
            days: [day],
            rotationPools: [pool]
        )
        let rotationIndex = RotationIndex(key: RotationPoolKey.quadsCompound.rawValue, value: 1)
        let activeCycle = ActiveCycleInstance(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            templateId: template.id,
            currentDayIndex: 0,
            rotationIndices: [rotationIndex]
        )
        let draft = Session(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .draft,
            exportStatus: .pending
        )
        let completed = Session(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label,
            createdAt: Date(timeIntervalSince1970: 1_699_900_000),
            finishedAt: Date(timeIntervalSince1970: 1_699_900_900),
            status: .completed,
            exportStatus: .success
        )
        let draftSet = SetEntry(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            sessionId: draft.id,
            exerciseId: press.id,
            setIndex: 1,
            weight: 70,
            reps: 0,
            isLocked: false
        )
        let completedSet = SetEntry(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            sessionId: completed.id,
            exerciseId: fly.id,
            setIndex: 1,
            weight: 35,
            reps: 12,
            isLocked: true
        )
        let slotOverride = SessionSlotOverride(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            sessionId: draft.id,
            slotPosition: 0,
            exerciseId: fly.id
        )

        [press, fly].forEach(context.insert)
        context.insert(template)
        context.insert(activeCycle)
        context.insert(draft)
        context.insert(completed)
        context.insert(draftSet)
        context.insert(completedSet)
        context.insert(slotOverride)
        try context.save()
    }

    private func assertFixtureContents(in container: ModelContainer) throws {
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CycleSlot>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CycleDay>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RotationPoolEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RotationPool>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CycleTemplate>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RotationIndex>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActiveCycleInstance>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionSlotOverride>()), 1)

        let sessions = try context.fetch(FetchDescriptor<Session>())
        let draft = try XCTUnwrap(sessions.first(where: { $0.status == .draft }))
        let completed = try XCTUnwrap(sessions.first(where: { $0.status == .completed }))
        XCTAssertEqual(draft.cycleNameSnapshot, "Synthetic Legacy Cycle")
        XCTAssertEqual(draft.exportStatus, .pending)
        XCTAssertEqual(completed.dayLabelSnapshot, "Upper Fixture")
        XCTAssertEqual(completed.exportStatus, .success)
        XCTAssertNotNil(completed.finishedAt)

        let activeCycle = try XCTUnwrap(context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        XCTAssertEqual(activeCycle.currentDayIndex, 0)
        XCTAssertEqual(activeCycle.rotationIndices.first?.value, 1)

        let sets = try context.fetch(FetchDescriptor<SetEntry>())
        XCTAssertEqual(sets.filter(\.isLocked).count, 1)
        XCTAssertEqual(sets.first(where: \.isLocked)?.reps, 12)
    }

    private func legacyEntityCounts(in container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        return [
            "Exercise": try context.fetchCount(FetchDescriptor<Exercise>()),
            "CycleSlot": try context.fetchCount(FetchDescriptor<CycleSlot>()),
            "CycleDay": try context.fetchCount(FetchDescriptor<CycleDay>()),
            "RotationPoolEntry": try context.fetchCount(FetchDescriptor<RotationPoolEntry>()),
            "RotationPool": try context.fetchCount(FetchDescriptor<RotationPool>()),
            "CycleTemplate": try context.fetchCount(FetchDescriptor<CycleTemplate>()),
            "RotationIndex": try context.fetchCount(FetchDescriptor<RotationIndex>()),
            "ActiveCycleInstance": try context.fetchCount(FetchDescriptor<ActiveCycleInstance>()),
            "Session": try context.fetchCount(FetchDescriptor<Session>()),
            "SetEntry": try context.fetchCount(FetchDescriptor<SetEntry>()),
            "SessionSlotOverride": try context.fetchCount(FetchDescriptor<SessionSlotOverride>())
        ]
    }

    private func makeFixtureDirectories() throws -> (root: URL, source: URL, working: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLiftMigrationSafety-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let working = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        return (root, source, working)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        for sourceURL in try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destination.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }
    }

    private func persistentStoreManifest(in directory: URL) throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.compactMap { fileURL in
            guard fileURL.lastPathComponent != "default.store-shm" else { return nil }
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (fileURL.lastPathComponent, digest)
        })
    }
}
