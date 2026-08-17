import Foundation
import SwiftData
import XCTest
@testable import OpenLift

final class August16PullACompletionRepairTests: XCTestCase {
    func testRepairBackdatesOnlyTargetSessionAndMakesPushAAvailableToday() throws {
        let (_, context, cycle, session) = try makeFixture()
        let entriesBefore = try context.fetch(FetchDescriptor<SetEntry>())
            .filter { $0.sessionId == session.id }
            .map(ManifestItem.init)
        let monday = Date(timeIntervalSince1970: 1_786_985_000)

        XCTAssertFalse(
            FixedCycleWorkoutService.shouldCreateDraft(
                on: monday,
                sessions: [session],
                calendar: pacificCalendar
            )
        )

        let first = try BootstrapDataService.repairAugust16PullACompletionDate(
            modelContext: context
        )

        XCTAssertTrue(first.didApply)
        XCTAssertEqual(first.sessionId, session.id)
        XCTAssertEqual(session.finishedAt, BootstrapDataService.august16PullARepairedCompletion)
        XCTAssertEqual(session.exportStatus, .pending)
        XCTAssertEqual(cycle.currentDayIndex, 1)
        XCTAssertTrue(
            FixedCycleWorkoutService.shouldCreateDraft(
                on: monday,
                sessions: [session],
                calendar: pacificCalendar
            )
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<SetEntry>())
                .filter { $0.sessionId == session.id }
                .map(ManifestItem.init),
            entriesBefore
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<TrainingPreference>()).contains {
                $0.key == BootstrapDataService.august16PullACompletionRepairMarkerKey
                    && $0.modeRawValue == session.id.uuidString
            }
        )

        session.exportStatus = .success
        try context.save()
        let second = try BootstrapDataService.repairAugust16PullACompletionDate(
            modelContext: context
        )
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(session.exportStatus, .success)
        XCTAssertEqual(cycle.currentDayIndex, 1)
    }

    func testRepairFailsClosedAndRollsBackOnSetDrift() throws {
        let (_, context, cycle, session) = try makeFixture()
        let entries = try context.fetch(FetchDescriptor<SetEntry>())
        let target = try XCTUnwrap(entries.first { $0.sessionId == session.id })
        target.reps += 1
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.repairAugust16PullACompletionDate(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.August16PullACompletionRepairError,
                .unexpectedExistingSets
            )
        }
        XCTAssertEqual(session.finishedAt, BootstrapDataService.august16PullAOriginalCompletion)
        XCTAssertEqual(session.exportStatus, .success)
        XCTAssertEqual(cycle.currentDayIndex, 1)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<TrainingPreference>()).contains {
                $0.key == BootstrapDataService.august16PullACompletionRepairMarkerKey
            }
        )
    }

    func testRepairIdentifiesStoresWithoutTargetSession() throws {
        let schema = Schema(versionedSchema: OpenLiftSchemaV12.self)
        let context = ModelContext(OpenLiftModelContainerFactory.makeInMemory(schema: schema))

        XCTAssertThrowsError(
            try BootstrapDataService.repairAugust16PullACompletionDate(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.August16PullACompletionRepairError,
                .targetSessionNotFound
            )
        }
    }

    private func makeFixture() throws -> (
        ModelContainer,
        ModelContext,
        ActiveCycleInstance,
        Session
    ) {
        let schema = Schema(versionedSchema: OpenLiftSchemaV12.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        let context = ModelContext(container)
        let template = CycleTemplate(
            id: BootstrapDataService.august16PullATemplateId,
            name: BootstrapDataService.pushPullABTemplateName,
            days: [
                CycleDay(label: "Pull A", slots: [], position: 0),
                CycleDay(label: "Push A", slots: [], position: 1),
                CycleDay(label: "Pull B", slots: [], position: 2),
                CycleDay(label: "Push B", slots: [], position: 3),
            ]
        )
        context.insert(template)
        let cycle = ActiveCycleInstance(
            id: BootstrapDataService.august16PullACycleId,
            templateId: template.id,
            currentDayIndex: 1
        )
        context.insert(cycle)
        context.insert(TrainingPreference(modeRawValue: TrainingMode.rotation.rawValue))
        context.insert(
            TrainingPreference(
                key: BootstrapDataService.pushPullRolloutMarkerKey,
                modeRawValue: template.id.uuidString
            )
        )
        let session = Session(
            id: BootstrapDataService.august16PullASessionId,
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Pull A",
            createdAt: Date(timeIntervalSince1970: 1_786_902_713),
            finishedAt: BootstrapDataService.august16PullAOriginalCompletion,
            status: .completed,
            exportStatus: .success
        )
        context.insert(session)
        for item in manifest {
            context.insert(
                SetEntry(
                    sessionId: session.id,
                    exerciseId: item.exerciseId,
                    setIndex: item.setIndex,
                    weight: item.weight,
                    reps: item.reps,
                    isLocked: true
                )
            )
        }
        try context.save()
        return (container, context, cycle, session)
    }

    private struct ManifestItem: Equatable {
        let exerciseId: UUID
        let setIndex: Int
        let weight: Double
        let reps: Int
        let isLocked: Bool

        init(_ entry: SetEntry) {
            exerciseId = entry.exerciseId
            setIndex = entry.setIndex
            weight = entry.weight
            reps = entry.reps
            isLocked = entry.isLocked
        }
    }

    private var manifest: [(exerciseId: UUID, setIndex: Int, weight: Double, reps: Int)] {
        [
            (UUID(uuidString: "54214942-679D-4CBB-9B27-F78601897BA2")!, 1, 95, 14),
            (UUID(uuidString: "54214942-679D-4CBB-9B27-F78601897BA2")!, 2, 95, 11),
            (UUID(uuidString: "921ADA85-9DED-412E-B74B-DF4CB6661284")!, 1, 35, 16),
            (UUID(uuidString: "921ADA85-9DED-412E-B74B-DF4CB6661284")!, 2, 35, 13),
            (UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, 1, 28, 16),
            (UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, 2, 28, 11),
            (UUID(uuidString: "E27608C0-2EFD-436C-A01E-BAF327F44055")!, 3, 28, 10),
            (UUID(uuidString: "55B44E05-2ADC-4680-AB4B-FA10592ECF49")!, 1, 135, 12),
            (UUID(uuidString: "55B44E05-2ADC-4680-AB4B-FA10592ECF49")!, 2, 135, 12),
            (UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, 1, 30, 6),
            (UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, 2, 25, 7),
            (UUID(uuidString: "2A193B06-CABA-44D1-8E19-29675FC6D7E5")!, 3, 20, 8),
        ]
    }

    private var pacificCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
}
