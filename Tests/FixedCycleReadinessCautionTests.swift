import Foundation
import XCTest
@testable import OpenLift

final class FixedCycleReadinessCautionTests: XCTestCase {
    func testCleanResponsesDoNotProduceCaution() {
        let day = makeDay([.chest, .triceps])
        let readiness = makeReadiness([
            response(.chest),
            response(.triceps)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            []
        )
    }

    func testConnectiveTissuePainAloneProducesCaution() {
        let day = makeDay([.chest])
        let readiness = makeReadiness([
            response(.chest, connectiveTissuePain: .caution)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            [.chest]
        )
    }

    func testBlockingSorenessAloneProducesCaution() {
        let day = makeDay([.back])
        let readiness = makeReadiness([
            response(.back, soreness: .moderate)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            [.back]
        )
    }

    func testPainAndBlockingSorenessProduceOneCaution() {
        let day = makeDay([.quads, .quads])
        let readiness = makeReadiness([
            response(.quads, soreness: .high, connectiveTissuePain: .stop)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            [.quads]
        )
    }

    func testScheduledMuscleWithoutReadinessResponseIsExcluded() {
        let day = makeDay([.chest, .triceps])
        let readiness = makeReadiness([
            response(.chest, connectiveTissuePain: .caution)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            [.chest]
        )
    }

    func testCautionResponseForUnscheduledMuscleIsExcluded() {
        let day = makeDay([.chest])
        let readiness = makeReadiness([
            response(.chest),
            response(.back, soreness: .high, connectiveTissuePain: .stop)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            []
        )
    }

    func testCautionOrderFollowsStableDaySlotOrder() {
        let day = CycleDay(
            label: "Mixed",
            slots: [
                CycleSlot(position: 2, muscle: .triceps, exerciseId: UUID()),
                CycleSlot(position: 0, muscle: .back, exerciseId: UUID()),
                CycleSlot(position: 3, muscle: .back, exerciseId: UUID()),
                CycleSlot(position: 1, muscle: .chest, exerciseId: UUID())
            ]
        )
        let readiness = makeReadiness([
            response(.triceps, connectiveTissuePain: .caution),
            response(.chest, soreness: .moderate),
            response(.back, connectiveTissuePain: .stop)
        ])

        XCTAssertEqual(
            FixedCycleWorkoutService.cautionMuscles(for: day, readiness: readiness),
            [.back, .chest, .triceps]
        )
    }

    private func makeDay(_ muscles: [MuscleGroup]) -> CycleDay {
        CycleDay(
            label: "Test Day",
            slots: muscles.enumerated().map { position, muscle in
                CycleSlot(position: position, muscle: muscle, exerciseId: UUID())
            }
        )
    }

    private func makeReadiness(
        _ responses: [FixedCycleReadinessResponse]
    ) -> FixedCycleReadinessObservation {
        FixedCycleReadinessObservation(
            sessionId: UUID(),
            localDateKey: "2026-07-29",
            timeZoneIdentifier: "America/Los_Angeles",
            revision: 1,
            responses: responses
        )
    }

    private func response(
        _ muscle: MuscleGroup,
        soreness: SorenessLevel = .none,
        connectiveTissuePain: ConnectiveTissuePainLevel = .none
    ) -> FixedCycleReadinessResponse {
        FixedCycleReadinessResponse(
            muscle: muscle,
            soreness: soreness,
            connectiveTissuePain: connectiveTissuePain
        )
    }
}
