import SwiftData
import XCTest
@testable import OpenLift

final class AdaptiveProgramServiceTests: XCTestCase {
    func testBlankDraftUsesRequestedPriorityAndLeavesUnsupportedMusclesDisabled() {
        let draft = AdaptiveProgramDraft.blank
        let enabled = draft.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }

        XCTAssertEqual(enabled.map(\.muscle), MuscleGroup.initialAdaptiveRankOrder)
        XCTAssertEqual(enabled.map(\.priorityRank), Array(1...MuscleGroup.initialAdaptiveRankOrder.count))
        XCTAssertEqual(enabled[4].muscle, .sideDelts)
        XCTAssertEqual(draft.globalMaxMovements, 4)
        XCTAssertEqual(draft.defaultComplexCount, 4)
        XCTAssertEqual(draft.maxDifficultyCost, 60)
        XCTAssertTrue(enabled.allSatisfy { $0.rollingSetFloor == 1 })

        for muscle in [MuscleGroup.glutes, .abs, .traps] {
            let rule = draft.muscleRules.first { $0.muscle == muscle }
            XCTAssertEqual(rule?.priorityRank, 0)
            XCTAssertEqual(rule?.rollingSetFloor, 0)
            XCTAssertEqual(rule?.isEnabled, false)
        }
    }

    func testTargetedEquipmentCorrectionDisablesMuscleAndComplexWithoutReplacingProfile() throws {
        var exercises = makeRankedExercises()
        let gluteExercise = makeExercise(for: .glutes)
        exercises.append(gluteExercise)
        var draft = AdaptiveProgramService.demoDraft(exercises: exercises)
        let gluteRuleIndex = try XCTUnwrap(draft.muscleRules.firstIndex { $0.muscle == .glutes })
        draft.muscleRules[gluteRuleIndex].isEnabled = true
        draft.muscleRules[gluteRuleIndex].priorityRank = draft.muscleRules.filter(\.isEnabled).count
        draft.muscleRules[gluteRuleIndex].rollingSetFloor = 1
        draft.complexes.append(
            AdaptiveExerciseComplexDraft(
                id: UUID(),
                definitionId: UUID(),
                sourceVersion: 0,
                name: "Glutes",
                primaryMuscle: .glutes,
                qualifiesForPrimaryFloor: true,
                isEnabled: true,
                components: [
                    AdaptiveComplexComponentDraft(
                        id: UUID(),
                        exerciseId: gluteExercise.id,
                        prescribedSetCount: 2,
                        primaryMuscle: .glutes,
                        secondaryMuscle: nil,
                        difficulty: .easy
                    )
                ]
            )
        )
        let (context, _) = makeContext()
        let program = try AdaptiveProgramService.saveVersion(
            draft: draft,
            replacing: nil,
            allPrograms: [],
            exercises: exercises,
            modelContext: context
        )
        let originalId = program.id
        let originalVersion = program.version

        XCTAssertGreaterThan(
            try AdaptiveProgramService.disableMuscleProgramming(.glutes, modelContext: context),
            0
        )

        XCTAssertEqual(program.id, originalId)
        XCTAssertEqual(program.version, originalVersion)
        let gluteRule = try XCTUnwrap(program.muscleRules.first { $0.muscle == .glutes })
        XCTAssertFalse(gluteRule.isEnabled)
        XCTAssertEqual(gluteRule.priorityRank, 0)
        XCTAssertEqual(gluteRule.rollingSetFloor, 0)
        XCTAssertTrue(program.complexes.filter { $0.primaryMuscle == .glutes }.allSatisfy { !$0.isEnabled })
        let enabledRules = program.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }
        XCTAssertEqual(enabledRules.map(\.priorityRank), Array(1...enabledRules.count))
        let proposal = try XCTUnwrap(
            AdaptiveForecastService.expectedProposal(
                program: program,
                exercises: exercises,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                targetComplexCount: 4,
                asOf: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        XCTAssertFalse(proposal.complexes.contains { $0.primaryMuscle == .glutes })
        XCTAssertEqual(
            try AdaptiveProgramService.disableMuscleProgramming(.glutes, modelContext: context),
            0
        )
    }

    func testDemoDraftDoesNotInventExercisesForMissingMuscles() {
        let chest = makeExercise(for: .chest)
        let draft = AdaptiveProgramService.demoDraft(exercises: [chest])

        XCTAssertEqual(draft.complexes.count, 1)
        XCTAssertEqual(draft.complexes.first?.primaryMuscle, .chest)
        XCTAssertThrowsError(try AdaptiveProgramService.validate(draft, exercises: [chest])) { error in
            XCTAssertEqual(error as? AdaptiveProgramValidationError, .noFloorQualifyingComplex(.back))
        }
    }

    func testValidDraftSavesAndBecomesActive() throws {
        let exercises = makeRankedExercises()
        let draft = AdaptiveProgramService.demoDraft(exercises: exercises)
        let (context, _) = makeContext()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        let saved = try AdaptiveProgramService.saveVersion(
            draft: draft,
            replacing: nil,
            allPrograms: [],
            exercises: exercises,
            modelContext: context,
            now: createdAt
        )

        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.createdAt, createdAt)
        XCTAssertTrue(saved.isActiveVersion)
        XCTAssertFalse(saved.isReviewedForUse)
        XCTAssertEqual(saved.muscleRules.count, MuscleGroup.allCases.count)
        XCTAssertEqual(saved.complexes.count, MuscleGroup.initialAdaptiveRankOrder.count)
        XCTAssertEqual(AdaptiveProgramService.activeProgram(from: [saved])?.id, saved.id)
        let sizePreference = try XCTUnwrap(
            context.fetch(FetchDescriptor<AdaptiveWorkoutSizePreference>()).first
        )
        XCTAssertEqual(sizePreference.adaptiveProgramId, saved.id)
        XCTAssertEqual(sizePreference.defaultComplexCount, draft.defaultComplexCount)
    }

    func testValidationRejectsNonBinaryExposureRequirementAndAtomicComplexCaps() {
        let exercises = makeRankedExercises()
        var floorDraft = AdaptiveProgramService.demoDraft(exercises: exercises)
        let chestIndex = floorDraft.muscleRules.firstIndex { $0.muscle == .chest }!
        floorDraft.muscleRules[chestIndex].rollingSetFloor = 2

        XCTAssertThrowsError(try AdaptiveProgramService.validate(floorDraft, exercises: exercises)) { error in
            XCTAssertEqual(
                error as? AdaptiveProgramValidationError,
                .invalidMuscleLimit(
                    muscle: .chest,
                    field: "rolling exposure requirement",
                    value: 2
                )
            )
        }

        var capDraft = AdaptiveProgramService.demoDraft(exercises: exercises)
        capDraft.globalMaxMovements = 1
        capDraft.complexes[0].components.append(
            AdaptiveComplexComponentDraft(
                id: UUID(),
                exerciseId: exercises[1].id,
                prescribedSetCount: 1,
                primaryMuscle: exercises[1].primaryMuscle,
                secondaryMuscle: nil,
                difficulty: .easy
            )
        )
        XCTAssertThrowsError(try AdaptiveProgramService.validate(capDraft, exercises: exercises)) { error in
            XCTAssertEqual(
                error as? AdaptiveProgramValidationError,
                .complexExceedsMovementCap(name: "Chest", count: 2, cap: 1)
            )
        }
    }

    func testSavingEditCreatesImmutableVersionAndPreservesDefinitionIdentity() throws {
        let exercises = makeRankedExercises()
        let (context, _) = makeContext()
        let first = try AdaptiveProgramService.saveVersion(
            draft: AdaptiveProgramService.demoDraft(exercises: exercises),
            replacing: nil,
            allPrograms: [],
            exercises: exercises,
            modelContext: context
        )
        let originalName = first.name
        let originalComplex = first.complexes.sorted { $0.position < $1.position }.first!
        let originalDefinitionId = originalComplex.definitionId
        let originalComplexName = originalComplex.name
        let originalSetCount = originalComplex.components.first!.prescribedSetCount

        var edited = AdaptiveProgramDraft(existing: first)
        edited.name = "Edited Adaptive Profile"
        let editedIndex = edited.complexes.firstIndex { $0.definitionId == originalDefinitionId }!
        edited.complexes[editedIndex].name = "Edited Chest Complex"
        edited.complexes[editedIndex].components[0].prescribedSetCount = 3

        let second = try AdaptiveProgramService.saveVersion(
            draft: edited,
            replacing: first,
            allPrograms: [first],
            exercises: exercises,
            modelContext: context
        )

        XCTAssertEqual(first.name, originalName)
        XCTAssertEqual(originalComplex.name, originalComplexName)
        XCTAssertEqual(originalComplex.components.first?.prescribedSetCount, originalSetCount)
        XCTAssertFalse(first.isActiveVersion)

        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.lineageId, first.lineageId)
        XCTAssertTrue(second.isActiveVersion)
        let newComplex = second.complexes.first { $0.definitionId == originalDefinitionId }
        XCTAssertEqual(newComplex?.version, originalComplex.version + 1)
        XCTAssertEqual(newComplex?.name, "Edited Chest Complex")
        XCTAssertEqual(newComplex?.components.first?.prescribedSetCount, 3)
        XCTAssertNotEqual(newComplex?.id, originalComplex.id)
    }

    private func makeRankedExercises() -> [Exercise] {
        MuscleGroup.initialAdaptiveRankOrder.map(makeExercise(for:))
    }

    private func makeExercise(for muscle: MuscleGroup) -> Exercise {
        Exercise(
            name: "Test \(muscle.displayName)",
            primaryMuscle: muscle,
            type: muscle == .quads || muscle == .hamstrings ? .compound : .isolation,
            equipment: .cable
        )
    }

    func testLegacySetFloorsNormalizeToBinaryExposureRequirements() throws {
        let exercises = makeRankedExercises()
        let (context, _) = makeContext()
        let program = try AdaptiveProgramService.saveVersion(
            draft: AdaptiveProgramService.demoDraft(exercises: exercises),
            replacing: nil,
            allPrograms: [],
            exercises: exercises,
            modelContext: context
        )
        let chest = try XCTUnwrap(program.muscleRules.first { $0.muscle == .chest })
        chest.rollingSetFloor = 4
        try context.save()

        XCTAssertEqual(
            try AdaptiveProgramService.normalizeBinaryExposureRequirements(modelContext: context),
            1
        )
        XCTAssertEqual(chest.rollingSetFloor, 1)
        XCTAssertEqual(
            try AdaptiveProgramService.normalizeBinaryExposureRequirements(modelContext: context),
            0
        )
    }

    func testLegacyDemoLabelsNormalizeWithoutChangingCustomNames() throws {
        let exercises = makeRankedExercises()
        let (context, _) = makeContext()
        let program = try AdaptiveProgramService.saveVersion(
            draft: AdaptiveProgramService.demoDraft(exercises: exercises),
            replacing: nil,
            allPrograms: [],
            exercises: exercises,
            modelContext: context
        )
        program.name = "Adaptive Demo — Review Required"
        let chest = try XCTUnwrap(program.complexes.first { $0.primaryMuscle == .chest })
        let back = try XCTUnwrap(program.complexes.first { $0.primaryMuscle == .back })
        chest.name = "Chest Demo"
        back.name = "My Back Rotation"

        let snapshot = PlannedComplexSnapshot(
            sourceDefinitionId: chest.definitionId,
            sourceVersion: chest.version,
            position: 0,
            name: "Chest Demo",
            primaryMuscle: .chest,
            reasonCodes: [],
            exercises: []
        )
        context.insert(
            GeneratedWorkoutPlan(
                localDateKey: "2026-07-21",
                timeZoneIdentifier: "America/Los_Angeles",
                status: .proposed,
                adaptiveProgramId: program.id,
                adaptiveProgramVersion: program.version,
                readinessCheckId: UUID(),
                plannerVersion: 3,
                reasonCodes: [],
                complexes: [snapshot]
            )
        )
        try context.save()

        XCTAssertEqual(try AdaptiveProgramService.normalizeLegacyDemoLabels(modelContext: context), 3)
        XCTAssertEqual(program.name, "Adaptive Program")
        XCTAssertEqual(chest.name, "Chest")
        XCTAssertEqual(back.name, "My Back Rotation")
        XCTAssertEqual(snapshot.name, "Chest")
        XCTAssertEqual(try AdaptiveProgramService.normalizeLegacyDemoLabels(modelContext: context), 0)
    }

    func testRequestedExerciseSelectionDefaultsPinLowerFoundationsAndRotateAvailableUpperWork() throws {
        let (context, _) = makeContext()
        let beltSquat = Exercise(
            name: "Belt Squat",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine
        )
        let stiffLegDeadlift = Exercise(
            name: "Stiff-Leg Deadlift",
            primaryMuscle: .hamstrings,
            type: .compound,
            equipment: .barbell
        )
        let reverseHyper = Exercise(
            name: "Reverse Hyper",
            primaryMuscle: .hamstrings,
            type: .isolation,
            equipment: .machine
        )
        let gluteHamRaise = Exercise(
            name: "Glute-Ham Raise",
            primaryMuscle: .hamstrings,
            type: .compound,
            equipment: .bodyweight
        )
        let inclinePress = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let machinePress = Exercise(
            name: "Machine Chest Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .machine
        )
        let assistedDips = Exercise(
            name: "Assisted Dips",
            primaryMuscle: .triceps,
            type: .compound,
            equipment: .machine
        )
        let pushdown = Exercise(
            name: "Cable Pushdown",
            primaryMuscle: .triceps,
            type: .isolation,
            equipment: .cable
        )
        (
            [beltSquat, stiffLegDeadlift, reverseHyper, gluteHamRaise, inclinePress, machinePress]
                + [assistedDips, pushdown]
        ).forEach(context.insert)
        try context.save()

        XCTAssertEqual(
            try AdaptiveExerciseSelectionPreferenceService.ensureRequestedDefaults(modelContext: context),
            MuscleGroup.allCases.count
        )
        let preferences = try context.fetch(FetchDescriptor<AdaptiveExerciseSelectionPreference>())
        let chest = try XCTUnwrap(preferences.first { $0.muscle == .chest })
        XCTAssertEqual(chest.mode, .rotateRecent)
        XCTAssertTrue(chest.eligibleExerciseIds.contains(inclinePress.id))
        XCTAssertTrue(chest.eligibleExerciseIds.contains(machinePress.id))

        let quads = try XCTUnwrap(preferences.first { $0.muscle == .quads })
        XCTAssertEqual(quads.mode, .pinned)
        XCTAssertEqual(quads.pinnedExerciseId, beltSquat.id)
        let hamstrings = try XCTUnwrap(preferences.first { $0.muscle == .hamstrings })
        XCTAssertEqual(hamstrings.mode, .pinned)
        XCTAssertEqual(hamstrings.pinnedExerciseId, stiffLegDeadlift.id)
        XCTAssertTrue(hamstrings.eligibleExerciseIds.contains(stiffLegDeadlift.id))
        XCTAssertTrue(hamstrings.eligibleExerciseIds.contains(reverseHyper.id))
        XCTAssertFalse(hamstrings.eligibleExerciseIds.contains(gluteHamRaise.id))
        XCTAssertEqual(preferences.first { $0.muscle == .back }?.mode, .rotateRecent)
        let triceps = try XCTUnwrap(preferences.first { $0.muscle == .triceps })
        XCTAssertFalse(triceps.eligibleExerciseIds.contains(assistedDips.id))
        XCTAssertTrue(triceps.eligibleExerciseIds.contains(pushdown.id))
        XCTAssertEqual(preferences.first { $0.muscle == .glutes }?.mode, .repeatLast)
        XCTAssertEqual(
            try AdaptiveExerciseSelectionPreferenceService.ensureRequestedDefaults(modelContext: context),
            0
        )
    }

    func testOpenPlanCategoriesNormalizeWithoutRewritingCompletedHistory() throws {
        let (context, _) = makeContext()
        let press = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        context.insert(press)

        func plan(status: AdaptivePlanStatus) -> GeneratedWorkoutPlan {
            GeneratedWorkoutPlan(
                localDateKey: UUID().uuidString,
                timeZoneIdentifier: "America/Los_Angeles",
                status: status,
                adaptiveProgramId: UUID(),
                adaptiveProgramVersion: 1,
                readinessCheckId: UUID(),
                plannerVersion: 3,
                reasonCodes: [],
                complexes: [
                    PlannedComplexSnapshot(
                        sourceDefinitionId: UUID(),
                        sourceVersion: 1,
                        position: 0,
                        name: "Chest",
                        primaryMuscle: .chest,
                        reasonCodes: [],
                        exercises: [
                            PlannedExerciseSnapshot(
                                position: 0,
                                exerciseId: press.id,
                                exerciseName: press.name,
                                primaryMuscle: .chest,
                                difficulty: .easy,
                                prescribedSetCount: 1
                            )
                        ]
                    )
                ]
            )
        }

        let proposed = plan(status: .proposed)
        let completed = plan(status: .completed)
        context.insert(proposed)
        context.insert(completed)
        try context.save()

        XCTAssertEqual(
            try AdaptiveProgramService.normalizeOpenPlanExerciseCategories(modelContext: context),
            1
        )
        XCTAssertEqual(proposed.complexes.first?.exercises.first?.difficulty, .hard)
        XCTAssertEqual(completed.complexes.first?.exercises.first?.difficulty, .easy)
    }

    private func makeContext() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV6.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }
}
