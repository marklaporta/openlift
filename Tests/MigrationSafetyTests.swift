import CryptoKit
import CoreData
import Foundation
import SwiftData
import XCTest
@testable import OpenLift

private typealias RealDeviceStoreMigrationTargetSchema = OpenLiftSchemaV12

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
    func testHistoricalSchemasNeverReferenceLiveAppModelTypes() {
        // V1-V8 still carry broad historical-schema debt: unchanged entities
        // reference their live model classes. This guard is deliberately scoped
        // to entities whose persisted shape changed after introduction.
        let changedLiveModelIdentifiers = Set([
            ObjectIdentifier(AdaptiveReadinessResponse.self),
            ObjectIdentifier(DailyReadinessCheck.self),
            ObjectIdentifier(FixedCycleReadinessObservation.self),
            ObjectIdentifier(FixedCycleReadinessResponse.self)
        ])

        // V11's live readiness models are byte-for-byte unchanged in V12; V12
        // adds only a parallel resistance-profile entity. The changed-type
        // guard therefore applies through V10, not the immediately prior head.
        for schema in OpenLiftSchemaMigrationPlan.schemas.dropLast(2) {
            for model in schema.models {
                XCTAssertFalse(
                    changedLiveModelIdentifiers.contains(ObjectIdentifier(model)),
                    "\(schema.versionIdentifier) references changed live model \(model)"
                )
            }
        }
    }

    func testRealDeviceStoreMigrationTargetTracksHeadOfPlan() throws {
        let headSchema = try XCTUnwrap(OpenLiftSchemaMigrationPlan.schemas.last)
        XCTAssertEqual(
            RealDeviceStoreMigrationTargetSchema.versionIdentifier,
            headSchema.versionIdentifier,
            "Update the real-device-store migration target whenever the migration plan gains a schema."
        )
    }

    func testV11StoreMigratesToV12WithoutInventingResistanceProfiles() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let exerciseId = UUID()
        let sessionId = UUID()

        autoreleasepool {
            let schema = Schema(versionedSchema: OpenLiftSchemaV11.self)
            let container = try! ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V11Fixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                Exercise(
                    id: exerciseId,
                    name: "Legacy Cable Exercise",
                    primaryMuscle: .triceps,
                    type: .isolation,
                    equipment: .cable
                )
            )
            context.insert(
                Session(
                    id: sessionId,
                    cycleInstanceId: UUID(),
                    cycleDayIndex: 0,
                    finishedAt: .now,
                    status: .completed
                )
            )
            context.insert(
                SetEntry(
                    sessionId: sessionId,
                    exerciseId: exerciseId,
                    setIndex: 1,
                    weight: 40,
                    reps: 12,
                    isLocked: true
                )
            )
            try! context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV12.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V12Readback",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )
        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 1)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ExerciseResistanceProfile>()),
            0,
            "Legacy cable work must remain unknown after the lightweight migration."
        )
    }

    func testV9StoreMigratesToV10WithExistingSetCompletionTimestampsNil() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let fixedId = UUID()
        let adaptiveId = UUID()

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV9.self)
            XCTAssertNil(schema.entitiesByName["SetEntry"]?.attributesByName["lockedAt"])
            XCTAssertNil(schema.entitiesByName["AdaptiveSetEntry"]?.attributesByName["lockedAt"])
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V9SetCompletionTimestampFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                OpenLiftSchemaV9.SetEntry(
                    id: fixedId,
                    sessionId: UUID(),
                    exerciseId: UUID(),
                    setIndex: 1,
                    weight: 185,
                    reps: 9,
                    isLocked: true
                )
            )
            context.insert(
                OpenLiftSchemaV9.AdaptiveSetEntry(
                    id: adaptiveId,
                    adaptiveSessionId: UUID(),
                    occurrenceId: UUID(),
                    exerciseId: UUID(),
                    setIndex: 1,
                    weight: 60,
                    reps: 10,
                    isLocked: true
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV10.self)
        XCTAssertNotNil(schema.entitiesByName["SetEntry"]?.attributesByName["lockedAt"])
        XCTAssertNotNil(schema.entitiesByName["AdaptiveSetEntry"]?.attributesByName["lockedAt"])
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V10SetCompletionTimestampFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        let fixed = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetEntry>()).first { $0.id == fixedId }
        )
        let adaptive = try XCTUnwrap(
            try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).first { $0.id == adaptiveId }
        )
        XCTAssertTrue(fixed.isLocked)
        XCTAssertNil(fixed.lockedAt)
        XCTAssertTrue(adaptive.isLocked)
        XCTAssertNil(adaptive.lockedAt)
    }

    func testV10StoreMigratesToV11WithNilSystemicEagernessAndLegacyResponsesIntact() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let adaptiveCheckId = UUID()
        let fixedObservationId = UUID()

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV10.self)
            XCTAssertNil(
                schema.entitiesByName["DailyReadinessCheck"]?
                    .attributesByName["systemicEagerness"]
            )
            XCTAssertNil(
                schema.entitiesByName["FixedCycleReadinessObservation"]?
                    .attributesByName["systemicEagerness"]
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V10SystemicEagernessFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                OpenLiftSchemaV3.DailyReadinessCheck(
                    id: adaptiveCheckId,
                    localDateKey: "2026-07-28",
                    timeZoneIdentifier: "America/Los_Angeles",
                    revision: 1,
                    adaptiveProgramId: UUID(),
                    adaptiveProgramVersion: 8,
                    responses: [
                        OpenLiftSchemaV3.AdaptiveReadinessResponse(
                            muscle: .chest,
                            soreness: .none,
                            connectiveTissuePain: .none,
                            eagerness: .neutral
                        ),
                        OpenLiftSchemaV3.AdaptiveReadinessResponse(
                            muscle: .back,
                            soreness: .mild,
                            connectiveTissuePain: .none,
                            eagerness: .reluctant
                        )
                    ]
                )
            )
            context.insert(
                OpenLiftSchemaV9.FixedCycleReadinessObservation(
                    id: fixedObservationId,
                    sessionId: UUID(),
                    localDateKey: "2026-07-28",
                    timeZoneIdentifier: "America/Los_Angeles",
                    revision: 1,
                    responses: [
                        OpenLiftSchemaV9.FixedCycleReadinessResponse(
                            muscle: .quads,
                            soreness: .mild,
                            connectiveTissuePain: .caution,
                            eagerness: .neutral
                        )
                    ]
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV11.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V11SystemicEagernessFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        let adaptive = try XCTUnwrap(
            try context.fetch(FetchDescriptor<DailyReadinessCheck>())
                .first { $0.id == adaptiveCheckId }
        )
        XCTAssertNil(adaptive.systemicEagerness)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: adaptive.responses.map {
                ($0.muscle, $0.eagerness)
            }),
            [.chest: .neutral, .back: .reluctant]
        )
        let fixed = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FixedCycleReadinessObservation>())
                .first { $0.id == fixedObservationId }
        )
        XCTAssertNil(fixed.systemicEagerness)
        XCTAssertEqual(fixed.responses.first?.eagerness, .neutral)
    }

    func testV8StoreMigratesToV9PreservesHistoryAndReopensNewParallelRecords() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let sessionId = UUID()
        let exerciseId = UUID()

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV8.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V8FixedCycleReadinessFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                Exercise(
                    id: exerciseId,
                    name: "Migration Press",
                    primaryMuscle: .chest,
                    type: .compound,
                    equipment: .dumbbell
                )
            )
            context.insert(
                Session(
                    id: sessionId,
                    cycleInstanceId: UUID(),
                    cycleDayIndex: 1,
                    cycleNameSnapshot: "Existing Cycle",
                    dayLabelSnapshot: "Push",
                    finishedAt: Date(timeIntervalSince1970: 100),
                    status: .completed,
                    exportStatus: .success
                )
            )
            context.insert(
                SetEntry(
                    sessionId: sessionId,
                    exerciseId: exerciseId,
                    setIndex: 1,
                    weight: 50,
                    reps: 10,
                    isLocked: true
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV9.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V9FixedCycleReadinessFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )
        XCTAssertNil(startup.issue)
        var context = ModelContext(startup.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OpenLiftSchemaV9.SetEntry>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<OpenLiftSchemaV9.FixedCycleReadinessObservation>()
            ),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FixedCycleOccurrenceOverride>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FixedCycleExerciseSnapshot>()),
            0
        )
        context.insert(
            OpenLiftSchemaV9.FixedCycleReadinessObservation(
                sessionId: sessionId,
                localDateKey: "2026-07-27",
                timeZoneIdentifier: "America/Los_Angeles",
                revision: 1,
                responses: [
                    OpenLiftSchemaV9.FixedCycleReadinessResponse(
                        muscle: .chest,
                        soreness: .none,
                        connectiveTissuePain: .none,
                        eagerness: .eager
                    )
                ]
            )
        )
        context.insert(
            FixedCycleOccurrenceOverride(
                sessionId: sessionId,
                kind: .skipExercise,
                slotPosition: 1,
                exerciseId: exerciseId,
                muscle: .chest,
                reasonCode: "recovery"
            )
        )
        context.insert(
            FixedCycleExerciseSnapshot(
                sessionId: sessionId,
                position: 0,
                exerciseId: exerciseId,
                exerciseName: "Migration Press",
                muscle: .chest,
                statusRawValue: "completed"
            )
        )
        try context.save()

        let reopened = try ModelContainer(
            for: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [
                ModelConfiguration(
                    "V9FixedCycleReadinessFixtureReopen",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            ]
        )
        context = ModelContext(reopened)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 1)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<OpenLiftSchemaV9.FixedCycleReadinessObservation>()
            ),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FixedCycleOccurrenceOverride>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FixedCycleExerciseSnapshot>()),
            1
        )
    }

    func testV6StoreMigratesToV7WithoutChangingWorkoutOrDesignData() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let programId = UUID()
        let lineageId = UUID()
        let planId = UUID()

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV6.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V6VolumeControllerFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                AdaptiveProgram(
                    id: programId,
                    lineageId: lineageId,
                    version: 4,
                    name: "Existing Adaptive Profile",
                    isReviewedForUse: true,
                    globalMaxMovements: 4,
                    maxDifficultyCost: 60,
                    muscleRules: [],
                    complexes: []
                )
            )
            context.insert(
                AdaptiveWorkoutSizePreference(
                    adaptiveProgramId: programId,
                    defaultComplexCount: 4
                )
            )
            context.insert(
                AdaptivePlanDesignState(
                    generatedPlanId: planId,
                    targetComplexCount: 3,
                    readinessRevision: 2,
                    canonicalSignature: "existing-signature"
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV8.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V7VolumeControllerFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        let program = try XCTUnwrap(context.fetch(FetchDescriptor<AdaptiveProgram>()).first)
        XCTAssertEqual(program.id, programId)
        XCTAssertEqual(program.lineageId, lineageId)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveWorkoutSizePreference>()).first?.defaultComplexCount,
            4
        )
        let design = try XCTUnwrap(context.fetch(FetchDescriptor<AdaptivePlanDesignState>()).first)
        XCTAssertEqual(design.generatedPlanId, planId)
        XCTAssertEqual(design.targetComplexCount, 3)
        XCTAssertEqual(design.canonicalSignature, "existing-signature")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveMuscleVolumeTarget>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutCapacityPreference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveMuscleVolumeAnchor>()), 0)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
            ),
            0
        )
    }

    func testPopulatedV7StoreMigratesToV8AndSeedsOnlyAfterOpenPlanCompletes() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storeURL = fixture.working.appendingPathComponent("default.store")
        let programId = UUID()
        let lineageId = UUID()
        let sessionId = UUID()
        let setEntryId = UUID()
        let exerciseId = UUID()
        let planId = UUID()
        let activatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let schema = Schema(versionedSchema: OpenLiftSchemaV7.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        "V7RecoveryControllerFixture",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            context.insert(
                AdaptiveProgram(
                    id: programId,
                    lineageId: lineageId,
                    version: 7,
                    name: "Existing V7 Profile",
                    isReviewedForUse: true,
                    globalMaxMovements: 4,
                    maxDifficultyCost: 60,
                    muscleRules: [
                        AdaptiveMuscleRule(
                            muscle: .chest,
                            priorityRank: 1,
                            rollingSetFloor: 1,
                            rollingWindowDays: 7,
                            maxRecoveredDayGap: 2,
                            maxExercisesPerExposure: 2,
                            maxSetsPerExercise: 4
                        )
                    ],
                    complexes: []
                )
            )
            context.insert(
                AdaptiveMuscleVolumeTarget(
                    adaptiveProgramId: programId,
                    lineageId: lineageId,
                    muscle: .chest,
                    weeklySetTarget: 13,
                    dailySetCap: 5,
                    effectiveAt: activatedAt
                )
            )
            context.insert(
                AdaptiveMuscleVolumeAnchor(
                    lineageId: lineageId,
                    muscle: .chest,
                    activatedAt: activatedAt,
                    initialBalance: -2,
                    seededDirectSetEntryIds: [setEntryId]
                )
            )
            context.insert(
                AdaptiveWorkoutCapacityPreference(
                    adaptiveProgramId: programId,
                    maxWorkingSetCount: 20,
                    updatedAt: activatedAt
                )
            )
            context.insert(
                Exercise(
                    id: exerciseId,
                    name: "Existing Chest Press",
                    primaryMuscle: .chest,
                    type: .compound,
                    equipment: .machine
                )
            )
            context.insert(
                Session(
                    id: sessionId,
                    cycleInstanceId: UUID(),
                    cycleDayIndex: 0,
                    finishedAt: activatedAt,
                    status: .completed,
                    exportStatus: .success
                )
            )
            context.insert(
                SetEntry(
                    id: setEntryId,
                    sessionId: sessionId,
                    exerciseId: exerciseId,
                    setIndex: 0,
                    weight: 100,
                    reps: 10,
                    isLocked: true
                )
            )
            context.insert(
                GeneratedWorkoutPlan(
                    id: planId,
                    localDateKey: "2027-01-15",
                    timeZoneIdentifier: "America/Los_Angeles",
                    status: .proposed,
                    adaptiveProgramId: programId,
                    adaptiveProgramVersion: 7,
                    readinessCheckId: UUID(),
                    plannerVersion: 9,
                    reasonCodes: [],
                    complexes: []
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: OpenLiftSchemaV8.self)
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "V8RecoveryControllerFixture",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )

        XCTAssertNil(startup.issue)
        let context = ModelContext(startup.container)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveProgram>()).first?.name,
            "Existing V7 Profile"
        )
        let target = try XCTUnwrap(
            context.fetch(FetchDescriptor<AdaptiveMuscleVolumeTarget>()).first
        )
        XCTAssertEqual(target.weeklySetTarget, 13)
        XCTAssertEqual(target.dailySetCap, 5)
        let anchor = try XCTUnwrap(
            context.fetch(FetchDescriptor<AdaptiveMuscleVolumeAnchor>()).first
        )
        XCTAssertEqual(anchor.initialBalance, -2)
        XCTAssertEqual(anchor.seededDirectSetEntryIds, [setEntryId])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<SetEntry>()).map(\.id),
            [setEntryId]
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
            ),
            0
        )
        XCTAssertEqual(
            try AdaptiveExposureControllerService.migrateActiveProgramIfNeeded(
                modelContext: context,
                now: activatedAt
            ),
            0
        )

        let plan = try XCTUnwrap(
            context.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
                .first { $0.id == planId }
        )
        plan.status = .completed
        try context.save()
        XCTAssertEqual(
            try AdaptiveExposureControllerService.migrateActiveProgramIfNeeded(
                modelContext: context,
                now: activatedAt
            ),
            MuscleGroup.allCases.count
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
            ),
            MuscleGroup.allCases.count
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveMuscleVolumeTarget>()).first?
                .weeklySetTarget,
            13
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveWorkoutCapacityPreference>())
                .first?.maxWorkingSetCount,
            15
        )
    }

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
            let readiness = OpenLiftSchemaV3.DailyReadinessCheck(
                id: readinessId,
                localDateKey: "2026-07-20",
                timeZoneIdentifier: "America/Los_Angeles",
                revision: 2,
                adaptiveProgramId: adaptiveProgramId,
                adaptiveProgramVersion: 3,
                responses: [
                    OpenLiftSchemaV3.AdaptiveReadinessResponse(
                        muscle: .back,
                        soreness: .mild,
                        connectiveTissuePain: .none,
                        eagerness: .eager
                    ),
                    OpenLiftSchemaV3.AdaptiveReadinessResponse(
                        muscle: .chest,
                        soreness: .high,
                        connectiveTissuePain: .none,
                        eagerness: .neutral
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
        let migratedReadiness = try XCTUnwrap(
            context.fetch(FetchDescriptor<OpenLiftSchemaV3.DailyReadinessCheck>()).first
        )
        XCTAssertEqual(migratedReadiness.id, readinessId)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: migratedReadiness.responses.map {
                ($0.muscle, $0.soreness)
            }),
            [.back: .mild, .chest: .high]
        )
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

    func testCopiedRealDeviceStoreMigratesToCurrentSchemaWhenOptedIn() throws {
        let documentsDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let environment = ProcessInfo.processInfo.environment
        let suppliedBackup = environment["OPENLIFT_REAL_DEVICE_STORE_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? documentsDirectory.appendingPathComponent(
            "OpenLiftCopiedRealDeviceStore",
            isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: suppliedBackup.appendingPathComponent("default.store").path
        ) else {
            throw XCTSkip(
                """
                Copied real-device-store migration readback is opt-in. Set \
                OPENLIFT_REAL_DEVICE_STORE_DIRECTORY to a directory containing \
                default.store and its sidecars, or stage OpenLiftCopiedRealDeviceStore \
                in the test host's Documents directory.
                """
            )
        }

        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyWorking = fixture.root.appendingPathComponent("legacy-working", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyWorking, withIntermediateDirectories: true)
        try copyDirectoryContents(from: suppliedBackup, to: fixture.source)
        try copyDirectoryContents(from: suppliedBackup, to: legacyWorking)
        try copyDirectoryContents(from: suppliedBackup, to: fixture.working)
        let suppliedManifestBefore = try completeStoreManifest(in: suppliedBackup)

        let sourceStoreURL = legacyWorking.appendingPathComponent("default.store")
        let sourceVersion = try persistentStoreSchemaVersion(at: sourceStoreURL)
        let headSchema = try XCTUnwrap(OpenLiftSchemaMigrationPlan.schemas.last)
        guard sourceVersion <= headSchema.versionIdentifier else {
            XCTFail(
                """
                Copied real-device store schema \(sourceVersion) is newer than the \
                migration-plan head \(headSchema.versionIdentifier). Use a matching \
                or newer OpenLift build to test this backup.
                """
            )
            return
        }
        guard let sourceVersionedSchema = OpenLiftSchemaMigrationPlan.schemas.first(
            where: { $0.versionIdentifier == sourceVersion }
        ) else {
            XCTFail(
                """
                Copied real-device store schema \(sourceVersion) is not present in \
                OpenLiftSchemaMigrationPlan (head: \(headSchema.versionIdentifier)).
                """
            )
            return
        }
        print(
            """
            OpenLift copied real store detected source schema: \(sourceVersion) \
            (migration-plan head: \(headSchema.versionIdentifier))
            """
        )

        let sourceSchema = Schema(versionedSchema: sourceVersionedSchema)
        let sourceContainer = try ModelContainer(
            for: sourceSchema,
            configurations: [
                ModelConfiguration(
                    "CopiedRealDeviceSourceReadback",
                    schema: sourceSchema,
                    url: sourceStoreURL,
                    cloudKitDatabase: .none
                )
            ]
        )
        let sourceCounts = try sourceEntityCounts(
            in: sourceContainer,
            sourceVersion: sourceVersion
        )
        let sourceLockedAtCounts = sourceVersion >= OpenLiftSchemaV10.versionIdentifier
            ? try lockedAtCounts(in: sourceContainer)
            : nil

        let currentSchema = Schema(
            versionedSchema: RealDeviceStoreMigrationTargetSchema.self
        )
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: currentSchema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: ModelConfiguration(
                "CopiedRealDeviceCurrentReadback",
                schema: currentSchema,
                url: fixture.working.appendingPathComponent("default.store"),
                cloudKitDatabase: .none
            )
        )
        XCTAssertNil(startup.issue)
        let allMigratedCounts = try currentEntityCounts(in: startup.container)
        let migratedCounts = allMigratedCounts.filter { sourceCounts[$0.key] != nil }
        XCTAssertEqual(migratedCounts, sourceCounts)

        let migratedLockedAtCounts = try lockedAtCounts(in: startup.container)
        if let sourceLockedAtCounts {
            XCTAssertEqual(
                migratedLockedAtCounts,
                sourceLockedAtCounts,
                "Existing set completion timestamps must survive migration."
            )
        } else {
            XCTAssertEqual(
                migratedLockedAtCounts,
                ["SetEntry": 0, "AdaptiveSetEntry": 0],
                "Migration must not fabricate set completion timestamps."
            )
        }
        XCTAssertEqual(
            try completeStoreManifest(in: suppliedBackup),
            suppliedManifestBefore
        )

        print("OpenLift copied real store counts before migration: \(formatted(sourceCounts))")
        print("OpenLift copied real store counts after migration: \(formatted(migratedCounts))")
        print(
            """
            OpenLift copied real store lockedAt values after migration: \
            fixed=\(migratedLockedAtCounts["SetEntry"] ?? 0), \
            adaptive=\(migratedLockedAtCounts["AdaptiveSetEntry"] ?? 0)
            """
        )
    }

    func testUnversionedV1FixtureMigratesToCurrentSchemaAndRollsBack() throws {
        let fixture = try makeFixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceStoreURL = fixture.source.appendingPathComponent("default.store")
        try createUnversionedV1Fixture(at: sourceStoreURL)
        try copyDirectoryContents(from: fixture.source, to: fixture.working)

        let sourceManifestBefore = try persistentStoreManifest(in: fixture.source)
        XCTAssertFalse(sourceManifestBefore.isEmpty)

        let versionedSchema = Schema(
            versionedSchema: RealDeviceStoreMigrationTargetSchema.self
        )
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
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveMuscleVolumeTarget>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutCapacityPreference>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveMuscleVolumeAnchor>()), 0)
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

    private func v9EntityCounts(in container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        var counts = try sharedV9AndV10EntityCounts(in: context)
        counts["SetEntry"] = try context.fetchCount(
            FetchDescriptor<OpenLiftSchemaV9.SetEntry>()
        )
        counts["AdaptiveSetEntry"] = try context.fetchCount(
            FetchDescriptor<OpenLiftSchemaV9.AdaptiveSetEntry>()
        )
        return counts
    }

    private func sourceEntityCounts(
        in container: ModelContainer,
        sourceVersion: Schema.Version
    ) throws -> [String: Int] {
        if sourceVersion == OpenLiftSchemaV9.versionIdentifier {
            return try v9EntityCounts(in: container)
        }
        if sourceVersion >= OpenLiftSchemaV10.versionIdentifier {
            return try currentEntityCounts(in: container)
        }

        let context = ModelContext(container)
        var counts = try legacyEntityCounts(in: container)
        if sourceVersion >= OpenLiftSchemaV2.versionIdentifier {
            counts["TrainingPreference"] = try context.fetchCount(
                FetchDescriptor<TrainingPreference>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV3.versionIdentifier {
            counts["AdaptiveMuscleRule"] = try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleRule>()
            )
            counts["AdaptiveComplexComponent"] = try context.fetchCount(
                FetchDescriptor<AdaptiveComplexComponent>()
            )
            counts["AdaptiveExerciseComplex"] = try context.fetchCount(
                FetchDescriptor<AdaptiveExerciseComplex>()
            )
            counts["AdaptiveProgram"] = try context.fetchCount(
                FetchDescriptor<AdaptiveProgram>()
            )
            counts["AdaptiveReadinessResponse"] = try context.fetchCount(
                FetchDescriptor<AdaptiveReadinessResponse>()
            )
            counts["DailyReadinessCheck"] = try context.fetchCount(
                FetchDescriptor<DailyReadinessCheck>()
            )
            counts["PlannedExerciseSnapshot"] = try context.fetchCount(
                FetchDescriptor<PlannedExerciseSnapshot>()
            )
            counts["PlannedComplexSnapshot"] = try context.fetchCount(
                FetchDescriptor<PlannedComplexSnapshot>()
            )
            counts["GeneratedWorkoutPlan"] = try context.fetchCount(
                FetchDescriptor<GeneratedWorkoutPlan>()
            )
            counts["AdaptiveWorkoutSession"] = try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutSession>()
            )
            counts["AdaptiveSetEntry"] = try context.fetchCount(
                FetchDescriptor<AdaptiveSetEntry>()
            )
            counts["AdaptiveSetOccurrenceLink"] = try context.fetchCount(
                FetchDescriptor<AdaptiveSetOccurrenceLink>()
            )
            counts["ComplexFeedback"] = try context.fetchCount(
                FetchDescriptor<ComplexFeedback>()
            )
            counts["AdHocExerciseFeedback"] = try context.fetchCount(
                FetchDescriptor<AdHocExerciseFeedback>()
            )
            counts["AdaptiveOverrideEvent"] = try context.fetchCount(
                FetchDescriptor<AdaptiveOverrideEvent>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV4.versionIdentifier {
            counts["AdaptiveExerciseSelectionPreference"] = try context.fetchCount(
                FetchDescriptor<AdaptiveExerciseSelectionPreference>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV5.versionIdentifier {
            counts["ExportDiagnostic"] = try context.fetchCount(
                FetchDescriptor<ExportDiagnostic>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV6.versionIdentifier {
            counts["AdaptiveWorkoutSizePreference"] = try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutSizePreference>()
            )
            counts["AdaptivePlanDesignState"] = try context.fetchCount(
                FetchDescriptor<AdaptivePlanDesignState>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV7.versionIdentifier {
            counts["AdaptiveMuscleVolumeTarget"] = try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleVolumeTarget>()
            )
            counts["AdaptiveWorkoutCapacityPreference"] = try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutCapacityPreference>()
            )
            counts["AdaptiveMuscleVolumeAnchor"] = try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleVolumeAnchor>()
            )
        }
        if sourceVersion >= OpenLiftSchemaV8.versionIdentifier {
            counts["AdaptiveMuscleExposureConfiguration"] = try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
            )
        }
        return counts
    }

    private func currentEntityCounts(in container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        var counts = try sharedV9AndV10EntityCounts(in: context)
        counts["SetEntry"] = try context.fetchCount(FetchDescriptor<SetEntry>())
        counts["AdaptiveSetEntry"] = try context.fetchCount(
            FetchDescriptor<AdaptiveSetEntry>()
        )
        return counts
    }

    private func lockedAtCounts(in container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        return [
            "SetEntry": try context.fetch(FetchDescriptor<SetEntry>())
                .compactMap(\.lockedAt)
                .count,
            "AdaptiveSetEntry": try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
                .compactMap(\.lockedAt)
                .count
        ]
    }

    private func sharedV9AndV10EntityCounts(
        in context: ModelContext
    ) throws -> [String: Int] {
        [
            "Exercise": try context.fetchCount(FetchDescriptor<Exercise>()),
            "CycleSlot": try context.fetchCount(FetchDescriptor<CycleSlot>()),
            "CycleDay": try context.fetchCount(FetchDescriptor<CycleDay>()),
            "RotationPoolEntry": try context.fetchCount(FetchDescriptor<RotationPoolEntry>()),
            "RotationPool": try context.fetchCount(FetchDescriptor<RotationPool>()),
            "CycleTemplate": try context.fetchCount(FetchDescriptor<CycleTemplate>()),
            "RotationIndex": try context.fetchCount(FetchDescriptor<RotationIndex>()),
            "ActiveCycleInstance": try context.fetchCount(
                FetchDescriptor<ActiveCycleInstance>()
            ),
            "Session": try context.fetchCount(FetchDescriptor<Session>()),
            "SessionSlotOverride": try context.fetchCount(
                FetchDescriptor<SessionSlotOverride>()
            ),
            "TrainingPreference": try context.fetchCount(
                FetchDescriptor<TrainingPreference>()
            ),
            "AdaptiveMuscleRule": try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleRule>()
            ),
            "AdaptiveComplexComponent": try context.fetchCount(
                FetchDescriptor<AdaptiveComplexComponent>()
            ),
            "AdaptiveExerciseComplex": try context.fetchCount(
                FetchDescriptor<AdaptiveExerciseComplex>()
            ),
            "AdaptiveProgram": try context.fetchCount(FetchDescriptor<AdaptiveProgram>()),
            "AdaptiveReadinessResponse": try context.fetchCount(
                FetchDescriptor<AdaptiveReadinessResponse>()
            ),
            "DailyReadinessCheck": try context.fetchCount(
                FetchDescriptor<DailyReadinessCheck>()
            ),
            "PlannedExerciseSnapshot": try context.fetchCount(
                FetchDescriptor<PlannedExerciseSnapshot>()
            ),
            "PlannedComplexSnapshot": try context.fetchCount(
                FetchDescriptor<PlannedComplexSnapshot>()
            ),
            "GeneratedWorkoutPlan": try context.fetchCount(
                FetchDescriptor<GeneratedWorkoutPlan>()
            ),
            "AdaptiveWorkoutSession": try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutSession>()
            ),
            "AdaptiveSetOccurrenceLink": try context.fetchCount(
                FetchDescriptor<AdaptiveSetOccurrenceLink>()
            ),
            "ComplexFeedback": try context.fetchCount(FetchDescriptor<ComplexFeedback>()),
            "AdHocExerciseFeedback": try context.fetchCount(
                FetchDescriptor<AdHocExerciseFeedback>()
            ),
            "AdaptiveOverrideEvent": try context.fetchCount(
                FetchDescriptor<AdaptiveOverrideEvent>()
            ),
            "AdaptiveExerciseSelectionPreference": try context.fetchCount(
                FetchDescriptor<AdaptiveExerciseSelectionPreference>()
            ),
            "ExportDiagnostic": try context.fetchCount(
                FetchDescriptor<ExportDiagnostic>()
            ),
            "AdaptiveWorkoutSizePreference": try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutSizePreference>()
            ),
            "AdaptivePlanDesignState": try context.fetchCount(
                FetchDescriptor<AdaptivePlanDesignState>()
            ),
            "AdaptiveMuscleVolumeTarget": try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleVolumeTarget>()
            ),
            "AdaptiveWorkoutCapacityPreference": try context.fetchCount(
                FetchDescriptor<AdaptiveWorkoutCapacityPreference>()
            ),
            "AdaptiveMuscleVolumeAnchor": try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleVolumeAnchor>()
            ),
            "AdaptiveMuscleExposureConfiguration": try context.fetchCount(
                FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
            ),
            "FixedCycleReadinessObservation": try context.fetchCount(
                FetchDescriptor<FixedCycleReadinessObservation>()
            ),
            "FixedCycleReadinessResponse": try context.fetchCount(
                FetchDescriptor<FixedCycleReadinessResponse>()
            ),
            "FixedCycleOccurrenceOverride": try context.fetchCount(
                FetchDescriptor<FixedCycleOccurrenceOverride>()
            ),
            "FixedCycleExerciseSnapshot": try context.fetchCount(
                FetchDescriptor<FixedCycleExerciseSnapshot>()
            )
        ]
    }

    private func persistentStoreSchemaVersion(at storeURL: URL) throws -> Schema.Version {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: nil
        )
        let identifiers = try XCTUnwrap(
            metadata[NSStoreModelVersionIdentifiersKey] as? [String]
        )
        let identifier = try XCTUnwrap(identifiers.first)
        let components = identifier.split(separator: ".").compactMap { Int($0) }
        let major = try XCTUnwrap(components.first)
        let minor = try XCTUnwrap(components.dropFirst().first)
        let patch = try XCTUnwrap(components.dropFirst(2).first)
        return Schema.Version(
            major,
            minor,
            patch
        )
    }

    private func formatted(_ counts: [String: Int]) -> String {
        counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", ")
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

    private func completeStoreManifest(in directory: URL) throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.map { fileURL in
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            return (fileURL.lastPathComponent, digest)
        })
    }
}
