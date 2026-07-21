import SwiftData
import XCTest
@testable import OpenLift

final class AdaptiveProgramServiceTests: XCTestCase {
    func testBlankDraftUsesRequestedPriorityAndLeavesAbsAndTrapsDisabled() {
        let draft = AdaptiveProgramDraft.blank
        let enabled = draft.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }

        XCTAssertEqual(enabled.map(\.muscle), MuscleGroup.initialAdaptiveRankOrder)
        XCTAssertEqual(enabled.map(\.priorityRank), Array(1...10))
        XCTAssertEqual(enabled[4].muscle, .sideDelts)
        XCTAssertEqual(draft.globalMaxMovements, 4)
        XCTAssertEqual(draft.maxDifficultyCost, 60)

        for muscle in [MuscleGroup.abs, .traps] {
            let rule = draft.muscleRules.first { $0.muscle == muscle }
            XCTAssertEqual(rule?.priorityRank, 0)
            XCTAssertEqual(rule?.rollingSetFloor, 0)
            XCTAssertEqual(rule?.isEnabled, false)
        }
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
        XCTAssertEqual(saved.complexes.count, 10)
        XCTAssertEqual(AdaptiveProgramService.activeProgram(from: [saved])?.id, saved.id)
    }

    func testValidationRejectsInfeasibleFloorAndAtomicComplexCaps() {
        let exercises = makeRankedExercises()
        var floorDraft = AdaptiveProgramService.demoDraft(exercises: exercises)
        let chestIndex = floorDraft.muscleRules.firstIndex { $0.muscle == .chest }!
        floorDraft.muscleRules[chestIndex].rollingSetFloor = 7
        floorDraft.muscleRules[chestIndex].rollingWindowDays = 1
        floorDraft.muscleRules[chestIndex].maxExercisesPerExposure = 2
        floorDraft.muscleRules[chestIndex].maxSetsPerExercise = 3

        XCTAssertThrowsError(try AdaptiveProgramService.validate(floorDraft, exercises: exercises)) { error in
            XCTAssertEqual(
                error as? AdaptiveProgramValidationError,
                .infeasibleFloor(muscle: .chest, floor: 7, maximum: 6)
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
                .complexExceedsMovementCap(name: "Chest Demo", count: 2, cap: 1)
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

    private func makeContext() -> (ModelContext, ModelContainer) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV3.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        return (ModelContext(container), container)
    }
}
