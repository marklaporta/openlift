import XCTest
@testable import OpenLift

final class CycleOrderingTests: XCTestCase {
    func testSortedSlotsPreservesOriginalOrderWhenPositionsAreEqual() {
        let slots = [
            CycleSlot(position: 0, muscle: .back, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .chest, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .hamstrings, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .quads, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .triceps, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .biceps, exerciseId: UUID(), defaultSetCount: 2),
            CycleSlot(position: 0, muscle: .sideDelts, exerciseId: UUID(), defaultSetCount: 2)
        ]

        let sorted = CycleOrdering.sortedSlots(slots)
        XCTAssertEqual(
            sorted.map(\.muscle),
            slots.map(\.muscle)
        )
    }

    func testSortedDaysUsesExplicitPositionOrdering() {
        let day2 = CycleDay(label: "Lower A", slots: [], position: 1)
        let day1 = CycleDay(label: "Upper A", slots: [], position: 0)
        let day4 = CycleDay(label: "Lower B", slots: [], position: 3)
        let day3 = CycleDay(label: "Upper B", slots: [], position: 2)

        let sorted = CycleOrdering.sortedDays([day2, day4, day3, day1])
        XCTAssertEqual(sorted.map(\.label), ["Upper A", "Lower A", "Upper B", "Lower B"])
    }

    func testSortedDaysInfersUpperLowerOrderForLegacyTemplates() {
        let days = [
            CycleDay(label: "Lower A", slots: []),
            CycleDay(label: "Upper B", slots: []),
            CycleDay(label: "Upper A", slots: []),
            CycleDay(label: "Lower B", slots: [])
        ]

        let sorted = CycleOrdering.sortedDays(days)
        XCTAssertEqual(sorted.map(\.label), ["Upper A", "Lower A", "Upper B", "Lower B"])
    }
}
