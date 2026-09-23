import XCTest
@testable import OpenLift

@MainActor
final class MovementHistoryTests: XCTestCase {
    private func exercise(_ name: String = "Flat DB Press") -> Exercise {
        Exercise(name: name, primaryMuscle: .chest, type: .compound, equipment: .dumbbell)
    }
    private func session(_ time: Double = 100) -> Session {
        Session(cycleInstanceId: UUID(), cycleDayIndex: 0, cycleNameSnapshot: "Program",
            createdAt: Date(timeIntervalSince1970: time), finishedAt: Date(timeIntervalSince1970: time), status: .completed)
    }
    private func row(_ session: Session, _ exercise: Exercise, _ reps: Int = 10) -> SetEntry {
        SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: 1, weight: 45, reps: reps, isLocked: true)
    }
    private func occurrence(_ session: Session, _ exercise: Exercise, key: String = "track-a",
        status: ClusterExerciseCompletionStatus = .performed, profile: ResistanceProfileValue? = nil) throws -> ClusterOccurrenceRecord {
        try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: session.cycleInstanceId,
            templateId: UUID(), programVersionID: "v1", clusterID: "cluster-1", absoluteStep: 0,
            templateDayPosition: 0, dayLabel: "Cluster 1", exerciseSnapshots: [
                .init(position: 0, exerciseId: exercise.id, exerciseName: exercise.name, muscle: .chest,
                    prescribedSetCount: 1, progressionKey: key, resistanceProfile: profile, completionStatus: status)
            ])
    }
    func testMovementGroupingSearchOrderingAndDistinctIDs() {
        let press = exercise(), duplicate = exercise(), rowExercise = exercise("CS DB Row")
        let old = session(), new = session(200), last = session(300)
        let draft = Session(cycleInstanceId: UUID(), cycleDayIndex: 0)
        let unlocked = row(new, press); unlocked.isLocked = false
        let results = MovementHistoryService.movements(sessions: [old, new, last, draft],
            setEntries: [row(old, press), row(new, press, 12), row(last, rowExercise), row(old, duplicate), row(draft, press), unlocked, row(new, press, 0)],
            adaptiveSessions: [], adaptiveSetEntries: [], exercises: [press, duplicate, rowExercise])
        XCTAssertEqual(results.count, 3, "Same name is not the same durable exercise")
        let movement = results.first { $0.exerciseID == press.id }!
        XCTAssertEqual(movement.workoutCount, 2)
        XCTAssertEqual(movement.performances.map { $0.sets[0].reps }, [12, 10])
        XCTAssertEqual(results[0].name, "CS DB Row")
        XCTAssertEqual(MovementHistoryService.matching(results, query: "  dumbbell PRESS ").count, 2)
        XCTAssertTrue(MovementHistoryService.matching(results, query: "nothing").isEmpty)
        XCTAssertEqual(MovementHistoryService.matching(results, query: "", alphabetical: true)[0].name, "CS DB Row")
    }
    func testClusterEvidenceFiltersSkippedUnbackedAndPreservesSetupBoundaries() throws {
        let press = exercise(), other = exercise("Other")
        let a = session(), b = session(200), c = session(300), skipped = session(400)
        let profiles: [ResistanceProfileValue] = [.weightStack, .voltra(chainType: .none, eccentricPercent: 0)]
        let records = [try occurrence(a, press, profile: profiles[0]), try occurrence(b, press, key: "track-b", profile: profiles[0]),
            try occurrence(c, press, key: "track-b", profile: profiles[1]), try occurrence(skipped, press, status: .skipped)]
        let result = MovementHistoryService.movements(sessions: [a,b,c,skipped],
            setEntries: [row(a,press), row(b,press), row(c,press), row(skipped,press), row(a,other)],
            adaptiveSessions: [], adaptiveSetEntries: [], exercises: [press,other], occurrences: records)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].workoutCount, 3)
        XCTAssertEqual(result[0].setups.count, 3)
        XCTAssertEqual(result[0].performances[0].profile, profiles[1])
        XCTAssertEqual(result[0].performances[0].progressionKey, "track-b")
    }
    func testAmbiguousClusterEvidenceDoesNotDuplicateSetsOrJoinLegacySetup() throws {
        let press = exercise(), fixed = session(), legacy = session(50)
        let result = MovementHistoryService.movements(sessions: [fixed,legacy],
            setEntries: [row(fixed,press),row(legacy,press)],adaptiveSessions: [],adaptiveSetEntries: [],exercises: [press],
            occurrences: [try occurrence(fixed,press,key: "a"),try occurrence(fixed,press,key: "b")])
        XCTAssertEqual(result[0].performances.count, 2)
        XCTAssertEqual(result[0].performances[0].sets.count, 1)
        XCTAssertTrue(result[0].performances[0].hasAmbiguousEvidence)
        XCTAssertEqual(result[0].setups.count, 2)
    }

    func testAdaptiveOccurrencesRemainSeparateAndCountOneWorkout() {
        let press = exercise()
        let adaptive = AdaptiveWorkoutSession(generatedPlanId: UUID(), finishedAt: Date(timeIntervalSince1970: 200), status: .completed)
        let rows = [8,12].map { reps in AdaptiveSetEntry(adaptiveSessionId: adaptive.id, occurrenceId: UUID(),
            exerciseId: press.id, setIndex: 1, weight: 50, reps: reps, isLocked: true) }
        let result = MovementHistoryService.movements(sessions: [], setEntries: [], adaptiveSessions: [adaptive],
            adaptiveSetEntries: rows, exercises: [press])
        XCTAssertEqual(result[0].workoutCount, 1)
        XCTAssertEqual(result[0].performances.count, 2)
        XCTAssertTrue(result[0].performances.allSatisfy { $0.sets.count == 1 })
    }
    func testRecoveryMirrorsDeduplicateAndPersistedRecordWins() {
        let press = exercise(), fixed = session()
        func export(_ id: String) -> ExportedSessionSummary {
            .init(id: id, date: Date(timeIntervalSince1970: 500), cycleName: "Export", cycleDayIndex: 0,
                exerciseCount: 1, exercises: [.init(exercise_id: press.id.uuidString, exercise_name: press.name,
                    muscle: "chest", sets: [.init(set_index: 1, weight: 75, reps: 7)])])
        }
        let exportedID = UUID().uuidString
        let result = MovementHistoryService.movements(sessions: [fixed], setEntries: [row(fixed, press)],
            adaptiveSessions: [], adaptiveSetEntries: [], exercises: [press],
            exports: [export(fixed.id.uuidString), export(exportedID), export(exportedID.lowercased())])
        XCTAssertEqual(result[0].workoutCount, 2)
        XCTAssertEqual(result[0].performances.map { $0.sets[0].weight }, [75,45])
    }
    func testNameOnlyLegacyExportJoinsOnlyAnUnambiguousCatalogMovement() {
        let press = exercise(), fixed = session()
        let exported = ExportedSessionSummary(id: UUID().uuidString, date: Date(timeIntervalSince1970: 500),
            cycleName: "Old export", cycleDayIndex: 0, exerciseCount: 1,
            exercises: [.init(exercise_name: "Flat Dumbbell Press", muscle: "chest",
                sets: [.init(set_index: 1, weight: 70, reps: 8)])])
        func history(_ catalog: [Exercise]) -> [MovementHistory] {
            MovementHistoryService.movements(sessions: [fixed],setEntries: [row(fixed,press)],
                adaptiveSessions: [],adaptiveSetEntries: [],exercises: catalog,exports: [exported])
        }
        XCTAssertEqual(history([press]).count, 1)
        XCTAssertEqual(history([press])[0].workoutCount, 2)
        XCTAssertEqual(history([press, exercise("Flat Dumbbell Press")]).count, 2,
            "An exact, different catalog identity must not merge with the compact-name record")
    }

    func testExportOnlyClusterEvidenceKeepsFrozenProfileAndOriginalSetNumber() throws {
        let press = exercise()
        let skipped = exercise("Skipped")
        let snapshot = SessionExportService.ClusterExerciseOccurrencePayload(position: 0, exercise_id: press.id.uuidString,
            exercise_name: press.name, muscle: "chest", prescribed_set_count: 3, progression_key: "frozen-track",
            resistance_profile: ResistanceProfilePayload(.weightStack), completion_status: "performed")
        let record = SessionExportService.ClusterOccurrencePayload(occurrence_id: UUID().uuidString,
            program_version_id: "v1", cluster_id: "cluster-1", position_index: 0, template_day_position: 0,
            day_label: "Upper", completed_at: "2026-09-20T10:00:00Z", exercises: [snapshot])
        let exported = ExportedSessionSummary(id: UUID().uuidString, date: Date(timeIntervalSince1970: 500),
            cycleName: "Program", cycleDayIndex: 0, exerciseCount: 2,
            exercises: [press, skipped].map { .init(exercise_id: $0.id.uuidString, exercise_name: $0.name,
                muscle: "chest", sets: [.init(set_index: 3, weight: 70, reps: 8)],
                resistance_profile: ResistanceProfilePayload(.voltra(chainType: .none, eccentricPercent: 0))) },
            clusterOccurrences: [record])
        let result = MovementHistoryService.movements(sessions: [],setEntries: [],adaptiveSessions: [],adaptiveSetEntries: [],
            exercises: [press,skipped], exports: [exported])
        XCTAssertEqual(result.count, 1)
        let performance = try XCTUnwrap(result.first?.performances.first)
        XCTAssertEqual(performance.profile, .weightStack)
        XCTAssertEqual(performance.progressionKey, "frozen-track")
        XCTAssertEqual(performance.sets[0].setIndex, 3)
    }

    func testCanonicalAliasesOnlyAfterExplicitConsolidationAndGripperIsNotWeight() {
        let canonical = exercise("CS DB Row"); canonical.id = CSDBRowIdentity.canonicalID
        let legacy = CSDBRowIdentity.legacyIDs.enumerated().map { index, id -> Exercise in
            let value = exercise(index == 0 ? "Helms Row" : "Chest Supported Row"); value.id = id; value.isActive = false; return value
        }
        let a = session(), b = session(200)
        let result = MovementHistoryService.movements(sessions: [a,b], setEntries: [row(a, legacy[0]),row(b,canonical)],
            adaptiveSessions: [], adaptiveSetEntries: [], exercises: [canonical] + legacy)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "CS DB Row")
        XCTAssertEqual(MovementHistoryService.matching(result, query: "helms").count, 1)
        XCTAssertEqual(MovementHistoryService.matching(result, query: "chest supported dumbbell").count, 1)
        let gripper = exercise("Captain of Crush"); gripper.id = GripperLoadPresentation.exerciseId
        let entry = row(a,gripper); entry.weight = 3
        let grippers = MovementHistoryService.movements(sessions: [a],setEntries: [entry],adaptiveSessions: [],adaptiveSetEntries: [],exercises: [gripper])
        XCTAssertTrue(grippers[0].isGripper)
        XCTAssertEqual(GripperLoadPresentation.set(grippers[0].performances[0].sets[0].weight, reps: 10, exerciseId: gripper.id), "Model 1 × 10")
    }
}
