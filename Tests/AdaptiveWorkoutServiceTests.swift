import SwiftData
import XCTest
@testable import OpenLift

final class AdaptiveWorkoutServiceTests: XCTestCase {
    func testOpeningWorkflowCreatesNoSessionBeforeProposalIsAccepted() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let proposal = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(check)
        context.insert(proposal)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyReadinessCheck>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GeneratedWorkoutPlan>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 0)
        XCTAssertEqual(proposal.status, .proposed)
    }

    func testFreezeSnapshotsPlanAndDefinitionEditsCannotRewriteIt() throws {
        let (context, container) = makeContext()
        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(check)
        context.insert(plan)
        try context.save()

        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let snapshot = plan.complexes.first!
        let exerciseSnapshot = snapshot.exercises.first!
        let originalName = exerciseSnapshot.exerciseName
        let originalSets = exerciseSnapshot.prescribedSetCount

        program.complexes.first?.name = "Changed Definition"
        program.complexes.first?.components.first?.prescribedSetCount = 1
        exercise.name = "Renamed Exercise"
        try context.save()

        XCTAssertEqual(plan.status, .frozen)
        XCTAssertEqual(plan.sessionId, session.id)
        XCTAssertEqual(exerciseSnapshot.exerciseName, originalName)
        XCTAssertEqual(exerciseSnapshot.prescribedSetCount, originalSets)
        let entries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.occurrenceId)), [exerciseSnapshot.occurrenceId])

        let reloadedContext = ModelContext(container)
        let reloadedPlans = try reloadedContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        let reloadedSessions = try reloadedContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
        let reloadedEntries = try reloadedContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(reloadedPlans.first(where: { $0.id == plan.id })?.status, .frozen)
        XCTAssertEqual(reloadedSessions.first(where: { $0.id == session.id })?.generatedPlanId, plan.id)
        XCTAssertEqual(reloadedEntries.filter { $0.adaptiveSessionId == session.id }.count, 2)
        XCTAssertEqual(
            reloadedPlans.first(where: { $0.id == plan.id })?.complexes.first?.exercises.first?.exerciseName,
            originalName
        )
    }

    func testRegenerationIsRejectedAfterFirstLockedSet() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(check)
        context.insert(plan)
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let entries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        entries.first?.weight = 60
        entries.first?.reps = 9
        entries.first?.isLocked = true
        try context.save()

        XCTAssertFalse(
            AdaptiveWorkoutService.canRegenerate(
                plan: plan,
                adaptiveSessions: [session],
                setEntries: entries
            )
        )
        XCTAssertThrowsError(
            try AdaptiveWorkoutService.discardForRegeneration(
                plan: plan,
                adaptiveSessions: [session],
                setEntries: entries,
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(error as? AdaptiveWorkoutServiceError, .planAlreadyStarted)
        }
    }

    func testAdaptiveCompletionDoesNotChangeRotationPointerOrIndices() throws {
        let (context, _) = makeContext()
        let rotation = ActiveCycleInstance(templateId: UUID(), currentDayIndex: 3)
        context.insert(rotation)
        let originalRotationValue = rotation.rotationIndices.first!.value

        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(check)
        context.insert(plan)
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let entries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        entries.first?.weight = 60
        entries.first?.reps = 9
        entries.first?.isLocked = true

        try AdaptiveWorkoutService.complete(
            plan: plan,
            adaptiveSessions: [session],
            setEntries: entries,
            modelContext: context
        )

        XCTAssertEqual(plan.status, .completed)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(rotation.currentDayIndex, 3)
        XCTAssertEqual(rotation.rotationIndices.first?.value, originalRotationValue)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
    }

    func testFeedbackReplacesPriorRatingAndPainCreatesSeparateSafetyEvent() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(plan)
        let complex = plan.complexes.first!
        try AdaptiveWorkoutService.recordFeedback(
            plan: plan,
            complex: complex,
            rating: .tooLittle,
            existingFeedback: [],
            modelContext: context
        )
        let first = try context.fetch(FetchDescriptor<ComplexFeedback>())
        try AdaptiveWorkoutService.recordFeedback(
            plan: plan,
            complex: complex,
            rating: .painProblem,
            existingFeedback: first,
            modelContext: context
        )

        let saved = try context.fetch(FetchDescriptor<ComplexFeedback>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.rating, .painProblem)
        let events = try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .painBlock)
        XCTAssertEqual(events.first?.muscle, .chest)
    }

    func testAdaptivePrefillPrefersSameOccurrenceContextAndKeepsValuesEditable() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let priorPlan = try makeProposal(program: program, exercise: exercise, check: check)
        priorPlan.status = .completed
        let priorSession = AdaptiveWorkoutSession(
            generatedPlanId: priorPlan.id,
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            status: .completed,
            exportStatus: .success
        )
        let priorOccurrence = priorPlan.complexes.first!.exercises.first!.occurrenceId
        let priorRows = [
            AdaptiveSetEntry(
                adaptiveSessionId: priorSession.id,
                occurrenceId: priorOccurrence,
                exerciseId: exercise.id,
                setIndex: 1,
                weight: 60,
                reps: 9,
                isLocked: true
            ),
            AdaptiveSetEntry(
                adaptiveSessionId: priorSession.id,
                occurrenceId: priorOccurrence,
                exerciseId: exercise.id,
                setIndex: 2,
                weight: 60,
                reps: 8,
                isLocked: true
            )
        ]
        let newerAdHoc = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "Off-Schedule",
            dayLabelSnapshot: "Off-Schedule",
            createdAt: Date(timeIntervalSince1970: 250),
            finishedAt: Date(timeIntervalSince1970: 300),
            status: .completed
        )
        let adHocRow = SetEntry(
            sessionId: newerAdHoc.id,
            exerciseId: exercise.id,
            setIndex: 1,
            weight: 70,
            reps: 7,
            isLocked: true
        )
        let currentPlan = try makeProposal(program: program, exercise: exercise, check: check)

        let prefill = AdaptivePrefillService.prefill(
            plan: currentPlan,
            adaptivePlans: [priorPlan, currentPlan],
            adaptiveSessions: [priorSession],
            adaptiveSetEntries: priorRows,
            rotationSessions: [newerAdHoc],
            rotationSetEntries: [adHocRow],
            overrides: []
        )
        let currentOccurrence = currentPlan.complexes.first!.exercises.first!.occurrenceId
        XCTAssertEqual(prefill[currentOccurrence]?[1], AdaptiveSetPrefill(weight: 60, reps: 9))
        XCTAssertEqual(prefill[currentOccurrence]?[2], AdaptiveSetPrefill(weight: 60, reps: 8))

        context.insert(currentPlan)
        _ = try AdaptiveWorkoutService.freeze(
            plan: currentPlan,
            modelContext: context,
            prefill: prefill
        )
        let created = try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(created.map(\.weight), [60, 60])
        XCTAssertEqual(created.map(\.reps), [9, 8])
        XCTAssertTrue(created.allSatisfy { !$0.isLocked })
    }

    @MainActor
    func testAdaptiveV2RoundTripPreservesDuplicateOccurrencesOrderFeedbackAndProvenance() throws {
        let exercise = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let firstExercise = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: .chest,
            difficulty: .moderate,
            prescribedSetCount: 1
        )
        let secondExercise = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: .chest,
            difficulty: .easy,
            prescribedSetCount: 1
        )
        let firstComplex = PlannedComplexSnapshot(
            sourceDefinitionId: UUID(),
            sourceVersion: 2,
            position: 0,
            name: "Press First",
            primaryMuscle: .chest,
            reasonCodes: ["chest_priority"],
            exercises: [firstExercise]
        )
        let secondComplex = PlannedComplexSnapshot(
            sourceDefinitionId: UUID(),
            sourceVersion: 4,
            position: 1,
            name: "Press Again",
            primaryMuscle: .chest,
            reasonCodes: ["chest_dose_fit"],
            exercises: [secondExercise]
        )
        let programId = UUID()
        let check = DailyReadinessCheck(
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            adaptiveProgramId: programId,
            adaptiveProgramVersion: 3,
            responses: MuscleGroup.allCases.map {
                AdaptiveReadinessResponse(
                    muscle: $0,
                    soreness: .none,
                    connectiveTissuePain: .none,
                    eagerness: .neutral
                )
            }
        )
        let sessionId = UUID()
        let plan = GeneratedWorkoutPlan(
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            createdAt: Date(timeIntervalSince1970: 1_800_000_010),
            frozenAt: Date(timeIntervalSince1970: 1_800_000_020),
            status: .completed,
            adaptiveProgramId: programId,
            adaptiveProgramVersion: 3,
            readinessCheckId: check.id,
            plannerVersion: 1,
            reasonCodes: ["chest_priority"],
            sessionId: sessionId,
            complexes: [firstComplex, secondComplex]
        )
        let session = AdaptiveWorkoutSession(
            id: sessionId,
            generatedPlanId: plan.id,
            createdAt: plan.createdAt,
            finishedAt: Date(timeIntervalSince1970: 1_800_000_100),
            status: .completed,
            exportStatus: .success
        )
        let entries = [
            AdaptiveSetEntry(
                adaptiveSessionId: session.id,
                occurrenceId: firstExercise.occurrenceId,
                exerciseId: exercise.id,
                setIndex: 1,
                weight: 60,
                reps: 9,
                isLocked: true
            ),
            AdaptiveSetEntry(
                adaptiveSessionId: session.id,
                occurrenceId: secondExercise.occurrenceId,
                exerciseId: exercise.id,
                setIndex: 1,
                weight: 55,
                reps: 10,
                isLocked: true
            )
        ]
        let feedback = ComplexFeedback(
            generatedPlanId: plan.id,
            plannedComplexId: firstComplex.id,
            rating: .justRight
        )
        let pain = AdaptiveOverrideEvent(
            generatedPlanId: plan.id,
            plannedComplexId: secondComplex.id,
            kind: .painBlock,
            muscle: .chest,
            reasonCode: "warmup_veto"
        )

        let payload = AdaptiveExportService.makePayload(
            plan: plan,
            session: session,
            readiness: check,
            setEntries: entries,
            exercises: [exercise],
            overrides: [pain],
            feedback: [feedback]
        )
        let decoded = try XCTUnwrap(AdaptiveExportService.decode(AdaptiveExportService.encode(payload)))
        XCTAssertEqual(decoded.schema_version, 2)
        XCTAssertEqual(decoded.workout_kind, "adaptive")
        XCTAssertEqual(decoded.plan.complexes.map(\.name), ["Press First", "Press Again"])
        XCTAssertNotEqual(
            decoded.plan.complexes[0].exercises[0].occurrence_id,
            decoded.plan.complexes[1].exercises[0].occurrence_id
        )

        let (targetContext, _) = makeContext()
        XCTAssertTrue(try AdaptiveExportService.hydrate(decoded, modelContext: targetContext))
        XCTAssertFalse(try AdaptiveExportService.hydrate(decoded, modelContext: targetContext))
        let recoveredPlans = try targetContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        XCTAssertEqual(recoveredPlans.first?.complexes.sorted(by: { $0.position < $1.position }).map(\.name), ["Press First", "Press Again"])
        let recoveredEntries = try targetContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(recoveredEntries.count, 2)
        XCTAssertEqual(Set(recoveredEntries.map(\.occurrenceId)).count, 2)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<ComplexFeedback>()), 1)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<AdaptiveOverrideEvent>()), 1)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<Session>()), 0)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<ActiveCycleInstance>()), 0)
    }

    private var readyInputs: [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
            ($0, MuscleReadinessInput(soreness: .none, connectiveTissuePain: .none, eagerness: .neutral))
        })
    }

    private func makeProgram() -> (AdaptiveProgram, Exercise) {
        let exercise = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let component = AdaptiveComplexComponent(
            position: 0,
            exerciseId: exercise.id,
            prescribedSetCount: 2,
            primaryMuscle: .chest,
            difficulty: .moderate
        )
        let complex = AdaptiveExerciseComplex(
            definitionId: UUID(),
            version: 1,
            name: "Incline Press",
            position: 0,
            primaryMuscle: .chest,
            qualifiesForPrimaryFloor: true,
            components: [component]
        )
        let rules = MuscleGroup.allCases.map { muscle in
            AdaptiveMuscleRule(
                muscle: muscle,
                priorityRank: muscle == .chest ? 1 : 0,
                rollingSetFloor: 0,
                rollingWindowDays: 7,
                maxRecoveredDayGap: 10,
                maxExercisesPerExposure: 2,
                maxSetsPerExercise: 3,
                isEnabled: muscle == .chest
            )
        }
        return (
            AdaptiveProgram(
                version: 1,
                name: "Test",
                isReviewedForUse: true,
                globalMaxMovements: 4,
                maxDifficultyCost: 8,
                muscleRules: rules,
                complexes: [complex]
            ),
            exercise
        )
    }

    private func makeProposal(
        program: AdaptiveProgram,
        exercise: Exercise,
        check: DailyReadinessCheck
    ) throws -> GeneratedWorkoutPlan {
        let component = AdaptivePlannedComponent(
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            position: 0,
            primaryMuscle: .chest,
            secondaryMuscle: nil,
            difficulty: .moderate,
            prescribedSetCount: 2
        )
        let complex = AdaptivePlannedComplex(
            definitionId: program.complexes.first!.definitionId,
            version: 1,
            name: "Incline Press",
            sourcePosition: 0,
            primaryMuscle: .chest,
            reasonCodes: ["chest_priority"],
            components: [component]
        )
        return try AdaptiveWorkoutService.makeProposedPlan(
            result: .proposal(
                AdaptivePlanProposal(
                    complexes: [complex],
                    totalMovements: 1,
                    totalDifficultyCost: 2,
                    muscleSetDose: [.chest: 2],
                    rejections: []
                )
            ),
            program: program,
            readinessCheck: check,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles"
        )
    }

    private func makeContext() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV3.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }
}
