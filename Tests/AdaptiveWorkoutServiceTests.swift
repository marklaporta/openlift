import SwiftData
import XCTest
@testable import OpenLift

final class AdaptiveWorkoutServiceTests: XCTestCase {
    func testReadinessTracksOnlyEnabledMuscles() throws {
        let (program, _) = makeProgram()
        let chestInput = MuscleReadinessInput(
            soreness: .none,
            connectiveTissuePain: .none,
            eagerness: .neutral
        )

        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: [.chest: chestInput],
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )

        XCTAssertEqual(check.responses.map(\.muscle), [.chest])
        XCTAssertFalse(check.responses.contains { $0.muscle == .abs || $0.muscle == .traps })
    }

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

    func testProposalAppliesPerMuscleExerciseSelectionWithoutChangingTheComplexDefinition() throws {
        let (program, configuredExercise) = makeProgram()
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let rotatedExercise = Exercise(
            name: "Cambered Bar Bench Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let plan = try makeProposal(
            program: program,
            exercise: configuredExercise,
            check: check,
            exerciseSelections: [
                .chest: AdaptiveExerciseSelectionRecommendation(
                    exercise: rotatedExercise,
                    reasonCodeSuffix: "exercise_rotation"
                )
            ]
        )

        let complex = try XCTUnwrap(plan.complexes.first)
        XCTAssertEqual(complex.sourceDefinitionId, program.complexes.first?.definitionId)
        XCTAssertTrue(complex.reasonCodes.contains("chest_exercise_rotation"))
        XCTAssertEqual(complex.exercises.first?.exerciseId, rotatedExercise.id)
        XCTAssertEqual(complex.exercises.first?.exerciseName, rotatedExercise.name)
        XCTAssertEqual(complex.exercises.first?.difficulty, .hard)
    }

    func testAnyProposedExerciseCanBeSubstitutedBeforeFreeze() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let replacement = Exercise(
            name: "Replacement Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
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
        context.insert(replacement)
        try context.save()

        let snapshot = try XCTUnwrap(plan.complexes.first?.exercises.first)
        let originalExerciseId = snapshot.exerciseId
        try AdaptiveWorkoutService.substituteProposedExercise(
            plan: plan,
            occurrenceId: snapshot.occurrenceId,
            to: replacement,
            modelContext: context
        )

        XCTAssertEqual(plan.status, .proposed)
        XCTAssertNil(plan.sessionId)
        XCTAssertEqual(snapshot.exerciseId, replacement.id)
        XCTAssertEqual(snapshot.exerciseName, replacement.name)
        XCTAssertEqual(snapshot.primaryMuscle, .back)
        XCTAssertEqual(snapshot.difficulty, .hard)
        XCTAssertNil(snapshot.secondaryMuscle)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveWorkoutSession>()), 0)

        let override = try XCTUnwrap(context.fetch(FetchDescriptor<AdaptiveOverrideEvent>()).first)
        XCTAssertEqual(override.kind, .substituteExercise)
        XCTAssertEqual(override.occurrenceId, snapshot.occurrenceId)
        XCTAssertEqual(override.originalExerciseId, originalExerciseId)
        XCTAssertEqual(override.replacementExerciseId, replacement.id)

        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let entries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter { $0.adaptiveSessionId == session.id }
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0.exerciseId == replacement.id })
    }

    func testProposedSlateCanExceedPlannerTargetAndAuditsAddAndRemove() throws {
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

        let additions = (1...4).map {
            Exercise(
                name: "Manual Movement \($0)",
                primaryMuscle: .biceps,
                type: .isolation,
                equipment: .cable
            )
        }
        additions.forEach(context.insert)
        try context.save()

        for addition in additions {
            try AdaptiveWorkoutService.addProposedMovement(
                plan: plan,
                exercise: addition,
                difficulty: .easy,
                prescribedSetCount: 2,
                modelContext: context
            )
        }

        XCTAssertEqual(plan.complexes.flatMap(\.exercises).count, 5)
        XCTAssertNil(plan.sessionId)
        let addedOccurrence = try XCTUnwrap(
            plan.complexes.flatMap(\.exercises).first { $0.exerciseId == additions[0].id }
        )
        try AdaptiveWorkoutService.removeProposedMovement(
            plan: plan,
            occurrenceId: addedOccurrence.occurrenceId,
            modelContext: context
        )

        XCTAssertEqual(plan.complexes.flatMap(\.exercises).count, 4)
        XCTAssertFalse(plan.complexes.flatMap(\.exercises).contains { $0.occurrenceId == addedOccurrence.occurrenceId })
        let events = try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        XCTAssertEqual(events.filter { $0.kind == .addExercise }.count, 4)
        XCTAssertEqual(events.filter { $0.kind == .removeExercise }.count, 1)
    }

    func testMovementsCanBeReorderedBeforeAndAfterFreeze() throws {
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
        let curl = Exercise(
            name: "Bayesian Curl",
            primaryMuscle: .biceps,
            type: .isolation,
            equipment: .cable
        )
        context.insert(plan)
        context.insert(curl)
        try AdaptiveWorkoutService.addProposedMovement(
            plan: plan,
            exercise: curl,
            difficulty: .easy,
            prescribedSetCount: 2,
            modelContext: context
        )
        let curlSnapshot = try XCTUnwrap(
            plan.complexes.flatMap(\.exercises).first { $0.exerciseId == curl.id }
        )

        XCTAssertTrue(
            try AdaptiveWorkoutService.movePlannedMovement(
                plan: plan,
                occurrenceId: curlSnapshot.occurrenceId,
                direction: .earlier,
                modelContext: context
            )
        )
        XCTAssertEqual(plan.complexes.sorted { $0.position < $1.position }.first?.exercises.first?.exerciseId, curl.id)

        _ = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        XCTAssertTrue(
            try AdaptiveWorkoutService.movePlannedMovement(
                plan: plan,
                occurrenceId: curlSnapshot.occurrenceId,
                direction: .later,
                modelContext: context
            )
        )
        XCTAssertEqual(plan.complexes.sorted { $0.position < $1.position }.last?.exercises.first?.exerciseId, curl.id)
        let reorderEvents = try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
            .filter { $0.kind == .reorderExercise }
        XCTAssertEqual(reorderEvents.count, 2)
        XCTAssertEqual(reorderEvents.map(\.reasonCode), [
            "user_reordered_before_freeze",
            "user_reordered_frozen_workout"
        ])
    }

    func testExerciseCanBeAddedToCrystallizedComplexWithoutChangingLockedSets() throws {
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
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let originalEntries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        originalEntries[0].weight = 60
        originalEntries[0].reps = 9
        originalEntries[0].isLocked = true
        try AdaptiveWorkoutService.markInProgress(plan: plan, modelContext: context)

        let fly = Exercise(
            name: "Cable Fly",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        context.insert(fly)
        let snapshot = try AdaptiveWorkoutService.addMovementToComplex(
            plan: plan,
            complexId: try XCTUnwrap(plan.complexes.first?.id),
            exercise: fly,
            difficulty: .easy,
            prescribedSetCount: 2,
            adaptiveSessions: [session],
            prefill: [
                1: AdaptiveSetPrefill(weight: 30, reps: 12),
                2: AdaptiveSetPrefill(weight: 30, reps: 10)
            ],
            modelContext: context
        )

        XCTAssertEqual(plan.status, .inProgress)
        XCTAssertEqual(plan.complexes.first?.exercises.count, 2)
        let allEntries = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let addedEntries = allEntries
            .filter { $0.occurrenceId == snapshot.occurrenceId }
            .sorted { $0.setIndex < $1.setIndex }
        XCTAssertEqual(addedEntries.map(\.weight), [30, 30])
        XCTAssertEqual(addedEntries.map(\.reps), [12, 10])
        XCTAssertTrue(addedEntries.allSatisfy { !$0.isLocked })
        XCTAssertEqual(originalEntries[0].weight, 60)
        XCTAssertEqual(originalEntries[0].reps, 9)
        XCTAssertTrue(originalEntries[0].isLocked)
        let event = try XCTUnwrap(
            context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
                .first { $0.occurrenceId == snapshot.occurrenceId }
        )
        XCTAssertEqual(event.kind, .addExercise)
        XCTAssertEqual(event.reasonCode, "user_added_to_frozen_complex")
    }

    func testSkippedExerciseCanBeRestoredWithoutLosingItsSetRows() throws {
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
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let occurrenceId = try XCTUnwrap(plan.complexes.first?.exercises.first?.occurrenceId)
        let rowsBefore = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter { $0.adaptiveSessionId == session.id && $0.occurrenceId == occurrenceId }

        try AdaptiveWorkoutService.recordSkip(
            plan: plan,
            complexId: nil,
            occurrenceId: occurrenceId,
            kind: .skipExercise,
            modelContext: context,
            now: Date(timeIntervalSince1970: 100)
        )
        var events = try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        XCTAssertTrue(
            AdaptiveWorkoutService.isExerciseSkipped(
                planId: plan.id,
                occurrenceId: occurrenceId,
                overrides: events
            )
        )

        try AdaptiveWorkoutService.recordUnskipExercise(
            plan: plan,
            occurrenceId: occurrenceId,
            modelContext: context,
            now: Date(timeIntervalSince1970: 200)
        )
        events = try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        XCTAssertFalse(
            AdaptiveWorkoutService.isExerciseSkipped(
                planId: plan.id,
                occurrenceId: occurrenceId,
                overrides: events
            )
        )
        XCTAssertEqual(events.filter { $0.kind == .skipExercise }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .unskipExercise }.count, 1)
        let rowsAfter = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
            .filter { $0.adaptiveSessionId == session.id && $0.occurrenceId == occurrenceId }
        XCTAssertEqual(Set(rowsAfter.map(\.id)), Set(rowsBefore.map(\.id)))
    }

    func testManualSlateEditsCanCreateHardQuadHamstringPair() throws {
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
        let quad = Exercise(name: "Hack Squat", primaryMuscle: .quads, type: .compound, equipment: .machine)
        let hamstring = Exercise(name: "SLDL", primaryMuscle: .hamstrings, type: .compound, equipment: .barbell)
        context.insert(quad)
        context.insert(hamstring)
        try context.save()

        try AdaptiveWorkoutService.addProposedMovement(
            plan: plan,
            exercise: quad,
            difficulty: .hard,
            prescribedSetCount: 2,
            modelContext: context
        )
        try AdaptiveWorkoutService.addProposedMovement(
            plan: plan,
            exercise: hamstring,
            difficulty: .hard,
            prescribedSetCount: 2,
            modelContext: context
        )
        XCTAssertTrue(plan.complexes.contains { $0.primaryMuscle == .quads })
        XCTAssertTrue(plan.complexes.contains { $0.primaryMuscle == .hamstrings })
    }

    func testEmptyProposedSlateCannotBeFrozen() throws {
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
        try context.save()
        let occurrenceId = try XCTUnwrap(plan.complexes.first?.exercises.first?.occurrenceId)
        try AdaptiveWorkoutService.removeProposedMovement(
            plan: plan,
            occurrenceId: occurrenceId,
            modelContext: context
        )

        XCTAssertThrowsError(try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)) { error in
            XCTAssertEqual(error as? AdaptiveWorkoutServiceError, .emptyProposedPlan)
        }
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

    func testFrozenSubstitutionUsesExerciseCategoryAndUpdatesSnapshotAndRows() throws {
        let (context, _) = makeContext()
        let (program, press) = makeProgram()
        let fly = Exercise(
            name: "Cable Fly",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-20",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: press, check: check)
        context.insert(plan)
        context.insert(fly)
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let snapshot = try XCTUnwrap(plan.complexes.first?.exercises.first)
        let rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        rows.first?.weight = 60
        rows.first?.reps = 9
        rows.first?.isLocked = true

        try AdaptiveWorkoutService.substitute(
            plan: plan,
            occurrenceId: snapshot.occurrenceId,
            fromExerciseId: press.id,
            to: fly,
            difficulty: .hard,
            adaptiveSessions: [session],
            setEntries: rows,
            modelContext: context
        )

        XCTAssertEqual(snapshot.exerciseId, fly.id)
        XCTAssertEqual(snapshot.exerciseName, fly.name)
        XCTAssertEqual(snapshot.difficulty, .easy)
        XCTAssertTrue(rows.allSatisfy { $0.exerciseId == fly.id })
        XCTAssertEqual(rows.first?.weight, 60)
        XCTAssertEqual(rows.first?.reps, 9)
        XCTAssertTrue(rows.first?.isLocked == true)
        XCTAssertEqual(rows.last?.weight, 0)
        XCTAssertFalse(rows.last?.isLocked == true)
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

    func testRecoveredReadinessDefaultsSubmitWithoutPerFieldConfirmation() throws {
        let (program, _) = makeProgram()
        var inputs = AdaptiveWorkoutService.defaultReadinessInputs(for: program)
        XCTAssertEqual(inputs[.chest], AdaptiveWorkoutService.recoveredReadiness)
        inputs[.chest]?.soreness = .mild

        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: inputs,
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let response = try XCTUnwrap(check.responses.first)
        XCTAssertEqual(response.soreness, .mild)
        XCTAssertEqual(response.connectiveTissuePain, .none)
        XCTAssertEqual(response.eagerness, .eager)
    }

    @MainActor
    func testReadinessRevisionPreservesEquivalentProposalAndReplacesMaterialChange() throws {
        let (context, _) = makeV6Context()
        let (program, exercise) = makeProgram()
        let firstCheck = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: AdaptiveWorkoutService.defaultReadinessInputs(for: program),
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let firstPlan = try makeProposal(program: program, exercise: exercise, check: firstCheck)
        let state = AdaptiveWorkoutService.makeDesignState(
            plan: firstPlan,
            targetComplexCount: 1,
            readinessRevision: 1
        )
        context.insert(firstCheck)
        context.insert(firstPlan)
        context.insert(state)
        let manualAudit = AdaptiveOverrideEvent(
            generatedPlanId: firstPlan.id,
            kind: .addExercise,
            reasonCode: "test_manual_edit"
        )
        context.insert(manualAudit)
        try context.save()

        firstPlan.complexes.first?.name = "My Manual Label"
        let equivalentCheck = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: AdaptiveWorkoutService.defaultReadinessInputs(for: program),
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 2
        )
        context.insert(equivalentCheck)
        let equivalent = try makeProposal(program: program, exercise: exercise, check: equivalentCheck)
        XCTAssertTrue(try AdaptiveWorkoutService.reconcileReadinessRevision(
            existingPlan: firstPlan,
            existingState: state,
            candidatePlan: equivalent,
            readinessCheck: equivalentCheck,
            overrides: [manualAudit],
            modelContext: context
        ))
        XCTAssertEqual(firstPlan.complexes.first?.name, "My Manual Label")
        XCTAssertEqual(state.readinessRevision, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveOverrideEvent>()), 1)

        let replacementExercise = Exercise(
            name: "Flat Bench",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let changed = try makeProposal(
            program: program,
            exercise: replacementExercise,
            check: equivalentCheck
        )
        XCTAssertFalse(try AdaptiveWorkoutService.reconcileReadinessRevision(
            existingPlan: firstPlan,
            existingState: state,
            candidatePlan: changed,
            readinessCheck: equivalentCheck,
            overrides: [manualAudit],
            modelContext: context
        ))
        let stored = try context.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, changed.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveOverrideEvent>()), 0)
    }

    func testTodayExposureTargetPersistsWithoutChangingProfileDefault() throws {
        let (context, _) = makeV6Context()
        let (program, exercise) = makeProgram()
        let preference = AdaptiveWorkoutSizePreference(
            adaptiveProgramId: program.id,
            defaultComplexCount: 4
        )
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: AdaptiveWorkoutService.defaultReadinessInputs(for: program),
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        let state = AdaptiveWorkoutService.makeDesignState(
            plan: plan,
            targetComplexCount: 2,
            readinessRevision: 1
        )
        context.insert(preference)
        context.insert(check)
        context.insert(plan)
        context.insert(state)
        try context.save()

        XCTAssertEqual(state.targetComplexCount, 2)
        XCTAssertEqual(preference.defaultComplexCount, 4)
        XCTAssertEqual(plan.complexes.count, 1)
    }

    func testActiveSubstitutionAndRemovalCorrectLockedWorkWithoutOrphans() throws {
        let (context, _) = makeContext()
        let (program, exercise) = makeProgram()
        let replacement = Exercise(
            name: "Cable Row",
            primaryMuscle: .back,
            type: .compound,
            equipment: .cable
        )
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: exercise, check: check)
        context.insert(check)
        context.insert(plan)
        context.insert(exercise)
        context.insert(replacement)
        try context.save()
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        var rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let firstRow = try XCTUnwrap(rows.first { $0.setIndex == 1 })
        let secondRow = try XCTUnwrap(rows.first { $0.setIndex == 2 })
        firstRow.weight = 60
        firstRow.reps = 9
        firstRow.isLocked = true
        secondRow.weight = 55
        secondRow.reps = 10
        secondRow.isLocked = true
        try context.save()
        let occurrenceId = try XCTUnwrap(plan.complexes.first?.exercises.first?.occurrenceId)
        let snapshot = try XCTUnwrap(plan.complexes.first?.exercises.first)

        XCTAssertTrue(try AdaptiveWorkoutService.removeLastSet(
            snapshot: snapshot,
            existingEntries: rows,
            modelContext: context
        ))
        rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(snapshot.prescribedSetCount, 1)

        try AdaptiveWorkoutService.substitute(
            plan: plan,
            occurrenceId: occurrenceId,
            fromExerciseId: exercise.id,
            to: replacement,
            difficulty: .hard,
            adaptiveSessions: [session],
            setEntries: rows,
            modelContext: context
        )
        rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let correctedRow = try XCTUnwrap(rows.first { $0.setIndex == 1 })
        XCTAssertEqual(correctedRow.exerciseId, replacement.id)
        XCTAssertEqual(correctedRow.weight, 60)
        XCTAssertEqual(correctedRow.reps, 9)
        XCTAssertTrue(correctedRow.isLocked)
        let payload = AdaptiveExportService.makePayload(
            plan: plan,
            session: session,
            readiness: check,
            setEntries: rows,
            exercises: [exercise, replacement],
            overrides: try context.fetch(FetchDescriptor<AdaptiveOverrideEvent>()),
            feedback: []
        )
        XCTAssertEqual(payload.plan.complexes[0].exercises[0].sets[0].exercise_id, replacement.id.uuidString)
        XCTAssertEqual(payload.plan.complexes[0].exercises[0].sets[0].weight, 60)

        XCTAssertTrue(try AdaptiveWorkoutService.removeLastSet(
            snapshot: snapshot,
            existingEntries: rows,
            modelContext: context
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 0)
        XCTAssertEqual(snapshot.prescribedSetCount, 0)
        _ = try AdaptiveWorkoutService.addSet(
            snapshot: snapshot,
            session: session,
            existingEntries: [],
            modelContext: context
        )
        rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.exerciseId, replacement.id)

        try AdaptiveWorkoutService.removeMovement(
            plan: plan,
            occurrenceId: occurrenceId,
            adaptiveSessions: [session],
            setEntries: rows,
            modelContext: context
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdaptiveSetEntry>()), 0)
        XCTAssertTrue(plan.complexes.isEmpty)
    }

    func testAddMissingComplexAppendsWithoutChangingExistingWork() throws {
        let (context, _) = makeContext()
        let (program, chest) = makeProgram()
        let calves = Exercise(
            name: "Standing Calf Raise",
            primaryMuscle: .calves,
            type: .isolation,
            equipment: .machine
        )
        let calfDefinition = AdaptiveExerciseComplex(
            definitionId: UUID(),
            version: 1,
            name: "Calves",
            position: 1,
            primaryMuscle: .calves,
            qualifiesForPrimaryFloor: true,
            components: [
                AdaptiveComplexComponent(
                    position: 0,
                    exerciseId: calves.id,
                    prescribedSetCount: 2,
                    primaryMuscle: .calves,
                    difficulty: .easy
                )
            ]
        )
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: chest, check: check)
        context.insert(check)
        context.insert(plan)
        context.insert(chest)
        context.insert(calves)
        try context.save()
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let originalOccurrence = try XCTUnwrap(plan.complexes.first?.exercises.first?.occurrenceId)
        let originalRows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).filter {
            $0.occurrenceId == originalOccurrence
        }
        originalRows[0].weight = 60
        originalRows[0].reps = 9
        originalRows[0].isLocked = true
        try context.save()

        let appended = try AdaptiveWorkoutService.appendComplex(
            plan: plan,
            definition: calfDefinition,
            exercises: [chest, calves],
            adaptiveSessions: [session],
            modelContext: context
        )
        XCTAssertEqual(plan.complexes.sorted(by: { $0.position < $1.position }).map(\.primaryMuscle), [.chest, .calves])
        XCTAssertEqual(appended.exercises.count, 1)
        let allRows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>())
        let preserved = try XCTUnwrap(allRows.first { $0.id == originalRows[0].id })
        XCTAssertEqual(preserved.weight, 60)
        XCTAssertTrue(preserved.isLocked)
        XCTAssertEqual(allRows.filter { $0.occurrenceId == appended.exercises[0].occurrenceId }.count, 2)
    }

    func testManualComplexUsesRequestedDoseAndDoesNotMutatePlanWithoutActiveSession() throws {
        let (context, _) = makeContext()
        let (program, chest) = makeProgram()
        let calves = Exercise(
            name: "Standing Calf Raise",
            primaryMuscle: .calves,
            type: .isolation,
            equipment: .machine
        )
        let check = try AdaptiveWorkoutService.makeReadinessCheck(
            program: program,
            inputs: readyInputs,
            localDateKey: "2026-07-21",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1
        )
        let plan = try makeProposal(program: program, exercise: chest, check: check)
        context.insert(check)
        context.insert(plan)
        context.insert(chest)
        context.insert(calves)
        try context.save()
        let originalComplexCount = plan.complexes.count
        plan.status = .frozen

        XCTAssertThrowsError(try AdaptiveWorkoutService.appendComplex(
            plan: plan,
            definition: nil,
            manualExercise: calves,
            manualPrescribedSetCount: 3,
            exercises: [chest, calves],
            adaptiveSessions: [],
            modelContext: context
        )) { error in
            XCTAssertEqual(error as? AdaptiveWorkoutServiceError, .adaptiveSessionNotFound)
        }
        XCTAssertEqual(plan.complexes.count, originalComplexCount)

        plan.status = .proposed
        let session = try AdaptiveWorkoutService.freeze(plan: plan, modelContext: context)
        let appended = try AdaptiveWorkoutService.appendComplex(
            plan: plan,
            definition: nil,
            manualExercise: calves,
            manualPrescribedSetCount: 3,
            exercises: [chest, calves],
            adaptiveSessions: [session],
            prefillByExerciseId: [
                calves.id: [1: AdaptiveSetPrefill(weight: 90, reps: 12)]
            ],
            modelContext: context
        )
        XCTAssertEqual(appended.exercises.first?.prescribedSetCount, 3)
        let rows = try context.fetch(FetchDescriptor<AdaptiveSetEntry>()).filter {
            $0.occurrenceId == appended.exercises.first?.occurrenceId
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first(where: { $0.setIndex == 1 })?.weight, 90)
        XCTAssertEqual(rows.first(where: { $0.setIndex == 1 })?.reps, 12)
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
        check: DailyReadinessCheck,
        exerciseSelections: [MuscleGroup: AdaptiveExerciseSelectionRecommendation] = [:]
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
            timeZoneIdentifier: "America/Los_Angeles",
            exerciseSelections: exerciseSelections
        )
    }

    private func makeContext() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV4.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }

    private func makeV6Context() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV7.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }
}
