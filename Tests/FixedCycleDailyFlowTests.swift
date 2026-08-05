import Foundation
import XCTest
@testable import OpenLift

final class FixedCycleDailyFlowTests: XCTestCase {
    func testCompletedFixedWorkoutBlocksDraftForRestOfLocalCalendarDay() throws {
        let finishedAt = date(year: 2026, month: 8, day: 4, hour: 17, minute: 51)
        let laterThatDay = date(year: 2026, month: 8, day: 4, hour: 23, minute: 59)
        let completed = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "Push Pull",
            dayLabelSnapshot: "Pull A",
            finishedAt: finishedAt,
            status: .completed
        )
        let legacyNextDraft = Session(
            cycleInstanceId: completed.cycleInstanceId,
            cycleDayIndex: 1,
            createdAt: finishedAt.addingTimeInterval(1),
            status: .draft
        )

        XCTAssertEqual(
            FixedCycleWorkoutService.completedFixedSession(
                on: laterThatDay,
                sessions: [legacyNextDraft, completed],
                calendar: calendar
            )?.id,
            completed.id
        )
        XCTAssertFalse(
            FixedCycleWorkoutService.shouldCreateDraft(
                on: laterThatDay,
                sessions: [legacyNextDraft, completed],
                calendar: calendar
            )
        )
    }

    func testNextLocalCalendarDayAllowsScheduledDraft() {
        let finishedAt = date(year: 2026, month: 8, day: 4, hour: 23, minute: 59)
        let nextDay = date(year: 2026, month: 8, day: 5, hour: 0, minute: 1)
        let completed = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "Push Pull",
            dayLabelSnapshot: "Pull A",
            finishedAt: finishedAt,
            status: .completed
        )

        XCTAssertNil(
            FixedCycleWorkoutService.completedFixedSession(
                on: nextDay,
                sessions: [completed],
                calendar: calendar
            )
        )
        XCTAssertTrue(
            FixedCycleWorkoutService.shouldCreateDraft(
                on: nextDay,
                sessions: [completed],
                calendar: calendar
            )
        )
    }

    func testAdHocCompletionDoesNotBlockFixedCycleDraft() {
        let finishedAt = date(year: 2026, month: 8, day: 4, hour: 12, minute: 0)
        let adHoc = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "Off-Schedule",
            dayLabelSnapshot: "Off-Schedule",
            finishedAt: finishedAt,
            status: .completed
        )

        XCTAssertTrue(
            FixedCycleWorkoutService.shouldCreateDraft(
                on: finishedAt,
                sessions: [adHoc],
                calendar: calendar
            )
        )
    }

    func testCompletedExerciseRecapIsOrderedAndExcludesUnfinishedRows() {
        let sessionId = UUID()
        let press = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let flye = Exercise(
            name: "Incline Cable Flye",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let entries = [
            SetEntry(sessionId: sessionId, exerciseId: press.id, setIndex: 2, weight: 60, reps: 8, isLocked: true),
            SetEntry(sessionId: sessionId, exerciseId: flye.id, setIndex: 1, weight: 20, reps: 10, isLocked: true),
            SetEntry(sessionId: sessionId, exerciseId: press.id, setIndex: 1, weight: 60, reps: 10, isLocked: true),
            SetEntry(sessionId: sessionId, exerciseId: flye.id, setIndex: 2, weight: 20, reps: 0, isLocked: true),
            SetEntry(sessionId: sessionId, exerciseId: press.id, setIndex: 3, weight: 60, reps: 6, isLocked: false)
        ]
        let snapshots = [
            FixedCycleExerciseSnapshot(
                sessionId: sessionId,
                position: 1,
                exerciseId: flye.id,
                exerciseName: flye.name,
                muscle: .chest,
                statusRawValue: "performed"
            ),
            FixedCycleExerciseSnapshot(
                sessionId: sessionId,
                position: 0,
                exerciseId: press.id,
                exerciseName: press.name,
                muscle: .chest,
                statusRawValue: "performed"
            )
        ]

        let recap = FixedCycleWorkoutService.completedExerciseRecaps(
            sessionId: sessionId,
            entries: entries,
            exercises: [flye, press],
            snapshots: snapshots
        )

        XCTAssertEqual(recap.map(\.exerciseName), [press.name, flye.name])
        XCTAssertEqual(recap[0].sets.map(\.setIndex), [1, 2])
        XCTAssertEqual(recap[0].sets.map(\.reps), [10, 8])
        XCTAssertEqual(recap[1].sets.map(\.reps), [10])
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
