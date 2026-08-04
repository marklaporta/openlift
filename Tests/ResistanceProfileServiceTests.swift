import SwiftData
import XCTest
@testable import OpenLift

final class ResistanceProfileServiceTests: XCTestCase {
    func testVOLTRAValueNormalizesNoneAndLabelsRawSettings() {
        let value = ResistanceProfileValue.voltra(
            chainType: .none,
            chainPercent: 70,
            eccentricPercent: 30
        )
        XCTAssertEqual(value.chainPercent, 0)
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(value.displayName, "VOLTRA · No Chains · Eccentric 30%")

        let inverse = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        XCTAssertEqual(inverse.displayName, "VOLTRA · Inverse Chains 70% · Eccentric 30%")
    }

    func testComparisonRequiresTwoCompleteExactProfiles() {
        let baseline = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25
        )
        XCTAssertEqual(
            ResistanceProfileComparison.compare(current: baseline, historical: baseline),
            ResistanceProfileComparison.exact
        )
        XCTAssertEqual(
            ResistanceProfileComparison.compare(current: baseline, historical: .weightStack),
            ResistanceProfileComparison.different
        )
        XCTAssertEqual(
            ResistanceProfileComparison.compare(current: baseline, historical: nil),
            ResistanceProfileComparison.unknown
        )
        XCTAssertEqual(
            ResistanceProfileComparison.compare(current: nil, historical: nil),
            ResistanceProfileComparison.unknown
        )
    }

    func testAdaptiveDoseProfileGateUsesActualSubstitutedExerciseIds() {
        let configuredNonCableExerciseId = UUID()
        let substitutedCableExerciseId = UUID()
        let otherNonCableExerciseId = UUID()
        let baseline = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25
        )
        let changed = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )

        XCTAssertFalse(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: configuredNonCableExerciseId,
                previousProfile: nil,
                currentExerciseId: substitutedCableExerciseId,
                currentProfile: changed,
                cableExerciseIds: [substitutedCableExerciseId]
            )
        )
        XCTAssertFalse(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: substitutedCableExerciseId,
                previousProfile: baseline,
                currentExerciseId: configuredNonCableExerciseId,
                currentProfile: nil,
                cableExerciseIds: [substitutedCableExerciseId]
            )
        )
        XCTAssertTrue(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: substitutedCableExerciseId,
                previousProfile: baseline,
                currentExerciseId: substitutedCableExerciseId,
                currentProfile: baseline,
                cableExerciseIds: [substitutedCableExerciseId]
            )
        )
        XCTAssertTrue(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: configuredNonCableExerciseId,
                previousProfile: nil,
                currentExerciseId: otherNonCableExerciseId,
                currentProfile: nil,
                cableExerciseIds: [substitutedCableExerciseId]
            )
        )
    }

    @MainActor
    func testProfileFreezesAndRequiresExplicitOccurrenceWideCorrection() throws {
        let (context, _) = makeContext()
        let sessionId = UUID()
        let exerciseId = UUID()
        let initial = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25
        )
        let profile = try ResistanceProfileService.create(
            workoutKind: .fixed,
            sessionId: sessionId,
            exerciseId: exerciseId,
            value: initial,
            profiles: [],
            modelContext: context
        )
        XCTAssertNil(profile.frozenAt)
        try ResistanceProfileService.freezeBeforeLock(profile, modelContext: context)
        XCTAssertNotNil(profile.frozenAt)

        let correction = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        XCTAssertThrowsError(
            try ResistanceProfileService.update(
                profile,
                to: correction,
                confirmedOccurrenceWideCorrection: false,
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .frozenConfirmationRequired)
        }
        try ResistanceProfileService.update(
            profile,
            to: correction,
            confirmedOccurrenceWideCorrection: true,
            modelContext: context
        )
        XCTAssertEqual(ResistanceProfileService.value(profile), correction)
    }

    @MainActor
    func testPerformedProfileCreationRequiresConfirmationFreezesAndMarksExportPending() throws {
        let (context, _) = makeContext()
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            dayLabelSnapshot: "Off-Schedule",
            finishedAt: .now,
            status: .completed,
            exportStatus: .success
        )
        context.insert(session)
        try context.save()
        let value = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        let exerciseId = UUID()

        XCTAssertThrowsError(
            try ResistanceProfileService.createPerformedOccurrence(
                workoutKind: .adHoc,
                sessionId: session.id,
                exerciseId: exerciseId,
                value: value,
                profiles: [],
                confirmedOccurrenceWideCorrection: false,
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .frozenConfirmationRequired)
        }
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ExerciseResistanceProfile>()),
            0
        )
        XCTAssertEqual(session.exportStatus, .success)

        let profile = try ResistanceProfileService.createPerformedOccurrence(
            workoutKind: .adHoc,
            sessionId: session.id,
            exerciseId: exerciseId,
            value: value,
            profiles: [],
            confirmedOccurrenceWideCorrection: true,
            modelContext: context,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(profile.workoutKind, .adHoc)
        XCTAssertEqual(profile.frozenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(ResistanceProfileService.value(profile), value)
        XCTAssertEqual(session.exportStatus, .pending)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ExerciseResistanceProfile>()),
            1
        )
    }

    @MainActor
    func testFixedProfileChangeClearsOnlyMatchingUnlockedPrefillAndSameValueIsNoOp() throws {
        let (context, _) = makeContext()
        let sessionId = UUID()
        let exerciseId = UUID()
        let profile = try ResistanceProfileService.create(
            workoutKind: .fixed,
            sessionId: sessionId,
            exerciseId: exerciseId,
            value: .voltra(chainType: .inverseChains, chainPercent: 25, eccentricPercent: 25),
            profiles: [],
            modelContext: context
        )
        let locked = SetEntry(
            sessionId: sessionId,
            exerciseId: exerciseId,
            setIndex: 1,
            weight: 20,
            reps: 12,
            isLocked: true
        )
        let unlocked = SetEntry(
            sessionId: sessionId,
            exerciseId: exerciseId,
            setIndex: 2,
            weight: 20,
            reps: 10,
            isLocked: false
        )
        let otherExercise = SetEntry(
            sessionId: sessionId,
            exerciseId: UUID(),
            setIndex: 1,
            weight: 50,
            reps: 8,
            isLocked: false
        )
        context.insert(locked)
        context.insert(unlocked)
        context.insert(otherExercise)
        try ResistanceProfileService.freezeBeforeLock(profile, modelContext: context)

        let correction = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        try ResistanceProfileService.update(
            profile,
            to: correction,
            confirmedOccurrenceWideCorrection: true,
            modelContext: context
        )

        XCTAssertEqual(locked.weight, 20)
        XCTAssertEqual(locked.reps, 12)
        XCTAssertEqual(unlocked.weight, 0)
        XCTAssertEqual(unlocked.reps, 0)
        XCTAssertEqual(otherExercise.weight, 50)
        XCTAssertEqual(otherExercise.reps, 8)

        unlocked.weight = 35
        unlocked.reps = 9
        let unchangedUpdatedAt = profile.updatedAt
        try ResistanceProfileService.update(
            profile,
            to: correction,
            confirmedOccurrenceWideCorrection: false,
            modelContext: context,
            now: unchangedUpdatedAt.addingTimeInterval(100)
        )
        XCTAssertEqual(unlocked.weight, 35)
        XCTAssertEqual(unlocked.reps, 9)
        XCTAssertEqual(profile.updatedAt, unchangedUpdatedAt)
    }

    @MainActor
    func testAdaptiveProfileChangeClearsOnlyUnlockedRowsForOccurrence() throws {
        let (context, _) = makeContext()
        let sessionId = UUID()
        let exerciseId = UUID()
        let occurrenceId = UUID()
        let profile = try ResistanceProfileService.create(
            workoutKind: .adaptive,
            sessionId: sessionId,
            exerciseId: exerciseId,
            occurrenceId: occurrenceId,
            value: .weightStack,
            profiles: [],
            modelContext: context
        )
        let locked = AdaptiveSetEntry(
            adaptiveSessionId: sessionId,
            occurrenceId: occurrenceId,
            exerciseId: exerciseId,
            setIndex: 1,
            weight: 60,
            reps: 10,
            isLocked: true
        )
        let unlocked = AdaptiveSetEntry(
            adaptiveSessionId: sessionId,
            occurrenceId: occurrenceId,
            exerciseId: UUID(),
            setIndex: 2,
            weight: 60,
            reps: 9,
            isLocked: false
        )
        let otherOccurrence = AdaptiveSetEntry(
            adaptiveSessionId: sessionId,
            occurrenceId: UUID(),
            exerciseId: exerciseId,
            setIndex: 1,
            weight: 45,
            reps: 11,
            isLocked: false
        )
        context.insert(locked)
        context.insert(unlocked)
        context.insert(otherOccurrence)
        try context.save()

        try ResistanceProfileService.update(
            profile,
            to: .voltra(chainType: .chains, chainPercent: 40, eccentricPercent: 20),
            confirmedOccurrenceWideCorrection: false,
            modelContext: context
        )

        XCTAssertEqual(locked.weight, 60)
        XCTAssertEqual(locked.reps, 10)
        XCTAssertEqual(unlocked.weight, 0)
        XCTAssertEqual(unlocked.reps, 0)
        XCTAssertEqual(otherOccurrence.weight, 45)
        XCTAssertEqual(otherOccurrence.reps, 11)
    }

    func testLastUsedPrefersExerciseThenFallsBackAcrossCableMovements() {
        let firstExercise = UUID()
        let otherExercise = UUID()
        let global = ExerciseResistanceProfile(
            workoutKind: .fixed,
            sessionId: UUID(),
            exerciseId: otherExercise,
            resistanceSource: .voltra,
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let exact = ExerciseResistanceProfile(
            workoutKind: .fixed,
            sessionId: UUID(),
            exerciseId: firstExercise,
            resistanceSource: .voltra,
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            ResistanceProfileService.lastUsedValue(
                exerciseId: firstExercise,
                profiles: [global, exact]
            ),
            ResistanceProfileService.value(exact)
        )
        XCTAssertEqual(
            ResistanceProfileService.lastUsedValue(
                exerciseId: UUID(),
                profiles: [global, exact]
            ),
            ResistanceProfileService.value(global)
        )
    }

    func testRepeatLastPrefersOlderExactProfileOverNewerDifferentProfile() {
        let exerciseId = UUID()
        let cycleId = UUID()
        let exactSession = completedSession(cycleId: cycleId, finishedAt: Date(timeIntervalSince1970: 10))
        let differentSession = completedSession(cycleId: cycleId, finishedAt: Date(timeIntervalSince1970: 20))
        let entries = [
            SetEntry(sessionId: exactSession.id, exerciseId: exerciseId, setIndex: 1, weight: 20, reps: 10, isLocked: true),
            SetEntry(sessionId: differentSession.id, exerciseId: exerciseId, setIndex: 1, weight: 40, reps: 8, isLocked: true)
        ]
        let exact = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25
        )
        let profiles = [
            profile(sessionId: exactSession.id, exerciseId: exerciseId, value: exact),
            profile(
                sessionId: differentSession.id,
                exerciseId: exerciseId,
                value: .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30)
            )
        ]
        let result = ExerciseEffortLookupService.globalEffort(
            exerciseId: exerciseId,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: [exactSession, differentSession],
            rotationSetEntries: entries,
            resistanceRequirement: .cable(exact),
            resistanceProfiles: profiles
        )
        XCTAssertEqual(result?.sessionId, exactSession.id)
        XCTAssertEqual(result?.rows.first?.weight, 20)
        XCTAssertEqual(result?.profileComparison, .exact)
    }

    func testAuditSelectsAug3ByIdentityDespiteJulyCreationDate() {
        let exercise = Exercise(
            name: "Cable Lateral Raise",
            primaryMuscle: .sideDelts,
            type: .isolation,
            equipment: .cable
        )
        let session = Session(
            id: HistoricalResistanceProfileMigration.august3SessionId,
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            status: .completed
        )
        let report = HistoricalResistanceProfileMigration.audit(
            sessions: [session],
            setEntries: [
                SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: 1, weight: 5, reps: 15, isLocked: true),
                SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: 2, weight: 5, reps: 12, isLocked: true)
            ],
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            exercises: [exercise]
        )
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.candidates.first?.performedSetCount, 2)
        XCTAssertEqual(report.candidates.first?.intendedProfile.chainPercent, 70)
        XCTAssertFalse(report.isExactExpectedCount)
    }

    @MainActor
    func testBackfillStaysDisabledWithoutReviewedExactManifest() throws {
        let (context, _) = makeContext()
        let report = HistoricalResistanceProfileMigration.AuditReport(
            schemaVersion: 1,
            generatedAt: .now,
            expectedCandidateCount: 19,
            candidates: [],
            isExactExpectedCount: false
        )
        XCTAssertThrowsError(
            try HistoricalResistanceProfileMigration.applyReviewedManifest(
                audit: report,
                existingProfiles: [],
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .emptyManifest)
        }
    }

    func testFixedExportRoundTripPreservesOptionalProfileAndLegacyUnknown() throws {
        let profile = ResistanceProfilePayload(
            .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30)
        )
        let payload = SessionExportService.ExportPayload(
            session_id: UUID().uuidString,
            cycle_name: "Push B",
            cycle_day_index: 1,
            date: ISO8601DateFormatter().string(from: .now),
            exercises: [
                .init(
                    exercise_name: "Cable Lateral Raise",
                    muscle: "sideDelts",
                    sets: [.init(set_index: 1, weight: 5, reps: 15)],
                    resistance_profile: profile
                )
            ]
        )
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(
            SessionExportService.decodeExportPayload(data: data)?.exercises.first?
                .resistance_profile?.value,
            profile.value
        )

        let legacy = """
        {"session_id":"\(UUID().uuidString)","cycle_name":"Legacy","cycle_day_index":0,"date":"2026-08-01T00:00:00Z","exercises":[{"exercise_name":"Cable Lateral Raise","muscle":"sideDelts","sets":[{"set_index":1,"weight":5,"reps":12}]}]}
        """.data(using: .utf8)!
        XCTAssertNil(
            SessionExportService.decodeExportPayload(data: legacy)?.exercises.first?
                .resistance_profile
        )
    }

    @MainActor
    private func makeContext() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV12.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }

    private func completedSession(cycleId: UUID, finishedAt: Date) -> Session {
        Session(
            cycleInstanceId: cycleId,
            cycleDayIndex: 0,
            finishedAt: finishedAt,
            status: .completed
        )
    }

    private func profile(
        sessionId: UUID,
        exerciseId: UUID,
        value: ResistanceProfileValue
    ) -> ExerciseResistanceProfile {
        ExerciseResistanceProfile(
            workoutKind: .fixed,
            sessionId: sessionId,
            exerciseId: exerciseId,
            resistanceSource: value.resistanceSource,
            chainType: value.chainType,
            chainPercent: value.chainPercent,
            eccentricPercent: value.eccentricPercent
        )
    }
}
