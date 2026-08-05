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
        XCTAssertFalse(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: configuredNonCableExerciseId,
                previousProfile: baseline,
                currentExerciseId: configuredNonCableExerciseId,
                currentProfile: changed,
                cableExerciseIds: []
            )
        )
        XCTAssertTrue(
            AdaptiveDoseEvidenceService.profilesPermitComparison(
                previousExerciseId: configuredNonCableExerciseId,
                previousProfile: baseline,
                currentExerciseId: configuredNonCableExerciseId,
                currentProfile: baseline,
                cableExerciseIds: []
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
        XCTAssertNil(
            ResistanceProfileService.lastUsedValue(
                exerciseId: UUID(),
                profiles: [global, exact],
                allowsGlobalFallback: false
            )
        )
    }

    @MainActor
    func testNonCableProfileIsOptionalButAnExistingProfileFreezesBeforeFirstSet() throws {
        let (context, _) = makeContext()
        try ResistanceProfileService.freezeBeforeLock(
            nil,
            required: false,
            modelContext: context
        )
        XCTAssertThrowsError(
            try ResistanceProfileService.freezeBeforeLock(nil, modelContext: context)
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .profileRequiredBeforeLock)
        }
        let profile = try ResistanceProfileService.create(
            workoutKind: .fixed,
            sessionId: UUID(),
            exerciseId: UUID(),
            value: .voltra(chainType: .inverseChains, chainPercent: 30, eccentricPercent: 70),
            profiles: [],
            modelContext: context
        )
        try ResistanceProfileService.freezeBeforeLock(
            profile,
            required: false,
            modelContext: context,
            now: Date(timeIntervalSince1970: 123)
        )
        XCTAssertEqual(profile.frozenAt, Date(timeIntervalSince1970: 123))
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
    func testBackfillRejectsAnEmptyManifest() throws {
        let (context, _) = makeContext()
        let report = HistoricalResistanceProfileMigration.AuditReport(
            schemaVersion: 1,
            generatedAt: .now,
            expectedCandidateCount: 24,
            candidates: [],
            isExactExpectedCount: false
        )
        XCTAssertThrowsError(
            try HistoricalResistanceProfileMigration.applyReviewedManifest(
                [],
                audit: report,
                existingProfiles: [],
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .emptyManifest)
        }
    }

    func testReviewedManifestExactlyMatchesTheDeviceAudit() {
        let manifest = HistoricalResistanceProfileMigration.reviewedManifest
        XCTAssertEqual(manifest.count, 24)
        XCTAssertEqual(Set(manifest.map(\.key.sessionId)).count, 12)

        let expectedIdentityAndCounts = [
            "adaptive|08476AD8-9550-4A33-94DF-55B12E6161F2|87A21249-FE4B-4C3E-8F5B-E02944C57263|ED4C9952-8F7D-42A1-9928-8FF5265463D8|3",
            "adaptive|0DADB7CE-573E-477E-8838-E6D69A27ED3C|17BC2F9D-F0A2-4604-AA41-33ADD79ED16B|D9C9805E-A95A-45F8-B674-7A1FCF639626|2",
            "adaptive|476348F2-D693-40B6-8761-866676A20676|C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3|0EE78BC6-6514-40C9-A401-FE0A7DD6CFB6|2",
            "adaptive|78F895B2-10DE-4AAA-AD74-97AB243C52E1|81739325-64CA-4686-B2D5-72A310832DA0|1BCE6A23-AD9B-4C60-BF5F-AA6CCFCD170E|3",
            "adaptive|78F895B2-10DE-4AAA-AD74-97AB243C52E1|742E75C7-9F97-4F1A-AB41-896B10402731|E4217C1E-A0D6-43F2-B70B-2BFE08B12DF5|3",
            "adaptive|86B9C09E-B52A-4864-B715-D5745CED523A|17BC2F9D-F0A2-4604-AA41-33ADD79ED16B|30E35887-912A-4C45-BBCE-9160C3EEB284|2",
            "adaptive|86B9C09E-B52A-4864-B715-D5745CED523A|27FC2511-A469-438D-8E46-6C6D99B30F42|9DA39594-9DAB-4E10-8521-5A008A642F4F|2",
            "adaptive|86B9C09E-B52A-4864-B715-D5745CED523A|87A21249-FE4B-4C3E-8F5B-E02944C57263|CDBB2B7B-B081-436A-8DF1-AE2733008295|2",
            "fixed|887431EA-2E20-45A3-A3FD-B1B65383961C|17BC2F9D-F0A2-4604-AA41-33ADD79ED16B|-|3",
            "fixed|887431EA-2E20-45A3-A3FD-B1B65383961C|31714E52-46E3-4080-8403-222537D68E10|-|3",
            "fixed|887431EA-2E20-45A3-A3FD-B1B65383961C|C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3|-|3",
            "ad_hoc|8DC5D239-F5FB-4E0F-B181-DF1F8EA5B52B|C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3|-|1",
            "ad_hoc|8DC5D239-F5FB-4E0F-B181-DF1F8EA5B52B|E27608C0-2EFD-436C-A01E-BAF327F44055|-|1",
            "adaptive|9814E290-49A9-480C-B654-85B7D61F05CF|C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3|9604D053-19FF-4BB7-BF2F-A3C5410AC49D|3",
            "adaptive|9814E290-49A9-480C-B654-85B7D61F05CF|E27608C0-2EFD-436C-A01E-BAF327F44055|BB3F4A65-F304-4667-8B2E-3329572DD1F5|3",
            "adaptive|D21627D8-34D5-4044-990A-6B7C036E230F|87A21249-FE4B-4C3E-8F5B-E02944C57263|E5347F42-3AC1-4817-ABFE-34A858DD921B|3",
            "adaptive|D21627D8-34D5-4044-990A-6B7C036E230F|8C24C3C7-EB71-4523-BA0C-BB22B1F8CE7D|F47ABA45-6FB0-40F3-90F4-433851F29B3D|4",
            "fixed|FF0623F5-92DF-484A-857F-A4FEFC540AD9|8C24C3C7-EB71-4523-BA0C-BB22B1F8CE7D|-|3",
            "fixed|FF0623F5-92DF-484A-857F-A4FEFC540AD9|C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3|-|3",
            "adaptive|0DADB7CE-573E-477E-8838-E6D69A27ED3C|54214942-679D-4CBB-9B27-F78601897BA2|E7045F23-F2CC-4295-B2BC-AEEEC19F72B4|2",
            "adaptive|D21627D8-34D5-4044-990A-6B7C036E230F|54214942-679D-4CBB-9B27-F78601897BA2|4AACD4E1-DB9F-4BB4-B918-E51415CE3D95|3",
            "adaptive|08476AD8-9550-4A33-94DF-55B12E6161F2|54214942-679D-4CBB-9B27-F78601897BA2|F77E334D-C843-45C1-84AD-68762C87DA4D|3",
            "fixed|FBE13920-FF2C-437F-8A38-C09CF1409C09|54214942-679D-4CBB-9B27-F78601897BA2|-|3",
            "fixed|317EE106-323C-405B-A110-260870F22993|54214942-679D-4CBB-9B27-F78601897BA2|-|3"
        ]
        XCTAssertEqual(manifest.map(manifestIdentityAndCount), expectedIdentityAndCounts)
        XCTAssertTrue(manifest.prefix(17).allSatisfy {
            $0.profile == .voltra(chainType: .inverseChains, chainPercent: 25, eccentricPercent: 25)
        })
        XCTAssertTrue(manifest[17..<19].allSatisfy {
            $0.profile == .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30)
        })
        XCTAssertTrue(manifest[19..<23].allSatisfy {
            $0.profile == .voltra(chainType: .inverseChains, chainPercent: 25, eccentricPercent: 25)
        })
        XCTAssertEqual(
            manifest.last?.profile,
            .voltra(chainType: .inverseChains, chainPercent: 30, eccentricPercent: 70)
        )
        XCTAssertEqual(
            manifest.map(\.exerciseName),
            [
                "Chest Supported Cable Row",
                "Overhead Single-Arm Cable Extension",
                "Cable Lateral Raise",
                "Cable Crossover Lateral Raise",
                "Cable Preacher Curl",
                "Overhead Single-Arm Cable Extension",
                "Lat Prayer",
                "Chest Supported Cable Row",
                "Overhead Single-Arm Cable Extension",
                "Incline Cable Flye",
                "Cable Lateral Raise",
                "Cable Lateral Raise",
                "Bayesian Curl",
                "Cable Lateral Raise",
                "Bayesian Curl",
                "Chest Supported Cable Row",
                "Cable Pushdown",
                "Cable Pushdown",
                "Cable Lateral Raise",
                "Lat Pulldown",
                "Lat Pulldown",
                "Lat Pulldown",
                "Lat Pulldown",
                "Lat Pulldown"
            ]
        )
    }

    @MainActor
    func testBackfillFailsClosedOnAuditMismatch() throws {
        let (context, _) = makeContext()
        var candidates = exactManifestReport().candidates
        let first = candidates.removeFirst()
        candidates.insert(
            .init(
                key: first.key,
                exerciseName: first.exerciseName,
                performedSetCount: first.performedSetCount + 1,
                intendedProfile: first.intendedProfile
            ),
            at: 0
        )
        let report = HistoricalResistanceProfileMigration.AuditReport(
            schemaVersion: 1,
            generatedAt: .now,
            expectedCandidateCount: 24,
            candidates: candidates,
            isExactExpectedCount: true
        )

        XCTAssertThrowsError(
            try HistoricalResistanceProfileMigration.applyReviewedManifest(
                audit: report,
                existingProfiles: [],
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .manifestMismatch)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()).isEmpty)
    }

    @MainActor
    func testBackfillConflictIsAtomic() throws {
        let (context, _) = makeContext()
        let conflictingItem = HistoricalResistanceProfileMigration.reviewedManifest.last!
        let conflicting = ExerciseResistanceProfile(
            workoutKind: conflictingItem.key.workoutKind,
            sessionId: conflictingItem.key.sessionId,
            exerciseId: conflictingItem.key.exerciseId,
            occurrenceId: conflictingItem.key.occurrenceId,
            resistanceSource: .weightStack
        )
        context.insert(conflicting)
        try context.save()

        XCTAssertThrowsError(
            try HistoricalResistanceProfileMigration.applyReviewedManifest(
                audit: exactManifestReport(),
                existingProfiles: [conflicting],
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? ResistanceProfileError, .conflictingExistingProfile)
        }
        let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.resistanceSource, .weightStack)
    }

    @MainActor
    func testStartupBackfillAppliesThenBecomesNoOpWithoutRedirtyingExports() throws {
        let (context, _) = makeContext()
        try insertExactAuditedHistory(into: context)
        let appliedAt = Date(timeIntervalSince1970: 1_786_000_000)

        let first = try HistoricalResistanceProfileMigration.runAtStartup(
            modelContext: context,
            now: appliedAt
        )
        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(first.auditedCandidateCount, 24)
        XCTAssertEqual(first.createdProfileCount, 24)
        XCTAssertEqual(first.repairedSessionCount, 12)
        XCTAssertEqual(first.repairedSessionIds.count, 12)
        let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        XCTAssertEqual(profiles.count, 24)
        XCTAssertTrue(profiles.allSatisfy { $0.frozenAt == appliedAt })

        let fixedSessions = try context.fetch(FetchDescriptor<Session>())
        let adaptiveSessions = try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        XCTAssertTrue(fixedSessions.allSatisfy { $0.exportStatus == .pending })
        XCTAssertTrue(adaptiveSessions.allSatisfy { $0.exportStatus == .pending })
        fixedSessions.forEach { $0.exportStatus = .success }
        adaptiveSessions.forEach { $0.exportStatus = .success }
        try context.save()

        let second = try HistoricalResistanceProfileMigration.runAtStartup(
            modelContext: context,
            now: appliedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(second.status, .alreadyApplied)
        XCTAssertEqual(second.auditedCandidateCount, 24)
        XCTAssertEqual(second.createdProfileCount, 0)
        XCTAssertEqual(second.repairedSessionCount, 0)
        XCTAssertTrue(second.repairedSessionIds.isEmpty)
        XCTAssertTrue(fixedSessions.allSatisfy { $0.exportStatus == .success })
        XCTAssertTrue(adaptiveSessions.allSatisfy { $0.exportStatus == .success })
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()).count, 24)
    }

    @MainActor
    func testStageTwoAddsOnlyFiveProfilesAndDirtiesOnlyTheirFiveSessions() throws {
        let (context, _) = makeContext()
        try insertExactAuditedHistory(into: context)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        for item in HistoricalResistanceProfileMigration.reviewedManifest.prefix(19) {
            let profile = ExerciseResistanceProfile(
                workoutKind: item.key.workoutKind,
                sessionId: item.key.sessionId,
                exerciseId: item.key.exerciseId,
                occurrenceId: item.key.occurrenceId,
                resistanceSource: item.profile.resistanceSource,
                chainType: item.profile.chainType,
                chainPercent: item.profile.chainPercent,
                eccentricPercent: item.profile.eccentricPercent,
                frozenAt: originalDate,
                createdAt: originalDate,
                updatedAt: originalDate
            )
            context.insert(profile)
        }
        try context.save()

        let appliedAt = originalDate.addingTimeInterval(100)
        let result = try HistoricalResistanceProfileMigration.runAtStartup(
            modelContext: context,
            now: appliedAt
        )
        let expectedRepaired = Set(
            HistoricalResistanceProfileMigration.reviewedManifest.suffix(5).map(\.key.sessionId)
        )
        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.createdProfileCount, 5)
        XCTAssertEqual(result.repairedSessionCount, 5)
        XCTAssertEqual(result.repairedSessionIds, expectedRepaired)

        let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        XCTAssertEqual(profiles.count, 24)
        let oldKeys = Set(HistoricalResistanceProfileMigration.reviewedManifest.prefix(19).map(\.key))
        let oldProfiles = profiles.filter {
            oldKeys.contains(
                .init(
                    workoutKind: $0.workoutKind,
                    sessionId: $0.sessionId,
                    exerciseId: $0.exerciseId,
                    occurrenceId: $0.occurrenceId
                )
            )
        }
        XCTAssertEqual(oldProfiles.count, 19)
        XCTAssertTrue(oldProfiles.allSatisfy {
            $0.createdAt == originalDate
                && $0.updatedAt == originalDate
                && $0.frozenAt == originalDate
        })
        XCTAssertEqual(
            ResistanceProfileService.lastUsedValue(
                exerciseId: HistoricalResistanceProfileMigration.latPulldownExerciseId,
                profiles: profiles,
                allowsGlobalFallback: false
            ),
            .voltra(chainType: .inverseChains, chainPercent: 30, eccentricPercent: 70)
        )

        let fixedSessions = try context.fetch(FetchDescriptor<Session>())
        let adaptiveSessions = try context.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        let pendingIds = Set(fixedSessions.filter { $0.exportStatus == .pending }.map(\.id))
            .union(adaptiveSessions.filter { $0.exportStatus == .pending }.map(\.id))
        XCTAssertEqual(pendingIds, expectedRepaired)
    }

    @MainActor
    func testCompletedMarkerMakesLaterUnreviewedLatOccurrenceHarmless() throws {
        let (context, _) = makeContext()
        try insertExactAuditedHistory(into: context)
        _ = try HistoricalResistanceProfileMigration.runAtStartup(modelContext: context)
        let selectedSession = HistoricalResistanceProfileMigration.reviewedManifest
            .first(where: { $0.key.workoutKind == .adaptive })!.key.sessionId
        let extraOccurrence = UUID()
        context.insert(
            AdaptiveSetEntry(
                adaptiveSessionId: selectedSession,
                occurrenceId: extraOccurrence,
                exerciseId: HistoricalResistanceProfileMigration.latPulldownExerciseId,
                setIndex: 1,
                weight: 90,
                reps: 8,
                isLocked: true
            )
        )
        try context.save()

        let second = try HistoricalResistanceProfileMigration.runAtStartup(modelContext: context)
        XCTAssertEqual(second.status, .alreadyApplied)
        XCTAssertEqual(second.createdProfileCount, 0)
    }

    func testAuditIncludesOnlyReviewedLatIdentityAndRejectsMalformedRows() {
        let lat = Exercise(
            id: HistoricalResistanceProfileMigration.latPulldownExerciseId,
            name: "Lat Pulldown",
            primaryMuscle: .back,
            type: .compound,
            equipment: .machine
        )
        let unrelated = Exercise(
            name: "Leg Press",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine
        )
        let reviewedSessionId = UUID(uuidString: "FBE13920-FF2C-437F-8A38-C09CF1409C09")!
        let reviewed = Session(
            id: reviewedSessionId,
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            status: .completed
        )
        let incomplete = Session(
            id: UUID(uuidString: "317EE106-323C-405B-A110-260870F22993")!,
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            status: .draft
        )
        let unreviewed = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            status: .completed
        )
        let rows = (1...3).map {
            SetEntry(
                sessionId: reviewedSessionId,
                exerciseId: lat.id,
                setIndex: $0,
                weight: 90,
                reps: 10,
                isLocked: true
            )
        } + [
            SetEntry(sessionId: reviewedSessionId, exerciseId: unrelated.id, setIndex: 1, weight: 200, reps: 10, isLocked: true),
            SetEntry(sessionId: incomplete.id, exerciseId: lat.id, setIndex: 1, weight: 90, reps: 10, isLocked: true),
            SetEntry(sessionId: unreviewed.id, exerciseId: lat.id, setIndex: 1, weight: 90, reps: 10, isLocked: true)
        ]
        let report = HistoricalResistanceProfileMigration.audit(
            sessions: [reviewed, incomplete, unreviewed],
            setEntries: rows,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            exercises: [lat, unrelated]
        )
        XCTAssertEqual(report.candidates.map(\.key.exerciseId), [lat.id])
        XCTAssertEqual(report.candidates.first?.performedSetCount, 3)

        let malformed = HistoricalResistanceProfileMigration.audit(
            sessions: [reviewed],
            setEntries: [
                SetEntry(sessionId: reviewedSessionId, exerciseId: lat.id, setIndex: 1, weight: 90, reps: 10, isLocked: true),
                SetEntry(sessionId: reviewedSessionId, exerciseId: lat.id, setIndex: 3, weight: 90, reps: 10, isLocked: true),
                SetEntry(sessionId: reviewedSessionId, exerciseId: lat.id, setIndex: 3, weight: 90, reps: 10, isLocked: true)
            ],
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            exercises: [lat]
        )
        XCTAssertTrue(malformed.candidates.isEmpty)

        let adaptiveId = UUID(uuidString: "0DADB7CE-573E-477E-8838-E6D69A27ED3C")!
        let adaptive = AdaptiveWorkoutSession(
            id: adaptiveId,
            generatedPlanId: UUID(),
            status: .completed
        )
        let mixedOccurrence = UUID()
        let mixed = HistoricalResistanceProfileMigration.audit(
            sessions: [],
            setEntries: [],
            adaptiveSessions: [adaptive],
            adaptiveSetEntries: [
                AdaptiveSetEntry(
                    adaptiveSessionId: adaptiveId,
                    occurrenceId: mixedOccurrence,
                    exerciseId: lat.id,
                    setIndex: 1,
                    weight: 90,
                    reps: 10,
                    isLocked: true
                ),
                AdaptiveSetEntry(
                    adaptiveSessionId: adaptiveId,
                    occurrenceId: mixedOccurrence,
                    exerciseId: unrelated.id,
                    setIndex: 2,
                    weight: 90,
                    reps: 10,
                    isLocked: true
                )
            ],
            exercises: [lat, unrelated]
        )
        XCTAssertTrue(mixed.candidates.isEmpty)
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
                    exercise_name: "Lat Pulldown",
                    muscle: "back",
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

    private func manifestIdentityAndCount(
        _ item: HistoricalResistanceProfileMigration.ManifestEntry
    ) -> String {
        [
            item.key.workoutKind.rawValue,
            item.key.sessionId.uuidString,
            item.key.exerciseId.uuidString,
            item.key.occurrenceId?.uuidString ?? "-",
            String(item.expectedPerformedSetCount)
        ].joined(separator: "|")
    }

    private func exactManifestReport() -> HistoricalResistanceProfileMigration.AuditReport {
        let candidates = HistoricalResistanceProfileMigration.reviewedManifest.map {
            HistoricalResistanceProfileMigration.Candidate(
                key: $0.key,
                exerciseName: $0.exerciseName,
                performedSetCount: $0.expectedPerformedSetCount,
                intendedProfile: $0.profile
            )
        }
        return HistoricalResistanceProfileMigration.AuditReport(
            schemaVersion: 1,
            generatedAt: .now,
            expectedCandidateCount: 24,
            candidates: candidates,
            isExactExpectedCount: true
        )
    }

    @MainActor
    private func insertExactAuditedHistory(into context: ModelContext) throws {
        let manifest = HistoricalResistanceProfileMigration.reviewedManifest
        var insertedExerciseIds: Set<UUID> = []
        for item in manifest where insertedExerciseIds.insert(item.key.exerciseId).inserted {
            context.insert(
                Exercise(
                    id: item.key.exerciseId,
                    name: item.exerciseName,
                    primaryMuscle: .sideDelts,
                    type: .isolation,
                    equipment: item.key.exerciseId == HistoricalResistanceProfileMigration.latPulldownExerciseId
                        ? .machine
                        : .cable
                )
            )
        }

        let bySession = Dictionary(grouping: manifest, by: { $0.key.sessionId })
        for (sessionId, items) in bySession {
            switch items[0].key.workoutKind {
            case .fixed, .adHoc:
                context.insert(
                    Session(
                        id: sessionId,
                        cycleInstanceId: UUID(),
                        cycleDayIndex: 0,
                        dayLabelSnapshot: items[0].key.workoutKind == .adHoc
                            ? "Off-Schedule"
                            : "Push",
                        finishedAt: .now,
                        status: .completed,
                        exportStatus: .success
                    )
                )
            case .adaptive:
                context.insert(
                    AdaptiveWorkoutSession(
                        id: sessionId,
                        generatedPlanId: UUID(),
                        finishedAt: .now,
                        status: .completed,
                        exportStatus: .success
                    )
                )
            }
        }

        for item in manifest {
            for setIndex in 1...item.expectedPerformedSetCount {
                switch item.key.workoutKind {
                case .fixed, .adHoc:
                    context.insert(
                        SetEntry(
                            sessionId: item.key.sessionId,
                            exerciseId: item.key.exerciseId,
                            setIndex: setIndex,
                            weight: 10,
                            reps: 10,
                            isLocked: true
                        )
                    )
                case .adaptive:
                    context.insert(
                        AdaptiveSetEntry(
                            adaptiveSessionId: item.key.sessionId,
                            occurrenceId: item.key.occurrenceId!,
                            exerciseId: item.key.exerciseId,
                            setIndex: setIndex,
                            weight: 10,
                            reps: 10,
                            isLocked: true
                        )
                    )
                }
            }
        }
        try context.save()
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
