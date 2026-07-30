import Foundation
import SwiftData
import XCTest
@testable import OpenLift

final class FixedCyclePushPullTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateId")
        UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateName")
        super.tearDown()
    }

    func testPushPullTemplateHasRequiredCompletionOrderAndSlotOrder() throws {
        let (_, context) = makeContext()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try BootstrapDataService.pushPullABTemplate(
            exercises: exercises,
            sourceTemplate: nil
        )
        let byId = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
        let days = CycleOrdering.sortedDays(template.days)

        XCTAssertEqual(days.map(\.label), ["Pull A", "Push A", "Pull B", "Push B"])
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[0].slots).map(\.muscle),
            [.back, .back, .biceps, .hamstrings, .forearms]
        )
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[1].slots).map(\.muscle),
            [.chest, .chest, .triceps, .quads, .sideDelts, .calves]
        )
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[0].slots).prefix(2).compactMap { byId[$0.exerciseId] },
            ["Lat Pulldown", "Chest-Supported Cable Row"]
        )
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[1].slots).prefix(2).compactMap { byId[$0.exerciseId] },
            ["Incline Dumbbell Press", "Flat Cable Flye"]
        )
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[2].slots).prefix(2).compactMap { byId[$0.exerciseId] },
            ["Chest-Supported Cable Row", "Lat Pulldown"]
        )
        XCTAssertEqual(
            CycleOrdering.sortedSlots(days[3].slots).prefix(2).compactMap { byId[$0.exerciseId] },
            ["Flat Dumbbell Press", "Incline Cable Flye"]
        )
    }

    func testAuthorizedRolloutPreservesHistoryAndOldTemplateAndNeverRewindsAfterMarker() throws {
        let (_, context) = makeContext()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let oldTemplate = try BootstrapDataService.defaultStarterTemplate(exercises: exercises)
        context.insert(oldTemplate)
        let oldCycle = ActiveCycleInstance(templateId: oldTemplate.id, currentDayIndex: 1)
        context.insert(oldCycle)
        let completed = Session(
            cycleInstanceId: oldCycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: oldTemplate.name,
            dayLabelSnapshot: "Upper",
            finishedAt: Date(timeIntervalSince1970: 100),
            status: .completed
        )
        context.insert(completed)
        let emptyDraft = Session(cycleInstanceId: oldCycle.id, cycleDayIndex: 1)
        context.insert(emptyDraft)
        context.insert(TrainingPreference(modeRawValue: TrainingMode.adaptive.rawValue))
        try context.save()
        UserDefaults.standard.set(
            oldTemplate.id.uuidString,
            forKey: "openlift.lastActivatedTemplateId"
        )

        let first = try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>())
        let preferences = try context.fetch(FetchDescriptor<TrainingPreference>())
        let migrated = try XCTUnwrap(cycles.first { $0.id == first.cycleId })

        XCTAssertTrue(first.didApply)
        XCTAssertEqual(migrated.currentDayIndex, 1)
        XCTAssertEqual(
            templates.first(where: { $0.id == first.templateId }).map {
                CycleOrdering.sortedDays($0.days)[migrated.currentDayIndex].label
            } ?? nil,
            "Push A"
        )
        XCTAssertTrue(templates.contains { $0.id == oldTemplate.id })
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Session>()).first { $0.id == completed.id })
        XCTAssertNil(try context.fetch(FetchDescriptor<Session>()).first { $0.id == emptyDraft.id })
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: preferences), .rotation)
        XCTAssertNotNil(preferences.first { $0.key == BootstrapDataService.pushPullRolloutMarkerKey })

        migrated.currentDayIndex = 2
        preferences.first(where: { $0.key == TrainingModeService.activeModeKey })?
            .modeRawValue = TrainingMode.adaptive.rawValue
        try context.save()

        let second = try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(migrated.currentDayIndex, 2)
        XCTAssertEqual(
            TrainingModeService.resolvedMode(
                preferences: try context.fetch(FetchDescriptor<TrainingPreference>())
            ),
            .adaptive
        )
    }

    func testAuthorizedRolloutPersistsNewCycleIdentityInFileBackedStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLiftPushPullRollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let schema = Schema(versionedSchema: OpenLiftSchemaV11.self)
        let storeURL = root.appendingPathComponent("default.store")
        var rolloutTemplateId = UUID()
        var rolloutCycleId = UUID()

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: OpenLiftSchemaMigrationPlan.self,
                configurations: [
                    ModelConfiguration(
                        "PushPullRolloutPersistence",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let context = ModelContext(container)
            let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
            let oldTemplate = try BootstrapDataService.defaultStarterTemplate(exercises: exercises)
            context.insert(oldTemplate)
            let oldCycle = ActiveCycleInstance(templateId: oldTemplate.id, currentDayIndex: 2)
            context.insert(oldCycle)
            context.insert(Session(cycleInstanceId: oldCycle.id, cycleDayIndex: 2))
            context.insert(TrainingPreference(modeRawValue: TrainingMode.adaptive.rawValue))
            try context.save()
            UserDefaults.standard.set(
                oldTemplate.id.uuidString,
                forKey: "openlift.lastActivatedTemplateId"
            )

            let result = try BootstrapDataService.preparePushPullABRollout(
                modelContext: context,
                archivedDraftsConfirmed: true
            )
            rolloutTemplateId = result.templateId
            rolloutCycleId = result.cycleId
        }

        let reopened = try ModelContainer(
            for: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configurations: [
                ModelConfiguration(
                    "PushPullRolloutPersistenceReopen",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            ]
        )
        let reopenedContext = ModelContext(reopened)
        let cycle = try XCTUnwrap(
            try reopenedContext.fetch(FetchDescriptor<ActiveCycleInstance>())
                .first { $0.id == rolloutCycleId }
        )
        let template = try XCTUnwrap(
            try reopenedContext.fetch(FetchDescriptor<CycleTemplate>())
                .first { $0.id == rolloutTemplateId }
        )

        XCTAssertEqual(cycle.templateId, template.id)
        XCTAssertEqual(cycle.currentDayIndex, 1)
        XCTAssertEqual(CycleOrdering.sortedDays(template.days)[cycle.currentDayIndex].label, "Push A")
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<Session>()), 0)
    }

    func testAuthorizedRolloutRefusesDraftWithEnteredOrLockedWork() throws {
        let (_, context) = makeContext()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let oldTemplate = try BootstrapDataService.defaultStarterTemplate(exercises: exercises)
        context.insert(oldTemplate)
        let oldCycle = ActiveCycleInstance(templateId: oldTemplate.id, currentDayIndex: 0)
        context.insert(oldCycle)
        let draft = Session(cycleInstanceId: oldCycle.id, cycleDayIndex: 0)
        context.insert(draft)
        context.insert(
            SetEntry(
                sessionId: draft.id,
                exerciseId: try XCTUnwrap(exercises.first).id,
                setIndex: 1,
                weight: 45,
                reps: 0,
                isLocked: false
            )
        )
        try context.save()
        UserDefaults.standard.set(
            oldTemplate.id.uuidString,
            forKey: "openlift.lastActivatedTemplateId"
        )

        XCTAssertThrowsError(
            try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.PushPullRolloutError,
                .nonEmptyDraft(sessionId: draft.id)
            )
        }
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Session>()).first { $0.id == draft.id })
        XCTAssertEqual(oldCycle.currentDayIndex, 0)
        XCTAssertNil(
            try context.fetch(FetchDescriptor<TrainingPreference>())
                .first { $0.key == BootstrapDataService.pushPullRolloutMarkerKey }
        )
    }

    func testAuthorizedRolloutRefusesNonemptyAdaptiveDraftBeforeSeedingCatalog() throws {
        let (_, context) = makeContext()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID())
        context.insert(adaptive)
        context.insert(
            AdaptiveSetEntry(
                adaptiveSessionId: adaptive.id,
                occurrenceId: UUID(),
                exerciseId: UUID(),
                setIndex: 1,
                weight: 0,
                reps: 0,
                isLocked: true
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.PushPullRolloutError,
                .nonEmptyDraft(sessionId: adaptive.id)
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).first?.id,
            adaptive.id
        )
    }

    func testArchivedDraftRolloutPreservesLockedAdaptiveWorkAndStartsPushA() throws {
        let (_, context) = makeContext()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let oldTemplate = try BootstrapDataService.defaultStarterTemplate(exercises: exercises)
        context.insert(oldTemplate)
        let oldCycle = ActiveCycleInstance(templateId: oldTemplate.id, currentDayIndex: 0)
        context.insert(oldCycle)
        let archivedFixedDraft = Session(cycleInstanceId: oldCycle.id, cycleDayIndex: 0)
        context.insert(archivedFixedDraft)
        context.insert(
            SetEntry(
                sessionId: archivedFixedDraft.id,
                exerciseId: try XCTUnwrap(exercises.first).id,
                setIndex: 1,
                weight: 45,
                reps: 10,
                isLocked: false
            )
        )

        let plan = GeneratedWorkoutPlan(
            localDateKey: "2026-07-27",
            timeZoneIdentifier: "America/Los_Angeles",
            status: .inProgress,
            adaptiveProgramId: UUID(),
            adaptiveProgramVersion: 1,
            readinessCheckId: UUID(),
            plannerVersion: 1,
            reasonCodes: [],
            complexes: []
        )
        context.insert(plan)
        let adaptiveDraft = AdaptiveWorkoutSession(generatedPlanId: plan.id)
        context.insert(adaptiveDraft)
        let occurrenceId = UUID()
        let exerciseId = try XCTUnwrap(exercises.first).id
        context.insert(
            AdaptiveSetEntry(
                adaptiveSessionId: adaptiveDraft.id,
                occurrenceId: occurrenceId,
                exerciseId: exerciseId,
                setIndex: 1,
                weight: 80,
                reps: 12,
                isLocked: true
            )
        )
        let editablePrefill = AdaptiveSetEntry(
            adaptiveSessionId: adaptiveDraft.id,
            occurrenceId: occurrenceId,
            exerciseId: exerciseId,
            setIndex: 2,
            weight: 80,
            reps: 10,
            isLocked: false
        )
        context.insert(editablePrefill)
        try context.save()

        let result = try BootstrapDataService.preparePushPullABRollout(
            modelContext: context,
            archivedDraftsConfirmed: true
        )
        let cycle = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ActiveCycleInstance>())
                .first { $0.id == result.cycleId }
        )
        let template = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CycleTemplate>())
                .first { $0.id == result.templateId }
        )

        XCTAssertEqual(cycle.currentDayIndex, 1)
        XCTAssertEqual(CycleOrdering.sortedDays(template.days)[cycle.currentDayIndex].label, "Push A")
        XCTAssertEqual(adaptiveDraft.status, .completed)
        XCTAssertEqual(plan.status, .completed)
        XCTAssertNotNil(adaptiveDraft.finishedAt)
        XCTAssertNil(
            try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
                .first { $0.id == editablePrefill.id }
        )
        XCTAssertNil(
            try context.fetch(FetchDescriptor<Session>())
                .first { $0.id == archivedFixedDraft.id }
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
                .filter { $0.adaptiveSessionId == adaptiveDraft.id }.count,
            1
        )
    }

    func testFirstAuthorizedRolloutResetsExistingUnmarkedPushPullCycleThenMarkerPreventsRewind() throws {
        let (_, context) = makeContext()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try BootstrapDataService.pushPullABTemplate(
            exercises: exercises,
            sourceTemplate: nil
        )
        context.insert(template)
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 3)
        context.insert(cycle)
        context.insert(TrainingPreference(modeRawValue: TrainingMode.rotation.rawValue))
        try context.save()
        UserDefaults.standard.set(
            template.id.uuidString,
            forKey: "openlift.lastActivatedTemplateId"
        )

        let first = try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        XCTAssertTrue(first.didApply)
        XCTAssertEqual(cycle.currentDayIndex, 1)

        cycle.currentDayIndex = 2
        try context.save()
        let second = try BootstrapDataService.preparePushPullABRollout(modelContext: context)
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(cycle.currentDayIndex, 2)
    }

    func testJuly27InclineCurlRepairRequiresExplicitBackupConfirmation() throws {
        let (_, context) = makeContext()
        let fixture = try makeJuly27InclineCurlRepairFixture(context: context)

        XCTAssertThrowsError(
            try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.July27AdaptiveInclineCurlRepairError,
                .backupConfirmationRequired
            )
        }

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
                .filter { $0.occurrenceId == fixture.inclineOccurrenceId }.count,
            1
        )
        XCTAssertEqual(fixture.adaptiveSession.exportStatus, .success)
        XCTAssertNil(
            try context.fetch(FetchDescriptor<TrainingPreference>()).first {
                $0.key == BootstrapDataService.july27AdaptiveInclineCurlRepairMarkerKey
            }
        )
    }

    func testJuly27InclineCurlRepairIsExactIdempotentAndPreservesOtherWorkoutAndPushAState() throws {
        let (_, context) = makeContext()
        let fixture = try makeJuly27InclineCurlRepairFixture(context: context)
        let originalOtherEntryId = fixture.otherAdaptiveEntry.id
        let originalOtherWeight = fixture.otherAdaptiveEntry.weight
        let originalOtherReps = fixture.otherAdaptiveEntry.reps
        let originalOtherIsLocked = fixture.otherAdaptiveEntry.isLocked
        let originalFixedEntryId = fixture.fixedEntry.id
        let originalFixedWeight = fixture.fixedEntry.weight
        let originalFixedReps = fixture.fixedEntry.reps
        let originalFixedIsLocked = fixture.fixedEntry.isLocked
        let originalPlanStatus = fixture.plan.status

        let first = try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
            modelContext: context,
            backupConfirmed: true
        )

        XCTAssertTrue(first.didApply)
        XCTAssertEqual(first.sessionId, fixture.adaptiveSession.id)
        let repaired = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter {
                $0.adaptiveSessionId == fixture.adaptiveSession.id
                    && $0.occurrenceId == fixture.inclineOccurrenceId
            }
            .sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(repaired.map(\.setIndex), [1, 2, 3])
        XCTAssertEqual(repaired.map(\.weight), [20, 20, 20])
        XCTAssertEqual(repaired.map(\.reps), [13, 9, 7])
        XCTAssertTrue(repaired.allSatisfy(\.isLocked))
        XCTAssertEqual(fixture.adaptiveSession.exportStatus, .pending)
        XCTAssertEqual(fixture.adaptiveSession.status, .completed)
        XCTAssertEqual(fixture.plan.status, originalPlanStatus)
        XCTAssertEqual(fixture.cycle.currentDayIndex, 1)
        XCTAssertEqual(
            CycleOrdering.sortedDays(fixture.template.days)[fixture.cycle.currentDayIndex].label,
            "Push A"
        )
        XCTAssertEqual(
            TrainingModeService.resolvedMode(
                preferences: try context.fetch(FetchDescriptor<TrainingPreference>())
            ),
            .rotation
        )
        XCTAssertEqual(fixture.otherAdaptiveEntry.id, originalOtherEntryId)
        XCTAssertEqual(fixture.otherAdaptiveEntry.weight, originalOtherWeight)
        XCTAssertEqual(fixture.otherAdaptiveEntry.reps, originalOtherReps)
        XCTAssertEqual(fixture.otherAdaptiveEntry.isLocked, originalOtherIsLocked)
        XCTAssertEqual(fixture.fixedEntry.id, originalFixedEntryId)
        XCTAssertEqual(fixture.fixedEntry.weight, originalFixedWeight)
        XCTAssertEqual(fixture.fixedEntry.reps, originalFixedReps)
        XCTAssertEqual(fixture.fixedEntry.isLocked, originalFixedIsLocked)

        let second = try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
            modelContext: context,
            backupConfirmed: true
        )
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(second.sessionId, first.sessionId)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
                .filter { $0.occurrenceId == fixture.inclineOccurrenceId }.count,
            3
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TrainingPreference>())
                .filter {
                    $0.key == BootstrapDataService.july27AdaptiveInclineCurlRepairMarkerKey
                }.count,
            1
        )
    }

    func testJuly27InclineCurlRepairRefusesUnexpectedRowsWithoutPartialMutation() throws {
        let (_, context) = makeContext()
        let fixture = try makeJuly27InclineCurlRepairFixture(context: context)
        fixture.savedInclineEntry.reps = 12
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
                modelContext: context,
                backupConfirmed: true
            )
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.July27AdaptiveInclineCurlRepairError,
                .unexpectedExistingSets
            )
        }
        let rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter { $0.occurrenceId == fixture.inclineOccurrenceId }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reps, 12)
        XCTAssertEqual(fixture.adaptiveSession.exportStatus, .success)
        XCTAssertEqual(fixture.cycle.currentDayIndex, 1)
        XCTAssertNil(
            try context.fetch(FetchDescriptor<TrainingPreference>()).first {
                $0.key == BootstrapDataService.july27AdaptiveInclineCurlRepairMarkerKey
            }
        )
    }

    @MainActor
    func testJuly27InclineCurlRepairRetriesAndReplacesCanonicalAdaptiveExport() throws {
        let (_, context) = makeContext()
        let fixture = try makeJuly27InclineCurlRepairFixture(context: context)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLiftJuly27CurlRepair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = SessionExportService.ExportEnvironment(
            containerIdentifier: "iCloud.test.openlift",
            iCloudContainerURL: root.appendingPathComponent("iCloud", isDirectory: true),
            localDocumentsURL: root.appendingPathComponent("Documents", isDirectory: true),
            coordinatedWrite: { data, url in
                try data.write(to: url, options: [.atomic])
            },
            ubiquityMetadata: { _ in
                SessionExportService.UbiquityMetadata(
                    isUbiquitousItem: true,
                    isUploaded: true,
                    isUploading: false,
                    uploadingErrorDescription: nil
                )
            }
        )
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let checks = try context.fetch(FetchDescriptor<DailyReadinessCheck>())
        let readiness = try XCTUnwrap(
            checks.first { $0.id == fixture.plan.readinessCheckId }
        )
        let originalOutcome = try AdaptiveExportService.export(
            plan: fixture.plan,
            session: fixture.adaptiveSession,
            readiness: readiness,
            setEntries: try context.fetch(FetchDescriptor<AdaptiveSetEntry>()),
            exercises: exercises,
            overrides: [],
            feedback: [],
            requireICloudMirror: true,
            environment: environment
        )
        let canonicalURL = try XCTUnwrap(originalOutcome.iCloudDestinationURL)
        let localCanonicalURL = try XCTUnwrap(originalOutcome.localMirrorURL)
        let originalPayload = try XCTUnwrap(
            AdaptiveExportService.decode(Data(contentsOf: canonicalURL))
        )
        let originalInclineSets = originalPayload.plan.complexes
            .flatMap(\.exercises)
            .first { $0.occurrence_id == fixture.inclineOccurrenceId.uuidString }?
            .sets
        XCTAssertEqual(originalInclineSets?.map(\.reps), [13])
        XCTAssertEqual(
            fixture.adaptiveSession.id,
            BootstrapDataService.july27AdaptiveInclineCurlSessionId
        )
        XCTAssertEqual(
            fixture.savedInclineEntry.exerciseId,
            BootstrapDataService.july27AdaptiveInclineCurlExerciseId
        )

        // Reproduce the live state: multiple valid local fallback files for
        // the same session, all containing only the first saved curl set.
        let staleData = try Data(contentsOf: localCanonicalURL)
        let localDirectory = localCanonicalURL.deletingLastPathComponent()
        let staleURLs = [
            localDirectory.appendingPathComponent("workout-stale-copy-1.json"),
            localDirectory.appendingPathComponent("workout-stale-copy-2.json")
        ]
        for url in staleURLs {
            try staleData.write(to: url, options: [.atomic])
        }

        _ = try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
            modelContext: context,
            backupConfirmed: true
        )
        XCTAssertEqual(fixture.adaptiveSession.exportStatus, .pending)
        let retryOutcome = try AdaptiveExportService.retryCompletedSessionExport(
            sessionId: fixture.adaptiveSession.id,
            modelContext: context,
            environment: environment
        )

        XCTAssertEqual(retryOutcome.status, .success)
        XCTAssertEqual(retryOutcome.iCloudDestinationURL, canonicalURL)
        XCTAssertEqual(fixture.adaptiveSession.exportStatus, .success)
        let repairedPayload = try XCTUnwrap(
            AdaptiveExportService.decode(Data(contentsOf: canonicalURL))
        )
        let repairedInclineSets = try XCTUnwrap(
            repairedPayload.plan.complexes
                .flatMap(\.exercises)
                .first { $0.occurrence_id == fixture.inclineOccurrenceId.uuidString }?
                .sets
        )
        XCTAssertEqual(repairedInclineSets.map(\.set_index), [1, 2, 3])
        XCTAssertEqual(repairedInclineSets.map(\.weight), [20, 20, 20])
        XCTAssertEqual(repairedInclineSets.map(\.reps), [13, 9, 7])
        XCTAssertTrue(repairedInclineSets.allSatisfy(\.is_locked))
        for url in [localCanonicalURL] + staleURLs {
            let copy = try XCTUnwrap(
                AdaptiveExportService.decode(Data(contentsOf: url))
            )
            let copyInclineSets = try XCTUnwrap(
                copy.plan.complexes
                    .flatMap(\.exercises)
                    .first { $0.occurrence_id == fixture.inclineOccurrenceId.uuidString }?
                    .sets
            )
            XCTAssertEqual(copyInclineSets.map(\.reps), [13, 9, 7])
        }

        let firstRepairedCanonicalData = try Data(contentsOf: canonicalURL)
        let repeatedOutcome = try AdaptiveExportService.retryCompletedSessionExport(
            sessionId: fixture.adaptiveSession.id,
            modelContext: context,
            environment: environment
        )
        XCTAssertEqual(repeatedOutcome.status, .success)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), firstRepairedCanonicalData)
        for url in [localCanonicalURL] + staleURLs {
            XCTAssertEqual(try Data(contentsOf: url), firstRepairedCanonicalData)
        }
    }

    func testPushPullMigrationCopiesVariantSpecificAccessorySelections() throws {
        let (_, context) = makeContext()
        var exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        func custom(_ name: String, _ muscle: MuscleGroup) -> Exercise {
            Exercise(
                name: name,
                primaryMuscle: muscle,
                type: .isolation,
                equipment: .cable
            )
        }
        let bicepsA = custom("Migration Biceps A", .biceps)
        let bicepsB = custom("Migration Biceps B", .biceps)
        let quadsA = custom("Migration Quads A", .quads)
        let quadsB = custom("Migration Quads B", .quads)
        let hamstringsA = custom("Migration Hamstrings A", .hamstrings)
        let hamstringsB = custom("Migration Hamstrings B", .hamstrings)
        exercises += [bicepsA, bicepsB, quadsA, quadsB, hamstringsA, hamstringsB]

        let source = CycleTemplate(
            name: "Existing A/B",
            days: [
                CycleDay(
                    label: "Upper A",
                    slots: [CycleSlot(position: 0, muscle: .biceps, exerciseId: bicepsA.id)],
                    position: 0
                ),
                CycleDay(
                    label: "Lower A",
                    slots: [
                        CycleSlot(position: 0, muscle: .quads, exerciseId: quadsA.id),
                        CycleSlot(position: 1, muscle: .hamstrings, exerciseId: hamstringsA.id)
                    ],
                    position: 1
                ),
                CycleDay(
                    label: "Upper B",
                    slots: [CycleSlot(position: 0, muscle: .biceps, exerciseId: bicepsB.id)],
                    position: 2
                ),
                CycleDay(
                    label: "Lower B",
                    slots: [
                        CycleSlot(position: 0, muscle: .quads, exerciseId: quadsB.id),
                        CycleSlot(position: 1, muscle: .hamstrings, exerciseId: hamstringsB.id)
                    ],
                    position: 3
                )
            ]
        )
        let migrated = try BootstrapDataService.pushPullABTemplate(
            exercises: exercises,
            sourceTemplate: source
        )
        let days: [String: CycleDay] = Dictionary(
            uniqueKeysWithValues: migrated.days.map { ($0.label, $0) }
        )

        XCTAssertTrue(days["Pull A"]?.slots.contains { $0.exerciseId == bicepsA.id } == true)
        XCTAssertTrue(days["Pull A"]?.slots.contains { $0.exerciseId == hamstringsA.id } == true)
        XCTAssertTrue(days["Push A"]?.slots.contains { $0.exerciseId == quadsA.id } == true)
        XCTAssertTrue(days["Pull B"]?.slots.contains { $0.exerciseId == bicepsB.id } == true)
        XCTAssertTrue(days["Pull B"]?.slots.contains { $0.exerciseId == hamstringsB.id } == true)
        XCTAssertTrue(days["Push B"]?.slots.contains { $0.exerciseId == quadsB.id } == true)
    }

    func testPushPullMigrationUsesActiveAdaptiveAccessorySelectionsForBothVariants() throws {
        let (_, context) = makeContext()
        var exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let biceps = Exercise(
            name: "Current Adaptive Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .cable
        )
        let calves = Exercise(
            name: "Current Adaptive Calf Raise",
            primaryMuscle: .calves,
            type: .isolation,
            equipment: .machine
        )
        exercises += [biceps, calves]
        let adaptiveProgram = AdaptiveProgram(
            version: 1,
            name: "Current Adaptive",
            globalMaxMovements: 8,
            maxDifficultyCost: 20,
            muscleRules: [],
            complexes: [
                AdaptiveExerciseComplex(
                    version: 1,
                    name: "Biceps",
                    position: 0,
                    primaryMuscle: .biceps,
                    qualifiesForPrimaryFloor: true,
                    components: [
                        AdaptiveComplexComponent(
                            position: 0,
                            exerciseId: biceps.id,
                            prescribedSetCount: 2,
                            primaryMuscle: .biceps,
                            difficulty: .easy
                        )
                    ]
                ),
                AdaptiveExerciseComplex(
                    version: 1,
                    name: "Calves",
                    position: 1,
                    primaryMuscle: .calves,
                    qualifiesForPrimaryFloor: true,
                    components: [
                        AdaptiveComplexComponent(
                            position: 0,
                            exerciseId: calves.id,
                            prescribedSetCount: 4,
                            primaryMuscle: .calves,
                            difficulty: .easy
                        )
                    ]
                )
            ]
        )

        let template = try BootstrapDataService.pushPullABTemplate(
            exercises: exercises,
            sourceTemplate: nil,
            sourceAdaptiveProgram: adaptiveProgram
        )
        let days: [String: CycleDay] = Dictionary(
            uniqueKeysWithValues: template.days.map { ($0.label, $0) }
        )

        for label in ["Pull A", "Pull B"] {
            let slot = try XCTUnwrap(days[label]?.slots.first { $0.muscle == .biceps })
            XCTAssertEqual(slot.exerciseId, biceps.id)
            XCTAssertEqual(slot.defaultSetCount, 2)
        }
        for label in ["Push A", "Push B"] {
            let slot = try XCTUnwrap(days[label]?.slots.first { $0.muscle == .calves })
            XCTAssertEqual(slot.exerciseId, calves.id)
            XCTAssertEqual(slot.defaultSetCount, 3)
        }
    }

    func testPushAReadinessCapturesWholeCycleMusclesWithUntouchedRecoveredDefaults() throws {
        let (_, context) = makeContext()
        let exercise = Exercise(
            name: "Test Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let day = CycleDay(
            label: "Push A",
            slots: [
                CycleSlot(position: 0, muscle: .chest, exerciseId: exercise.id),
                CycleSlot(position: 1, muscle: .triceps, exerciseId: exercise.id)
            ]
        )
        let pullDay = CycleDay(
            label: "Pull A",
            slots: [
                CycleSlot(position: 0, muscle: .back, exerciseId: exercise.id),
                CycleSlot(position: 1, muscle: .biceps, exerciseId: exercise.id),
                CycleSlot(position: 2, muscle: .hamstrings, exerciseId: exercise.id)
            ]
        )
        let template = CycleTemplate(name: "Push/Pull", days: [day, pullDay])
        let session = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        let calendar = utcCalendar
        let firstDate = Date(timeIntervalSince1970: 1_769_299_200) // 2026-01-25 UTC
        let nextDate = calendar.date(byAdding: .day, value: 1, to: firstDate)!
        // Mirrors the view layer, which pre-fills every tracked muscle at its
        // recovered default so an untouched submit stays a single tap.
        let ready = Dictionary(
            uniqueKeysWithValues: FixedCycleWorkoutService
                .readinessMuscles(for: template, targeting: day)
                .map { ($0, FixedCycleWorkoutService.allClear) }
        )
        let first = try FixedCycleWorkoutService.makeReadinessObservation(
            sessionId: session.id,
            template: template,
            day: day,
            inputs: ready,
            existing: [],
            now: firstDate,
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        context.insert(first)
        try context.save()
        let revision = try FixedCycleWorkoutService.makeReadinessObservation(
            sessionId: session.id,
            template: template,
            day: day,
            inputs: ready,
            existing: [first],
            now: firstDate.addingTimeInterval(60),
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let tomorrow = try FixedCycleWorkoutService.makeReadinessObservation(
            sessionId: session.id,
            template: template,
            day: day,
            inputs: ready,
            existing: [first, revision],
            now: nextDate,
            calendar: calendar,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(revision.revision, 2)
        XCTAssertEqual(tomorrow.revision, 1)
        XCTAssertEqual(
            FixedCycleWorkoutService.readinessMuscles(for: template, targeting: day),
            [.chest, .triceps, .back, .hamstrings, .biceps]
        )
        XCTAssertEqual(
            Set(first.responses.map(\.muscle)),
            Set([.chest, .triceps, .back, .hamstrings, .biceps])
        )
        XCTAssertTrue(first.responses.contains { $0.muscle == .back })
        XCTAssertTrue(first.responses.contains { $0.muscle == .biceps })
        XCTAssertTrue(first.responses.contains { $0.muscle == .hamstrings })
        XCTAssertFalse(first.responses.contains { $0.muscle == .traps })
        XCTAssertTrue(first.responses.allSatisfy {
            $0.soreness == .none
                && $0.connectiveTissuePain == .none
                && $0.eagerness == nil
        })
        XCTAssertTrue(
            FixedCycleWorkoutService.canExecute(
                sessionId: session.id,
                now: firstDate,
                observations: [first],
                calendar: calendar
            )
        )
        XCTAssertFalse(
            FixedCycleWorkoutService.canExecute(
                sessionId: session.id,
                now: nextDate,
                observations: [first],
                calendar: calendar
            )
        )
        XCTAssertFalse(FixedCycleWorkoutService.hasQualifyingSet(sessionId: session.id, entries: []))
    }

    func testFixedReadinessThrowsWhenATrackedMuscleInputIsMissing() throws {
        let exercise = Exercise(
            name: "Test Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let day = CycleDay(
            label: "Push A",
            slots: [CycleSlot(position: 0, muscle: .chest, exerciseId: exercise.id)]
        )
        let pullDay = CycleDay(
            label: "Pull A",
            slots: [CycleSlot(position: 0, muscle: .back, exerciseId: exercise.id)]
        )
        let template = CycleTemplate(name: "Push/Pull", days: [day, pullDay])
        let session = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        // Back is trained on another day of the cycle, so it is required today.
        // The view pre-fills this row, while the service still validates callers.
        let partial: [MuscleGroup: MuscleReadinessInput] = [
            .chest: FixedCycleWorkoutService.allClear
        ]

        XCTAssertThrowsError(
            try FixedCycleWorkoutService.makeReadinessObservation(
                sessionId: session.id,
                template: template,
                day: day,
                inputs: partial,
                eagerness: .reluctant,
                existing: [],
                now: Date(timeIntervalSince1970: 1_769_299_200),
                calendar: utcCalendar,
                timeZone: TimeZone(identifier: "UTC")!
            )
        ) { error in
            XCTAssertEqual(
                error as? FixedCycleWorkoutError,
                .incompleteReadiness(.back)
            )
        }
    }

    func testFixedReadinessFromEarlierSessionSatisfiesLaterDraftOnSameLocalDate() {
        let earlierSessionId = UUID()
        let laterSessionId = UUID()
        let date = Date(timeIntervalSince1970: 1_769_299_200)
        let observation = FixedCycleReadinessObservation(
            sessionId: earlierSessionId,
            localDateKey: FixedCycleWorkoutService.localDateKey(
                for: date,
                calendar: utcCalendar
            ),
            timeZoneIdentifier: "UTC",
            revision: 1,
            createdAt: date,
            responses: []
        )

        XCTAssertEqual(
            FixedCycleWorkoutService.latestObservation(
                sessionId: laterSessionId,
                localDateKey: observation.localDateKey,
                observations: [observation]
            )?.id,
            observation.id
        )
        XCTAssertTrue(
            FixedCycleWorkoutService.canExecute(
                sessionId: laterSessionId,
                now: date,
                observations: [observation],
                calendar: utcCalendar
            )
        )
    }

    func testFixedReadinessFromPriorDateDoesNotSatisfyLaterDraftToday() {
        let earlierSessionId = UUID()
        let laterSessionId = UUID()
        let priorDate = Date(timeIntervalSince1970: 1_769_299_200)
        let today = priorDate.addingTimeInterval(24 * 60 * 60)
        let observation = FixedCycleReadinessObservation(
            sessionId: earlierSessionId,
            localDateKey: FixedCycleWorkoutService.localDateKey(
                for: priorDate,
                calendar: utcCalendar
            ),
            timeZoneIdentifier: "UTC",
            revision: 1,
            createdAt: priorDate,
            responses: []
        )

        XCTAssertNil(
            FixedCycleWorkoutService.latestObservation(
                sessionId: laterSessionId,
                localDateKey: FixedCycleWorkoutService.localDateKey(
                    for: today,
                    calendar: utcCalendar
                ),
                observations: [observation]
            )
        )
        XCTAssertFalse(
            FixedCycleWorkoutService.canExecute(
                sessionId: laterSessionId,
                now: today,
                observations: [observation],
                calendar: utcCalendar
            )
        )
    }

    func testFixedReadinessPrefersCurrentSessionObservationOverDayScopedFallback() {
        let currentSessionId = UUID()
        let otherSessionId = UUID()
        let date = Date(timeIntervalSince1970: 1_769_299_200)
        let dateKey = FixedCycleWorkoutService.localDateKey(
            for: date,
            calendar: utcCalendar
        )
        let currentSessionObservation = FixedCycleReadinessObservation(
            sessionId: currentSessionId,
            localDateKey: dateKey,
            timeZoneIdentifier: "UTC",
            revision: 1,
            createdAt: date,
            responses: []
        )
        let newerFallback = FixedCycleReadinessObservation(
            sessionId: otherSessionId,
            localDateKey: dateKey,
            timeZoneIdentifier: "UTC",
            revision: 99,
            createdAt: date.addingTimeInterval(60),
            responses: []
        )

        XCTAssertEqual(
            FixedCycleWorkoutService.latestObservation(
                sessionId: currentSessionId,
                localDateKey: dateKey,
                observations: [currentSessionObservation, newerFallback]
            )?.id,
            currentSessionObservation.id
        )
    }

    func testFixedSystemicEagernessPersistsOnlyOnObservation() throws {
        let exercise = Exercise(
            name: "Test Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let day = CycleDay(
            label: "Push A",
            slots: [CycleSlot(position: 0, muscle: .chest, exerciseId: exercise.id)]
        )
        let pullDay = CycleDay(
            label: "Pull A",
            slots: [CycleSlot(position: 0, muscle: .back, exerciseId: exercise.id)]
        )
        let template = CycleTemplate(name: "Push/Pull", days: [day, pullDay])
        let inputs: [MuscleGroup: MuscleReadinessInput] = [
            .chest: .init(soreness: .mild, connectiveTissuePain: .none, eagerness: .eager),
            .back: .init(soreness: .none, connectiveTissuePain: .caution, eagerness: .neutral)
        ]

        let observation = try FixedCycleWorkoutService.makeReadinessObservation(
            sessionId: UUID(),
            template: template,
            day: day,
            inputs: inputs,
            eagerness: .reluctant,
            existing: [],
            now: Date(timeIntervalSince1970: 1_769_299_200),
            calendar: utcCalendar,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(Set(observation.responses.map(\.muscle)), Set([.chest, .back]))
        XCTAssertEqual(observation.systemicEagerness, .reluctant)
        XCTAssertTrue(observation.responses.allSatisfy { $0.eagerness == nil })
    }

    func testFixedReadinessEagernessResolverFallsBackToLegacyResponses() {
        let observation = FixedCycleReadinessObservation(
            sessionId: UUID(),
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            responses: [
                FixedCycleReadinessResponse(
                    muscle: .chest,
                    soreness: .none,
                    connectiveTissuePain: .none,
                    eagerness: .neutral
                ),
                FixedCycleReadinessResponse(
                    muscle: .back,
                    soreness: .none,
                    connectiveTissuePain: .none,
                    eagerness: .reluctant
                )
            ]
        )

        XCTAssertEqual(ReadinessEagernessResolver.resolve(observation), .reluctant)
    }

    func testFixedCycleLookupKeepsSeparateDayBaselinesAndSkipsZeroOccurrences() {
        let exerciseId = UUID()
        let cycleId = UUID()
        let pullA = completedSession(
            cycleId: cycleId,
            day: 0,
            name: "Push/Pull A/B",
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let skippedPullA = completedSession(
            cycleId: cycleId,
            day: 0,
            name: "Push/Pull A/B",
            finishedAt: Date(timeIntervalSince1970: 300)
        )
        let pullB = completedSession(
            cycleId: cycleId,
            day: 2,
            name: "Push/Pull A/B",
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let entries =
            lockedRows(sessionId: pullA.id, exerciseId: exerciseId, count: 3)
            + lockedRows(sessionId: pullB.id, exerciseId: exerciseId, count: 5)

        let a = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseId,
            cycleInstanceId: cycleId,
            cycleDayIndex: 0,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: [pullA, pullB, skippedPullA],
            rotationSetEntries: entries
        )
        let b = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseId,
            cycleInstanceId: cycleId,
            cycleDayIndex: 2,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: [pullA, pullB, skippedPullA],
            rotationSetEntries: entries
        )

        XCTAssertEqual(a?.rows.count, 3)
        XCTAssertEqual(a?.sessionId, pullA.id)
        XCTAssertEqual(a?.matchKind, .sameCycleDay)
        XCTAssertEqual(b?.rows.count, 5)
        XCTAssertEqual(b?.sessionId, pullB.id)
    }

    func testFixedCycleSameDayLookupUsesStableCycleIdentityNotTemplateName() {
        let exerciseId = UUID()
        let targetCycle = UUID()
        let otherCycle = UUID()
        let target = completedSession(
            cycleId: targetCycle,
            day: 0,
            name: "Same Display Name",
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let other = completedSession(
            cycleId: otherCycle,
            day: 0,
            name: "Same Display Name",
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let result = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseId,
            cycleInstanceId: targetCycle,
            cycleDayIndex: 0,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: [target, other],
            rotationSetEntries:
                lockedRows(sessionId: target.id, exerciseId: exerciseId, count: 3)
                + lockedRows(sessionId: other.id, exerciseId: exerciseId, count: 5)
        )

        XCTAssertEqual(result?.sessionId, target.id)
        XCTAssertEqual(result?.rows.count, 3)
        XCTAssertEqual(result?.matchKind, .sameCycleDay)
    }

    func testFixedCycleLookupFallsBackAcrossAdHocAndAdaptiveWithStableTieBreak() {
        let exerciseId = UUID()
        let adHoc = completedSession(
            cycleId: UUID(),
            day: 0,
            name: "Off-Schedule",
            label: "Off-Schedule",
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let adaptive = AdaptiveWorkoutSession(
            generatedPlanId: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 300),
            status: .completed
        )
        let adaptiveRow = AdaptiveSetEntry(
            adaptiveSessionId: adaptive.id,
            occurrenceId: UUID(),
            exerciseId: exerciseId,
            setIndex: 1,
            weight: 99,
            reps: 7,
            isLocked: true
        )
        let result = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseId,
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            adaptiveSessions: [adaptive],
            adaptiveSetEntries: [adaptiveRow],
            rotationSessions: [adHoc],
            rotationSetEntries: lockedRows(
                sessionId: adHoc.id,
                exerciseId: exerciseId,
                count: 4
            )
        )

        XCTAssertEqual(result?.matchKind, .globalLatest)
        XCTAssertEqual(result?.sourceKind, .adaptive)
        XCTAssertEqual(result?.rows.map(\.weight), [99])
    }

    func testImportedExerciseIdentityPrefersStableIdAndUsesOnlySafeLegacyAliases() {
        let canonical = Exercise(
            name: "Single-Arm Dumbbell Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .dumbbell
        )
        let distinct = Exercise(
            name: "Incline Cable Flye",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let byId = [canonical.id: canonical, distinct.id: distinct]
        let byName = Dictionary(
            uniqueKeysWithValues: [canonical, distinct].map { ($0.name.lowercased(), $0) }
        )

        XCTAssertEqual(
            BootstrapDataService.resolveImportedExercise(
                id: canonical.id,
                name: "Renamed Historical Display",
                byId: byId,
                byName: byName
            )?.id,
            canonical.id
        )
        XCTAssertEqual(
            BootstrapDataService.resolveImportedExercise(
                id: nil,
                name: "Single Arm DB Row",
                byId: byId,
                byName: byName
            )?.id,
            canonical.id
        )
        XCTAssertNil(
            BootstrapDataService.resolveImportedExercise(
                id: nil,
                name: "Cable Fly",
                byId: byId,
                byName: byName
            )
        )
    }

    func testFixedCycleExportHydrationPreservesIdentityOrderReadinessAndSkip() throws {
        let (_, context) = makeContext()
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let first = try XCTUnwrap(catalog.first { $0.name == "Lat Pulldown" })
        let second = try XCTUnwrap(catalog.first { $0.name == "Chest-Supported Cable Row" })
        let day = CycleDay(
            label: "Pull A",
            slots: [
                CycleSlot(position: 0, muscle: .back, exerciseId: first.id),
                CycleSlot(position: 1, muscle: .back, exerciseId: second.id)
            ]
        )
        let otherDay = CycleDay(
            label: "Pull B",
            slots: [
                CycleSlot(position: 0, muscle: .biceps, exerciseId: first.id),
                CycleSlot(position: 1, muscle: .hamstrings, exerciseId: second.id)
            ]
        )
        let template = CycleTemplate(name: "Push/Pull A/B", days: [day, otherDay])
        context.insert(template)
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)
        context.insert(cycle)
        try context.save()
        let source = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label,
            finishedAt: Date(timeIntervalSince1970: 100),
            status: .completed
        )
        let row = SetEntry(
            sessionId: source.id,
            exerciseId: first.id,
            setIndex: 1,
            weight: 80,
            reps: 10,
            isLocked: true
        )
        let trackedReadinessMuscles = FixedCycleWorkoutService.readinessMuscles(
            for: template,
            targeting: day
        )
        let readiness = FixedCycleReadinessObservation(
            sessionId: source.id,
            localDateKey: "2026-07-27",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            responses: trackedReadinessMuscles.map { muscle in
                FixedCycleReadinessResponse(
                    muscle: muscle,
                    soreness: muscle == .back ? .mild : .none,
                    connectiveTissuePain: .none,
                    eagerness: muscle == .back ? .neutral : .eager
                )
            }
        )
        let skip = FixedCycleOccurrenceOverride(
            sessionId: source.id,
            kind: .skipExercise,
            slotPosition: 1,
            exerciseId: second.id,
            muscle: .back,
            reasonCode: "time"
        )
        let metadata = SessionExportService.fixedCycleMetadata(
            session: source,
            template: template,
            day: day,
            exercises: catalog,
            setEntries: [row],
            readiness: [readiness],
            overrides: [skip]
        )
        XCTAssertEqual(metadata.ordered_exercises.map(\.exercise_id), [
            first.id.uuidString, second.id.uuidString
        ])
        XCTAssertEqual(metadata.ordered_exercises.map(\.status), ["completed", "skipped"])
        XCTAssertEqual(
            Set(metadata.readiness.first?.responses.map(\.muscle) ?? []),
            Set(trackedReadinessMuscles.map(\.rawValue))
        )

        let payload = SessionExportService.ExportPayload(
            session_id: source.id.uuidString,
            cycle_name: template.name,
            cycle_day_index: 0,
            date: ISO8601DateFormatter().string(from: source.finishedAt!),
            exercises: [
                SessionExportService.ExportExercise(
                    exercise_id: first.id.uuidString,
                    exercise_name: "Legacy display name that must not win",
                    muscle: MuscleGroup.back.rawValue,
                    sets: [
                        SessionExportService.ExportSet(set_index: 1, weight: 80, reps: 10)
                    ]
                )
            ],
            workout_kind: "rotation",
            fixed_cycle: metadata
        )
        let result = try BootstrapDataService.reconcileWorkoutExports(
            [payload],
            cycle: cycle,
            modelContext: context
        )
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleExerciseSnapshot>())
                .filter { $0.sessionId == source.id }
                .sorted { $0.position < $1.position }
                .map(\.exerciseId),
            [first.id, second.id]
        )
        let hydratedReadiness = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FixedCycleReadinessObservation>())
                .first { $0.sessionId == source.id }
        )
        XCTAssertEqual(hydratedReadiness.localDateKey, "2026-07-27")
        XCTAssertEqual(
            Set(hydratedReadiness.responses.map(\.muscle)),
            Set(trackedReadinessMuscles)
        )
        XCTAssertEqual(
            hydratedReadiness.responses.first(where: { $0.muscle == .back })?.soreness,
            .mild
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleOccurrenceOverride>())
                .first { $0.sessionId == source.id }?
                .reasonCode,
            "time"
        )
    }

    func testLegacyPartialFixedReadinessHydrationDoesNotFabricateMissingMuscles() throws {
        let (_, context) = makeContext()
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let exercise = try XCTUnwrap(catalog.first { $0.primaryMuscle == .back })
        let day = CycleDay(
            label: "Pull A",
            slots: [CycleSlot(position: 0, muscle: .back, exerciseId: exercise.id)]
        )
        let template = CycleTemplate(name: "Legacy Partial Fixture", days: [day])
        context.insert(template)
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)
        context.insert(cycle)
        try context.save()

        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label,
            finishedAt: Date(timeIntervalSince1970: 200),
            status: .completed
        )
        let partial = FixedCycleReadinessObservation(
            sessionId: session.id,
            localDateKey: "2026-07-26",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            responses: [
                FixedCycleReadinessResponse(
                    muscle: .back,
                    soreness: .moderate,
                    connectiveTissuePain: .caution,
                    eagerness: .reluctant
                )
            ]
        )
        let metadata = SessionExportService.fixedCycleMetadata(
            session: session,
            template: template,
            day: day,
            exercises: catalog,
            setEntries: [],
            readiness: [partial],
            overrides: []
        )
        let payload = SessionExportService.ExportPayload(
            session_id: session.id.uuidString,
            cycle_name: template.name,
            cycle_day_index: 0,
            date: ISO8601DateFormatter().string(from: session.finishedAt!),
            exercises: [],
            workout_kind: "rotation",
            fixed_cycle: metadata
        )

        XCTAssertEqual(
            try BootstrapDataService.reconcileWorkoutExports(
                [payload],
                cycle: cycle,
                modelContext: context
            ).imported,
            1
        )
        let hydrated = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FixedCycleReadinessObservation>())
                .first { $0.sessionId == session.id }
        )
        XCTAssertEqual(hydrated.responses.map(\.muscle), [.back])
        XCTAssertNil(hydrated.responses.first { $0.muscle == .chest })
    }

    func testAdaptiveRepeatLastUsesExactCompletedSetCount() throws {
        let (_, context) = makeContext()
        let exercise = Exercise(
            name: "Literal Dose Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let previous = completedSession(
            cycleId: UUID(),
            day: 0,
            name: "Old Cycle",
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let snapshot = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: .chest,
            difficulty: .hard,
            prescribedSetCount: 4
        )
        let complex = PlannedComplexSnapshot(
            sourceDefinitionId: UUID(),
            sourceVersion: 1,
            position: 0,
            name: "Chest",
            primaryMuscle: .chest,
            reasonCodes: [],
            exercises: [snapshot]
        )
        let plan = GeneratedWorkoutPlan(
            localDateKey: "2026-07-27",
            timeZoneIdentifier: "America/Los_Angeles",
            status: .proposed,
            adaptiveProgramId: UUID(),
            adaptiveProgramVersion: 1,
            readinessCheckId: UUID(),
            plannerVersion: 1,
            reasonCodes: [],
            complexes: [complex]
        )
        let rows = lockedRows(sessionId: previous.id, exerciseId: exercise.id, count: 1)

        AdaptivePrefillService.applyRepeatLastSetCounts(
            to: plan,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: [previous],
            rotationSetEntries: rows
        )
        XCTAssertEqual(snapshot.prescribedSetCount, 1)

        context.insert(plan)
        let session = try AdaptiveWorkoutService.freeze(
            plan: plan,
            modelContext: context,
            prefill: AdaptivePrefillService.prefill(
                plan: plan,
                adaptiveSessions: [],
                adaptiveSetEntries: [],
                rotationSessions: [previous],
                rotationSetEntries: rows
            )
        )
        let created = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter { $0.adaptiveSessionId == session.id }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.weight, rows.first?.weight)
        XCTAssertEqual(created.first?.reps, rows.first?.reps)
    }

    func testReadinessRolloverClosesGateWithoutMutatingPartialDraft() {
        let sessionId = UUID()
        let exerciseId = UUID()
        let firstDate = Date(timeIntervalSince1970: 1_769_299_200)
        let nextDate = firstDate.addingTimeInterval(24 * 60 * 60)
        let entry = SetEntry(
            sessionId: sessionId,
            exerciseId: exerciseId,
            setIndex: 1,
            weight: 75,
            reps: 9,
            isLocked: true
        )
        let observation = FixedCycleReadinessObservation(
            sessionId: sessionId,
            localDateKey: FixedCycleWorkoutService.localDateKey(
                for: firstDate,
                calendar: utcCalendar
            ),
            timeZoneIdentifier: "UTC",
            revision: 1,
            createdAt: firstDate,
            responses: []
        )

        XCTAssertTrue(
            FixedCycleWorkoutService.canExecute(
                sessionId: sessionId,
                now: firstDate,
                observations: [observation],
                calendar: utcCalendar
            )
        )
        XCTAssertFalse(
            FixedCycleWorkoutService.canExecute(
                sessionId: sessionId,
                now: nextDate,
                observations: [observation],
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(entry.weight, 75)
        XCTAssertEqual(entry.reps, 9)
        XCTAssertTrue(entry.isLocked)
        XCTAssertTrue(FixedCycleWorkoutService.hasQualifyingSet(sessionId: sessionId, entries: [entry]))
        XCTAssertFalse(FixedCycleWorkoutService.hasQualifyingSet(sessionId: sessionId, entries: []))
    }

    func testPersistentRemovalRetainsPerformedOccurrenceSnapshotAndFutureTemplateOmitsIt() throws {
        let (_, context) = makeContext()
        let performed = Exercise(
            name: "Performed Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let untouched = Exercise(
            name: "Untouched Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let performedSlot = CycleSlot(position: 0, muscle: .back, exerciseId: performed.id)
        let untouchedSlot = CycleSlot(position: 1, muscle: .back, exerciseId: untouched.id)
        let day = CycleDay(label: "Pull A", slots: [performedSlot, untouchedSlot])
        let template = CycleTemplate(name: "Push/Pull A/B", days: [day])
        let cycle = ActiveCycleInstance(templateId: template.id)
        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label
        )
        let row = SetEntry(
            sessionId: session.id,
            exerciseId: performed.id,
            setIndex: 1,
            weight: 80,
            reps: 10,
            isLocked: true
        )
        [performed, untouched].forEach(context.insert)
        context.insert(template)
        context.insert(cycle)
        context.insert(session)
        context.insert(row)

        FixedCycleWorkoutService.stageOccurrenceSnapshotsIfNeeded(
            sessionId: session.id,
            day: day,
            exercises: [performed, untouched],
            existingSnapshots: [],
            modelContext: context
        )
        FixedCycleWorkoutService.removeExercisePersistently(
            slot: performedSlot,
            from: day,
            sessionId: session.id,
            entries: [row],
            modelContext: context
        )
        try context.save()
        let snapshots = try context.fetch(FetchDescriptor<FixedCycleExerciseSnapshot>())
        let metadata = SessionExportService.fixedCycleMetadata(
            session: session,
            template: template,
            day: day,
            exercises: [performed, untouched],
            setEntries: [row],
            readiness: [],
            overrides: [],
            snapshots: snapshots
        )

        XCTAssertFalse(day.slots.contains { $0.exerciseId == performed.id })
        XCTAssertEqual(row.reps, 10)
        XCTAssertEqual(
            metadata.ordered_exercises.first { $0.exercise_id == performed.id.uuidString }?.status,
            "completed"
        )
        XCTAssertEqual(
            metadata.ordered_exercises.first { $0.exercise_id == untouched.id.uuidString }?.status,
            "zero_set"
        )
        XCTAssertEqual(metadata.ordered_exercises.count, 2)
        XCTAssertEqual(metadata.cycle_instance_id, cycle.id.uuidString)
    }

    func testCompletedFixedSnapshotRetryDoesNotConsultLaterTemplateShape() {
        let original = Exercise(
            name: "Original Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let later = Exercise(
            name: "Later Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let day = CycleDay(
            label: "Pull A",
            slots: [CycleSlot(position: 0, muscle: .back, exerciseId: later.id)]
        )
        let template = CycleTemplate(name: "Push/Pull A/B", days: [day])
        let cycle = ActiveCycleInstance(templateId: template.id)
        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: day.label,
            status: .completed
        )
        let snapshot = FixedCycleExerciseSnapshot(
            sessionId: session.id,
            position: 0,
            exerciseId: original.id,
            exerciseName: original.name,
            muscle: .back,
            statusRawValue: "completed"
        )

        let metadata = SessionExportService.fixedCycleMetadata(
            session: session,
            template: template,
            day: day,
            exercises: [original, later],
            setEntries: [],
            readiness: [],
            overrides: [],
            snapshots: [snapshot]
        )

        XCTAssertEqual(
            metadata.ordered_exercises.map { $0.exercise_id },
            [original.id.uuidString]
        )
        XCTAssertEqual(metadata.ordered_exercises.first?.status, "completed")
    }

    func testSkipAndPersistentStructuralEditsAreDayScoped() throws {
        let (_, context) = makeContext()
        let first = Exercise(
            name: "First Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let second = Exercise(
            name: "Second Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let pullASlot = CycleSlot(position: 0, muscle: .back, exerciseId: first.id)
        let pullBSlot = CycleSlot(position: 0, muscle: .back, exerciseId: first.id)
        let pullA = CycleDay(label: "Pull A", slots: [pullASlot])
        let pullB = CycleDay(label: "Pull B", slots: [pullBSlot])
        context.insert(CycleTemplate(name: "Push/Pull A/B", days: [pullA, pullB]))
        let sessionId = UUID()

        FixedCycleWorkoutService.skipExercise(
            slot: pullASlot,
            sessionId: sessionId,
            reasonCode: "recovery",
            entries: [],
            existingOverrides: [],
            modelContext: context
        )
        XCTAssertEqual(pullASlot.exerciseId, first.id)
        XCTAssertEqual(pullBSlot.exerciseId, first.id)

        try FixedCycleWorkoutService.replaceExercise(
            slot: pullASlot,
            with: second,
            sessionId: sessionId,
            entries: [],
            modelContext: context
        )
        XCTAssertEqual(pullASlot.exerciseId, second.id)
        XCTAssertEqual(pullBSlot.exerciseId, first.id)

        let added = try FixedCycleWorkoutService.addMovement(
            exercise: first,
            to: pullA,
            sessionId: sessionId,
            defaultSetCount: 2,
            modelContext: context
        )
        XCTAssertTrue(pullA.slots.contains { $0 === added })
        XCTAssertEqual(pullB.slots.count, 1)
        XCTAssertThrowsError(
            try FixedCycleWorkoutService.addMovement(
                exercise: first,
                to: pullA,
                sessionId: sessionId,
                defaultSetCount: 2,
                modelContext: context
            )
        )

        FixedCycleWorkoutService.removeExercisePersistently(
            slot: added,
            from: pullA,
            sessionId: sessionId,
            entries: [],
            modelContext: context
        )
        XCTAssertFalse(pullA.slots.contains { $0 === added })
        XCTAssertEqual(pullB.slots.count, 1)
    }

    func testPersistentReplacementRetiresLegacyDraftOverrideTransactionally() throws {
        let (_, context) = makeContext()
        let configured = Exercise(
            name: "Configured Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let draftOverrideExercise = Exercise(
            name: "Draft Override Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let replacement = Exercise(
            name: "Replacement Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let slot = CycleSlot(position: 0, muscle: .back, exerciseId: configured.id)
        let sessionId = UUID()
        let override = SessionSlotOverride(
            sessionId: sessionId,
            slotPosition: slot.position,
            exerciseId: draftOverrideExercise.id
        )
        let oldRow = SetEntry(
            sessionId: sessionId,
            exerciseId: draftOverrideExercise.id,
            setIndex: 1,
            weight: 70,
            reps: 10
        )
        [configured, draftOverrideExercise, replacement].forEach(context.insert)
        context.insert(override)
        context.insert(oldRow)
        try context.save()

        try FixedCycleWorkoutService.replaceExercise(
            slot: slot,
            currentExerciseId: draftOverrideExercise.id,
            with: replacement,
            sessionId: sessionId,
            entries: [oldRow],
            slotOverrides: [override],
            modelContext: context
        )
        try context.save()

        XCTAssertEqual(slot.exerciseId, replacement.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionSlotOverride>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 0)
    }

    private struct July27InclineCurlRepairFixture {
        let template: CycleTemplate
        let cycle: ActiveCycleInstance
        let plan: GeneratedWorkoutPlan
        let adaptiveSession: AdaptiveWorkoutSession
        let inclineOccurrenceId: UUID
        let savedInclineEntry: AdaptiveSetEntry
        let otherAdaptiveEntry: AdaptiveSetEntry
        let fixedEntry: SetEntry
    }

    private func makeJuly27InclineCurlRepairFixture(
        context: ModelContext
    ) throws -> July27InclineCurlRepairFixture {
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let inclineCurl = try XCTUnwrap(
            exercises.first { $0.name.caseInsensitiveCompare("Incline Curl") == .orderedSame }
        )
        inclineCurl.id = BootstrapDataService.july27AdaptiveInclineCurlExerciseId
        let otherExercise = try XCTUnwrap(
            exercises.first { $0.name.caseInsensitiveCompare("Lat Pulldown") == .orderedSame }
        )
        let template = try BootstrapDataService.pushPullABTemplate(
            exercises: exercises,
            sourceTemplate: nil
        )
        context.insert(template)
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 1)
        context.insert(cycle)
        context.insert(TrainingPreference(modeRawValue: TrainingMode.rotation.rawValue))
        context.insert(
            TrainingPreference(
                key: BootstrapDataService.pushPullRolloutMarkerKey,
                modeRawValue: template.id.uuidString
            )
        )

        let readiness = DailyReadinessCheck(
            localDateKey: "2026-07-27",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            adaptiveProgramId: UUID(),
            adaptiveProgramVersion: 1,
            responses: MuscleGroup.allCases.map {
                AdaptiveReadinessResponse(
                    muscle: $0,
                    soreness: .none,
                    connectiveTissuePain: .none,
                    eagerness: .neutral
                )
            }
        )
        context.insert(readiness)
        let inclineSnapshot = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: inclineCurl.id,
            exerciseName: inclineCurl.name,
            primaryMuscle: inclineCurl.primaryMuscle,
            difficulty: .easy,
            prescribedSetCount: 3
        )
        let otherSnapshot = PlannedExerciseSnapshot(
            position: 1,
            exerciseId: otherExercise.id,
            exerciseName: otherExercise.name,
            primaryMuscle: otherExercise.primaryMuscle,
            difficulty: .hard,
            prescribedSetCount: 1
        )
        let complex = PlannedComplexSnapshot(
            sourceDefinitionId: UUID(),
            sourceVersion: 1,
            position: 0,
            name: "July 27 Pull",
            primaryMuscle: .back,
            reasonCodes: [],
            exercises: [inclineSnapshot, otherSnapshot]
        )
        let adaptiveSessionId = BootstrapDataService.july27AdaptiveInclineCurlSessionId
        let plan = GeneratedWorkoutPlan(
            localDateKey: "2026-07-27",
            timeZoneIdentifier: "America/Los_Angeles",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            frozenAt: Date(timeIntervalSince1970: 1_775_000_060),
            status: .completed,
            adaptiveProgramId: readiness.adaptiveProgramId,
            adaptiveProgramVersion: readiness.adaptiveProgramVersion,
            readinessCheckId: readiness.id,
            plannerVersion: 1,
            reasonCodes: [],
            sessionId: adaptiveSessionId,
            complexes: [complex]
        )
        context.insert(plan)
        let adaptiveSession = AdaptiveWorkoutSession(
            id: adaptiveSessionId,
            generatedPlanId: plan.id,
            createdAt: plan.createdAt,
            finishedAt: Date(timeIntervalSince1970: 1_775_000_600),
            status: .completed,
            exportStatus: .success
        )
        context.insert(adaptiveSession)
        let savedInclineEntry = AdaptiveSetEntry(
            adaptiveSessionId: adaptiveSession.id,
            occurrenceId: inclineSnapshot.occurrenceId,
            exerciseId: inclineCurl.id,
            setIndex: 1,
            weight: 20,
            reps: 13,
            isLocked: true
        )
        let otherAdaptiveEntry = AdaptiveSetEntry(
            adaptiveSessionId: adaptiveSession.id,
            occurrenceId: otherSnapshot.occurrenceId,
            exerciseId: otherExercise.id,
            setIndex: 1,
            weight: 100,
            reps: 10,
            isLocked: true
        )
        context.insert(savedInclineEntry)
        context.insert(otherAdaptiveEntry)

        let fixedDraft = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 1,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Push A"
        )
        context.insert(fixedDraft)
        let fixedEntry = SetEntry(
            sessionId: fixedDraft.id,
            exerciseId: otherExercise.id,
            setIndex: 1,
            weight: 55,
            reps: 8,
            isLocked: false
        )
        context.insert(fixedEntry)
        try context.save()

        return July27InclineCurlRepairFixture(
            template: template,
            cycle: cycle,
            plan: plan,
            adaptiveSession: adaptiveSession,
            inclineOccurrenceId: inclineSnapshot.occurrenceId,
            savedInclineEntry: savedInclineEntry,
            otherAdaptiveEntry: otherAdaptiveEntry,
            fixedEntry: fixedEntry
        )
    }

    private func makeContext() -> (ModelContainer, ModelContext) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV11.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (container, ModelContext(container))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func completedSession(
        cycleId: UUID,
        day: Int,
        name: String,
        label: String = "Pull",
        finishedAt: Date
    ) -> Session {
        Session(
            cycleInstanceId: cycleId,
            cycleDayIndex: day,
            cycleNameSnapshot: name,
            dayLabelSnapshot: label,
            createdAt: finishedAt.addingTimeInterval(-60),
            finishedAt: finishedAt,
            status: .completed
        )
    }

    private func lockedRows(
        sessionId: UUID,
        exerciseId: UUID,
        count: Int
    ) -> [SetEntry] {
        (1...count).map {
            SetEntry(
                sessionId: sessionId,
                exerciseId: exerciseId,
                setIndex: $0,
                weight: Double(40 + $0),
                reps: 12 - $0,
                isLocked: true
            )
        }
    }
}
