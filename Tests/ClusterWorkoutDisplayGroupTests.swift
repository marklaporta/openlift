import XCTest
@testable import OpenLift

final class ClusterWorkoutDisplayGroupTests: XCTestCase {
    private typealias Program = FixedCycleClusterProgramService

    private func selections(step: Int = 0) -> [Program.Selection] {
        let definition = BundledClusterPrograms.v8
        return Program.Cluster.allCases.map { cluster in
            let day = definition.step(clusterID: cluster.rawValue, counter: step)!
            return Program.Selection(cluster: cluster, cycleInstanceId: UUID(), templateId: UUID(),
                absoluteStep: step, effectiveStep: step % definition.cluster(cluster.rawValue)!.steps.count,
                day: CycleDay(label: day.label, slots: day.slots.enumerated().map {
                    CycleSlot(position: $0.offset, muscle: $0.element.muscle, exerciseId: UUID(), defaultSetCount: $0.element.defaultSetCount)
                }, position: day.templatePosition), programVersionID: definition.programVersionID, definition: definition)
        }
    }

    func testEveryPairingSeparatesArmsAfterLegsWithoutLosingSlotsOrIdentity() {
        for step in 0..<24 {
            let selections = selections(step: step)
            let sessionId = UUID()
            let groups = ClusterWorkoutDisplayGroup.make(selections: selections, sessionId: sessionId, occurrences: [])
            XCTAssertEqual(groups.map(\.id), ["cluster-1.torso", "cluster-2", "cluster-1.arms", "cluster-3"])
            XCTAssertEqual(groups.compactMap(\.completionTitle), ["Complete Cluster 2", "Complete Torso + Arms", "Complete Cluster 3"])
            XCTAssertEqual(groups[0].anchor, "cluster.cluster-1", "Finish review still targets torso")
            XCTAssertEqual(groups[0].selection.absoluteStep, groups[2].selection.absoluteStep)
            for selection in selections {
                let canonical = Program.resolvedSlots(selection: selection, sessionId: sessionId, preferences: [], overrides: [])
                let displayed = groups.filter { $0.selection.id == selection.id }.flatMap { group in
                    canonical.filter { group.includes($0.slot.muscle) }
                }
                XCTAssertEqual(displayed.map(\.id), canonical.map(\.id))
                XCTAssertEqual(displayed.map(\.progressionKey), canonical.map(\.progressionKey))
                XCTAssertEqual(displayed.map(\.slot.id), canonical.map(\.slot.id))
            }
        }
    }

    func testSubstitutionsKeepStructuralArmPlacementAndAllRows() {
        let selections = selections()
        let upper = selections[0]
        let sessionId = UUID(), preferredID = UUID(), overrideID = UUID()
        let preferences = [ClusterExercisePreference(programVersionID: upper.programVersionID,
            templateDayPosition: upper.day.position, slotPosition: 2, exerciseId: preferredID)]
        let overrides = [ClusterExerciseOccurrenceOverride(sessionId: sessionId,
            programVersionID: upper.programVersionID, templateDayPosition: upper.day.position,
            slotPosition: 2, exerciseId: overrideID)]
        let resolved = Program.resolvedSlots(selection: upper, sessionId: sessionId, preferences: preferences, overrides: overrides)
        let groups = ClusterWorkoutDisplayGroup.make(selections: selections, sessionId: sessionId, occurrences: [])
        XCTAssertEqual(resolved.filter { groups[2].includes($0.slot.muscle) }.map(\.exerciseId), [overrideID, upper.day.slots[3].exerciseId])
        XCTAssertEqual(resolved.filter { groups[0].includes($0.slot.muscle) }.count, 2)
        XCTAssertEqual(upper.day.slots.count, 4)
    }

    func testHistoricalUnsplitProgramsAndCompletedSnapshotOwnGrouping() throws {
        let selections = selections()
        let upper = selections[0]
        let sessionId = UUID()
        func occurrence(muscles: [MuscleGroup]) throws -> ClusterOccurrenceRecord {
            try ClusterOccurrenceRecord(sessionId: sessionId, cycleInstanceId: upper.cycleInstanceId,
                templateId: upper.templateId, programVersionID: upper.programVersionID, clusterID: upper.cluster.rawValue,
                absoluteStep: 0, templateDayPosition: 0, dayLabel: "Frozen", exerciseSnapshots: muscles.enumerated().map {
                    ClusterExerciseProgressionSnapshot(position: $0.offset, exerciseId: UUID(), exerciseName: "Frozen",
                        muscle: $0.element, prescribedSetCount: 2, progressionKey: "frozen.\($0.offset)",
                        resistanceProfile: nil, completionStatus: .performed)
                })
        }
        let unsplit = try occurrence(muscles: [.chest, .back])
        XCTAssertEqual(ClusterWorkoutDisplayGroup.make(selections: selections, sessionId: sessionId, occurrences: [unsplit]).map(\.id), ["cluster-1", "cluster-2", "cluster-3"])
        upper.day.slots = upper.day.slots.filter { $0.muscle == .chest || $0.muscle == .back }
        XCTAssertEqual(ClusterWorkoutDisplayGroup.make(selections: selections, sessionId: sessionId, occurrences: []).map(\.id), ["cluster-1", "cluster-2", "cluster-3"])
        let split = try occurrence(muscles: [.chest, .back, .triceps, .biceps])
        XCTAssertEqual(ClusterWorkoutDisplayGroup.make(selections: selections, sessionId: sessionId, occurrences: [split]).map(\.id), ["cluster-1.torso", "cluster-2", "cluster-1.arms", "cluster-3"])
    }
}
