import SwiftData
import XCTest
@testable import OpenLift

final class ExportIntegrityTests: XCTestCase {
    @MainActor
    func testConfirmedClusterProfileCorrectionKeepsLookupAndRecoveryConsistent() throws {
        try assertClusterProfileCorrection(original: .voltra(chainType: .chains,
                                                            chainPercent: 10, eccentricPercent: 20))
    }

    @MainActor
    func testConfirmedUnknownClusterProfileCorrectionKeepsLookupAndRecoveryConsistent() throws {
        try assertClusterProfileCorrection(original: nil)
    }

    @MainActor
    func testExplicitCorrectionReconcilesSnapshotWhenLiveProfileWasAlreadyCorrected() throws {
        try assertClusterProfileCorrection(original: .weightStack, liveAlreadyCorrected: true)
    }

    @MainActor
    private func assertClusterProfileCorrection(original: ResistanceProfileValue?,
                                                liveAlreadyCorrected: Bool = false) throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let context = ModelContext(container)
        let exercise = Exercise(name: "Corrected Row", primaryMuscle: .back,
                                type: .compound, equipment: .cable)
        let cycle = ActiveCycleInstance(templateId: UUID())
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0,
            finishedAt: Date(timeIntervalSince1970: 1000), status: .completed, exportStatus: .success)
        let key = "cluster-row-key"
        let snapshot = ClusterExerciseProgressionSnapshot(position: 0, exerciseId: exercise.id,
            exerciseName: exercise.name, muscle: .back, prescribedSetCount: 1, progressionKey: key,
            resistanceProfile: original, completionStatus: .performed)
        let occurrence = try ClusterOccurrenceRecord(sessionId: session.id,
            cycleInstanceId: cycle.id, templateId: cycle.templateId,
            programVersionID: FixedCycleClusterProgramService.programVersionID,
            clusterID: "cluster-1", positionIndex: 4, templateDayPosition: 0,
            dayLabel: "Frozen day", completedAt: session.finishedAt!, exerciseSnapshots: [snapshot])
        let row = SetEntry(sessionId: session.id, exerciseId: exercise.id,
                           setIndex: 1, weight: 70, reps: 10, isLocked: true)
        context.insert(exercise)
        context.insert(cycle)
        context.insert(session)
        context.insert(occurrence)
        context.insert(row)
        let existing = try original.map { value in
            let profile = try ResistanceProfileService.create(workoutKind: .fixed,
                sessionId: session.id, exerciseId: exercise.id, value: value,
                profiles: [], modelContext: context)
            profile.frozenAt = session.finishedAt
            return profile
        }
        try context.save()
        let corrected = ResistanceProfileValue.voltra(chainType: .inverseChains,
                                                      chainPounds: 35, eccentricPounds: 12.5)
        let correction: (Bool) throws -> Void = { confirmed in
            if let existing {
                try ResistanceProfileService.update(existing, to: corrected,
                    confirmedOccurrenceWideCorrection: confirmed, modelContext: context)
            } else {
                try ResistanceProfileService.createPerformedOccurrence(workoutKind: .fixed,
                    sessionId: session.id, exerciseId: exercise.id, value: corrected, profiles: [],
                    confirmedOccurrenceWideCorrection: confirmed, modelContext: context)
            }
        }
        if liveAlreadyCorrected, let existing {
            existing.resistanceSource = corrected.resistanceSource
            existing.chainType = corrected.chainType
            existing.chainPercent = corrected.chainPercent
            existing.eccentricPercent = corrected.eccentricPercent
            existing.chainPounds = corrected.chainPounds
            existing.eccentricPounds = corrected.eccentricPounds
            try context.save()
            // Re-saving the same live value without correction authority must
            // not silently rewrite the frozen snapshot.
            try correction(false)
        } else {
            XCTAssertThrowsError(try correction(false))
        }
        XCTAssertEqual(occurrence.exerciseSnapshots, [snapshot])
        try correction(true)

        let correctedSnapshot = try XCTUnwrap(occurrence.exerciseSnapshots.first)
        XCTAssertEqual(correctedSnapshot.resistanceProfile, corrected)
        XCTAssertEqual(correctedSnapshot.progressionKey, key)
        XCTAssertEqual(correctedSnapshot.exerciseName, snapshot.exerciseName)
        XCTAssertEqual(correctedSnapshot.prescribedSetCount, snapshot.prescribedSetCount)
        XCTAssertEqual(correctedSnapshot.completionStatus, .performed)
        XCTAssertEqual(occurrence.positionIndex, 4)
        XCTAssertEqual(occurrence.completedAt, session.finishedAt)
        XCTAssertEqual([row.weight, Double(row.reps)], [70, 10])
        XCTAssertEqual(session.exportStatus, .pending)
        let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        let effort = ExerciseEffortLookupService.fixedCycleEffort(exerciseId: exercise.id,
            cycleInstanceId: cycle.id, cycleDayIndex: 0, adaptiveSessions: [], adaptiveSetEntries: [],
            rotationSessions: [session], rotationSetEntries: [row], progressionKey: key,
            progressionOccurrences: [occurrence], resistanceRequirement: .cable(corrected),
            resistanceProfiles: profiles)
        XCTAssertEqual(effort?.profileComparison, .exact)
        let payload = try exportPayload(session: session, cycle: cycle, occurrence: occurrence,
            rows: [row], exercises: [exercise], profiles: profiles)
        XCTAssertEqual(payload.exercises.first?.resistance_profile?.value, corrected)
        XCTAssertEqual(payload.fixed_cycle?.cluster_occurrences?.first?.exercises.first?
            .resistance_profile?.value, corrected)
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).first?
            .exerciseSnapshots.first?.resistanceProfile, corrected)
    }

    func testClusterExportRetainsFrozenProfileAndDescriptorAfterLiveRecordsChange() throws {
        let frozen = ResistanceProfileValue.voltra(chainType: .inverseChains,
                                                   chainPounds: 35, eccentricPounds: 12.5)
        let payload = try clusteredExport(frozenProfile: frozen, includeCatalog: true)
        let exercise = try XCTUnwrap(payload.exercises.first)
        XCTAssertEqual(exercise.exercise_name, "Frozen Cable Row")
        XCTAssertEqual(exercise.muscle, MuscleGroup.back.rawValue)
        XCTAssertEqual(exercise.resistance_profile?.value, frozen)
        XCTAssertEqual(exercise.resistance_profile,
                       payload.fixed_cycle?.cluster_occurrences?.first?.exercises.first?.resistance_profile)
        XCTAssertEqual(exercise.sets.map(\.weight), [70])
    }

    func testClusterExportRetainsPerformedExerciseWhenCatalogRecordIsMissing() throws {
        let payload = try clusteredExport(frozenProfile: .weightStack, includeCatalog: false)
        XCTAssertEqual(payload.exercises.count, 1)
        XCTAssertEqual(payload.exercises.first?.exercise_name, "Frozen Cable Row")
        XCTAssertEqual(payload.exercises.first?.sets.map(\.reps), [10])
    }

    func testClusterExportDoesNotInventUnknownFrozenProfileFromLiveRecord() throws {
        let payload = try clusteredExport(frozenProfile: nil, includeCatalog: true)
        XCTAssertEqual(payload.exercises.count, 1)
        XCTAssertNil(payload.exercises.first?.resistance_profile)
    }

    @MainActor
    func testRejectedAdaptiveHydrationLeavesNoPartialReadinessOrCatalogAndCanRetry() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let context = ModelContext(container)
        let valid = adaptivePayload()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AdaptiveExportService.encode(valid)) as? [String: Any])
        var plan = try XCTUnwrap(object["plan"] as? [String: Any])
        var complexes = try XCTUnwrap(plan["complexes"] as? [[String: Any]])
        var invalid = complexes[0]
        invalid["snapshot_id"] = "invalid-uuid"
        complexes.append(invalid)
        plan["complexes"] = complexes
        object["plan"] = plan
        let malformed = try XCTUnwrap(AdaptiveExportService.decode(
            JSONSerialization.data(withJSONObject: object)))

        XCTAssertFalse(try AdaptiveExportService.hydrate(malformed, modelContext: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyReadinessCheck>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)
        // A later save must not commit leftovers from the rejected import.
        try context.save()
        XCTAssertTrue(try AdaptiveExportService.hydrate(valid, modelContext: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyReadinessCheck>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 1)
        XCTAssertFalse(try AdaptiveExportService.hydrate(valid, modelContext: context))
    }

    @MainActor
    func testAdaptiveHydrationRejectsInvalidSetIdentityWithoutLosingRowsOnRetry() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let context = ModelContext(container)
        let valid = adaptivePayload()
        let validSetId = valid.plan.complexes[0].exercises[0].sets[0].set_entry_id
        let json = try XCTUnwrap(String(data: AdaptiveExportService.encode(valid), encoding: .utf8))
        let invalid = try XCTUnwrap(AdaptiveExportService.decode(
            Data(json.replacingOccurrences(of: validSetId, with: "invalid-set-id").utf8)))
        XCTAssertFalse(try AdaptiveExportService.hydrate(invalid, modelContext: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)
        XCTAssertTrue(try AdaptiveExportService.hydrate(valid, modelContext: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 1)
    }

    @MainActor
    func testAdaptiveHydrationDoesNotCommitOrDiscardUnrelatedPendingEdits() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let context = ModelContext(container)
        let pending = Exercise(name: "Unrelated draft", primaryMuscle: .chest,
                               type: .compound, equipment: .dumbbell)
        context.insert(pending)
        XCTAssertThrowsError(try AdaptiveExportService.hydrate(adaptivePayload(), modelContext: context))
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)
        XCTAssertEqual(pending.name, "Unrelated draft")
    }

    private func clusteredExport(frozenProfile: ResistanceProfileValue?, includeCatalog: Bool) throws
        -> SessionExportService.ExportPayload {
        let exercise = Exercise(name: "Renamed live exercise", primaryMuscle: .biceps,
                                type: .isolation, equipment: .cable)
        let cycle = ActiveCycleInstance(templateId: UUID())
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0,
                              finishedAt: Date(timeIntervalSince1970: 1000), status: .completed)
        let occurrence = try ClusterOccurrenceRecord(
            sessionId: session.id, cycleInstanceId: cycle.id, templateId: cycle.templateId,
            programVersionID: FixedCycleClusterProgramService.programVersionID,
            clusterID: "cluster-1", positionIndex: 0, templateDayPosition: 0, dayLabel: "Cluster 1",
            exerciseSnapshots: [.init(position: 0, exerciseId: exercise.id,
                exerciseName: "Frozen Cable Row", muscle: .back, prescribedSetCount: 1,
                progressionKey: "frozen-row-key", resistanceProfile: frozenProfile,
                completionStatus: .performed)])
        let row = SetEntry(sessionId: session.id, exerciseId: exercise.id,
                           setIndex: 1, weight: 70, reps: 10, isLocked: true)
        let liveProfile = ExerciseResistanceProfile(workoutKind: .fixed, sessionId: session.id,
            exerciseId: exercise.id, resistanceSource: .voltra, chainType: .chains,
            chainPercent: 10, eccentricPercent: 20)
        return try exportPayload(session: session, cycle: cycle, occurrence: occurrence, rows: [row],
                                 exercises: includeCatalog ? [exercise] : [], profiles: [liveProfile])
    }

    private func exportPayload(session: Session, cycle: ActiveCycleInstance,
        occurrence: ClusterOccurrenceRecord, rows: [SetEntry], exercises: [Exercise],
        profiles: [ExerciseResistanceProfile]) throws -> SessionExportService.ExportPayload {
        let metadata = try XCTUnwrap(SessionExportService.resolvedFixedCycleMetadata(
            session: session, activeCycles: [cycle], templates: [], exercises: [], setEntries: rows,
            readiness: [], overrides: [], snapshots: [], clusterOccurrences: [occurrence],
            clusterRotationStates: []))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try SessionExportService.export(session: session, cycleName: "Frozen program",
            exercises: exercises, setEntries: rows,
            fixedCycleMetadata: metadata, resistanceProfiles: profiles,
            environment: .init(containerIdentifier: nil, iCloudContainerURL: nil,
                localDocumentsURL: root, coordinatedWrite: { try $0.write(to: $1) },
                ubiquityMetadata: { _ in .init(isUbiquitousItem: false, isUploaded: false,
                                              isUploading: false, uploadingErrorDescription: nil) }))
        let data = try Data(contentsOf: XCTUnwrap(outcome.localMirrorURL))
        return try XCTUnwrap(SessionExportService.decodeExportPayload(data: data))
    }

    private func adaptivePayload() -> AdaptiveExportService.PayloadV2 {
        let programId = UUID()
        let exercise = Exercise(name: "Recovered Row", primaryMuscle: .back,
                                type: .compound, equipment: .cable)
        let snapshot = PlannedExerciseSnapshot(position: 0, exerciseId: exercise.id,
            exerciseName: exercise.name, primaryMuscle: .back, difficulty: .easy, prescribedSetCount: 1)
        let complex = PlannedComplexSnapshot(sourceDefinitionId: UUID(), sourceVersion: 1,
            position: 0, name: "Row", primaryMuscle: .back, reasonCodes: [], exercises: [snapshot])
        let readiness = DailyReadinessCheck(localDateKey: "2026-09-07",
            timeZoneIdentifier: "America/Los_Angeles", revision: 1,
            adaptiveProgramId: programId, adaptiveProgramVersion: 1, responses: [])
        let plan = GeneratedWorkoutPlan(localDateKey: "2026-09-07",
            timeZoneIdentifier: "America/Los_Angeles", status: .completed,
            adaptiveProgramId: programId, adaptiveProgramVersion: 1,
            readinessCheckId: readiness.id, plannerVersion: 1, reasonCodes: [], complexes: [complex])
        let session = AdaptiveWorkoutSession(generatedPlanId: plan.id,
            finishedAt: Date(timeIntervalSince1970: 1000), status: .completed)
        let row = AdaptiveSetEntry(adaptiveSessionId: session.id, occurrenceId: snapshot.occurrenceId,
            exerciseId: exercise.id, setIndex: 1, weight: 70, reps: 10, isLocked: true)
        return AdaptiveExportService.makePayload(plan: plan, session: session, readiness: readiness,
            setEntries: [row], exercises: [exercise], overrides: [], feedback: [])
    }
}
