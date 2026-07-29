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

// History presents one chronological list rather than grouping by workout type. These
// live here rather than in their own file because the Xcode project lists test sources
// explicitly, so a new file would not be compiled.
final class HistoryTimelineServiceTests: XCTestCase {
    private func rotation(_ finished: TimeInterval, id: UUID = UUID()) -> Session {
        Session(
            id: id,
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: finished - 3600),
            finishedAt: Date(timeIntervalSince1970: finished),
            status: .completed,
            exportStatus: .success
        )
    }

    private func adaptive(_ finished: TimeInterval, id: UUID = UUID()) -> AdaptiveWorkoutSession {
        AdaptiveWorkoutSession(
            id: id,
            generatedPlanId: UUID(),
            createdAt: Date(timeIntervalSince1970: finished - 3600),
            finishedAt: Date(timeIntervalSince1970: finished),
            status: .completed,
            exportStatus: .success
        )
    }

    // The regression this replaces: grouping by type meant a Fixed Cycle session
    // finished today sorted below an Adaptive session from days earlier.
    func testHistoryEntriesInterleaveBothWorkoutKindsNewestFirst() {
        let entries = HistoryTimelineService.entries(
            sessions: [rotation(500), rotation(100)],
            adaptiveSessions: [adaptive(400), adaptive(300)]
        )

        XCTAssertEqual(entries.map { $0.date.timeIntervalSince1970 }, [500, 400, 300, 100])
        guard case .rotation = entries[0], case .adaptive = entries[1] else {
            return XCTFail("newest rotation session should precede an older adaptive one")
        }
    }

    func testNewestRotationSessionOutranksEveryOlderAdaptiveSession() {
        let entries = HistoryTimelineService.entries(
            sessions: [rotation(900)],
            adaptiveSessions: [adaptive(800), adaptive(700), adaptive(600)]
        )

        guard case .rotation = entries.first else {
            return XCTFail("expected the newest session overall to be the rotation one")
        }
        XCTAssertEqual(entries.count, 4)
    }

    func testHistoryFallsBackToCreatedAtWhenFinishedAtIsMissing() {
        let unfinished = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 450),
            status: .completed
        )
        let entries = HistoryTimelineService.entries(
            sessions: [unfinished],
            adaptiveSessions: [adaptive(400)]
        )

        XCTAssertEqual(entries.map { $0.date.timeIntervalSince1970 }, [450, 400])
    }

    // Same timestamp must not shuffle between redraws.
    func testHistoryEqualTimestampsOrderDeterministically() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let first = HistoryTimelineService.entries(
            sessions: [rotation(200, id: b)],
            adaptiveSessions: [adaptive(200, id: a)]
        )
        let second = HistoryTimelineService.entries(
            sessions: [rotation(200, id: b)],
            adaptiveSessions: [adaptive(200, id: a)]
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.first?.id, "adaptive-\(a.uuidString)")
    }

    func testHistoryHandlesEmptyInputAndSingleKind() {
        XCTAssertTrue(HistoryTimelineService.entries(sessions: [], adaptiveSessions: []).isEmpty)
        XCTAssertEqual(
            HistoryTimelineService.entries(sessions: [rotation(1)], adaptiveSessions: []).count, 1
        )
        XCTAssertEqual(
            HistoryTimelineService.entries(sessions: [], adaptiveSessions: [adaptive(1)]).count, 1
        )
    }
}
