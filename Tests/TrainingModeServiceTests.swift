import SwiftData
import XCTest
@testable import OpenLift

final class TrainingModeServiceTests: XCTestCase {
    func testMissingOrInvalidPreferenceDefaultsToFixedCycle() {
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: []), .rotation)

        let invalid = TrainingPreference(modeRawValue: "unknown-mode")
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: [invalid]), .rotation)
    }

    func testModeRoundTripDoesNotMutateFixedCycleState() throws {
        let schema = Schema(versionedSchema: OpenLiftSchemaV3.self)
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        let context = ModelContext(container)

        let templateId = UUID()
        let cycle = ActiveCycleInstance(templateId: templateId, currentDayIndex: 3)
        let draft = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 3,
            cycleNameSnapshot: "Preserved Cycle",
            dayLabelSnapshot: "Day Four"
        )
        context.insert(cycle)
        context.insert(draft)
        try context.save()

        let cycleId = cycle.id
        let draftId = draft.id
        let originalRotationValue = cycle.rotationIndices.first?.value

        var preferences = try context.fetch(FetchDescriptor<TrainingPreference>())
        try TrainingModeService.setMode(.adaptive, preferences: preferences, modelContext: context)
        preferences = try context.fetch(FetchDescriptor<TrainingPreference>())
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: preferences), .adaptive)

        try TrainingModeService.setMode(.rotation, preferences: preferences, modelContext: context)
        preferences = try context.fetch(FetchDescriptor<TrainingPreference>())
        XCTAssertEqual(TrainingModeService.resolvedMode(preferences: preferences), .rotation)

        let savedCycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>())
        let savedSessions = try context.fetch(FetchDescriptor<Session>())
        XCTAssertEqual(savedCycles.map(\.id), [cycleId])
        XCTAssertEqual(savedCycles.first?.templateId, templateId)
        XCTAssertEqual(savedCycles.first?.currentDayIndex, 3)
        XCTAssertEqual(savedCycles.first?.rotationIndices.first?.value, originalRotationValue)
        XCTAssertEqual(savedSessions.map(\.id), [draftId])
        XCTAssertEqual(savedSessions.first?.status, .draft)
        XCTAssertEqual(savedSessions.first?.cycleDayIndex, 3)
    }
}
