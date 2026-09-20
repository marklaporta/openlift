import XCTest
import SwiftData
@testable import OpenLift

@MainActor
final class WorkoutTextBufferTests: XCTestCase {
    private let first = UUID(), second = UUID()
    private func rows(weight: Double = 45, reps: Int = 0) -> [(id: UUID, state: WorkoutEntryEditing.EntryState)] {
        [(first, .init(setIndex: 1, weight: weight, reps: reps, isLocked: false)),
         (second, .init(setIndex: 2, weight: weight, reps: 0, isLocked: false))]
    }
    func testUntouchedWeightIsAcceptedWhileRepsAreEntered() throws {
        let buffer = WorkoutTextBuffer()
        buffer.set("12", for: .init(entryID: first, kind: .reps))
        let actual = try buffer.applying(to: rows())
        XCTAssertEqual(actual[0].weight, 45)
        XCTAssertEqual(actual[0].reps, 12)
        XCTAssertEqual(actual[1].reps, 0)
    }
    func testReplacementAndPropagationDoNotAppendOrOverwriteDistinctLaterLoad() throws {
        let buffer = WorkoutTextBuffer()
        buffer.set("47.5", for: .init(entryID: first, kind: .weight))
        var input = rows()
        XCTAssertEqual(try buffer.applying(to: input).map(\.weight), [47.5, 47.5])
        input[1].state.weight = 50
        XCTAssertEqual(try buffer.applying(to: input).map(\.weight), [47.5, 50])
    }
    func testInvalidAndPartialTextAreRetainedUntilCorrectionOrSuccessfulSave() throws {
        let buffer = WorkoutTextBuffer()
        let key = WorkoutTextBuffer.Key(entryID: first, kind: .weight)
        buffer.set(".", for: key)
        XCTAssertThrowsError(try buffer.applying(to: rows()))
        XCTAssertEqual(buffer.text(for: key), ".")
        buffer.set("47.", for: key)
        XCTAssertEqual(try buffer.applying(to: rows())[0].weight, 47)
        XCTAssertEqual(buffer.text(for: key), "47.")
        buffer.set("47.5", for: key)
        XCTAssertEqual(try buffer.applying(to: rows())[0].weight, 47.5)
        buffer.didSave()
        XCTAssertNil(buffer.text(for: key))
    }
    func testImmediateCompletionReadsLastDigitAndEditOrder() throws {
        let buffer = WorkoutTextBuffer()
        buffer.set("1", for: .init(entryID: first, kind: .reps))
        buffer.set("12", for: .init(entryID: first, kind: .reps))
        buffer.set("50", for: .init(entryID: second, kind: .weight))
        buffer.set("47.5", for: .init(entryID: first, kind: .weight))
        let actual = try buffer.applying(to: rows())
        XCTAssertEqual(actual[0].reps, 12)
        XCTAssertEqual(actual.map(\.weight), [47.5, 50])
    }
    func testInvalidNumbersCannotFallBackToOldValues() throws {
        for raw in ["-1", "NaN", "inf", "12..5", "abc", "1" + String(repeating: "0", count: 308)] {
            XCTAssertThrowsError(try WorkoutTextBuffer.weight(raw), raw)
        }
        for raw in ["-1", "1.5", "12x", String(repeating: "9", count: 25)] {
            XCTAssertThrowsError(try WorkoutTextBuffer.reps(raw), raw)
        }
        XCTAssertEqual(try WorkoutTextBuffer.weight(""), 0)
        XCTAssertEqual(try WorkoutTextBuffer.weight("0"), 0)
    }
    func testExistingDraftAndLockedHistoryUntouchedWithoutRawEdits() throws {
        let buffer = WorkoutTextBuffer()
        var input = rows(reps: 9)
        input[0].state.isLocked = true
        buffer.set("70", for: .init(entryID: first, kind: .weight))
        let actual = try buffer.applying(to: input)
        XCTAssertEqual(actual[0].weight, 45)
        XCTAssertEqual(actual[0].reps, 9)
        XCTAssertTrue(actual[0].isLocked)
    }
    func testSaveFailureKeepsRawEditAndRetryPersistsLatestValues() throws {
        enum Failure: Error { case save }
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let entry = SetEntry(sessionId: UUID(), exerciseId: UUID(), setIndex: 1, weight: 45, reps: 9)
        context.insert(entry)
        try context.save()
        let buffer = WorkoutTextBuffer()
        buffer.set("47.5", for: .init(entryID: entry.id, kind: .weight))
        buffer.set("12", for: .init(entryID: entry.id, kind: .reps))
        XCTAssertThrowsError(try WorkoutInputPersistence.commit(buffer, entries: [entry], context: context,
            save: { _ in throw Failure.save }))
        XCTAssertEqual(entry.weight, 45)
        XCTAssertEqual(entry.reps, 9)
        XCTAssertEqual(buffer.edits.count, 2)
        XCTAssertTrue(try WorkoutInputPersistence.commit(buffer, entries: [entry], context: context))
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SetEntry>()).first)
        XCTAssertEqual(saved.weight, 47.5)
        XCTAssertEqual(saved.reps, 12)
        XCTAssertTrue(buffer.edits.isEmpty)
        XCTAssertThrowsError(try WorkoutInputPersistence.toggleComplete(entry, context: context,
            save: { _ in throw Failure.save }))
        XCTAssertFalse(entry.isLocked)
        XCTAssertNil(entry.lockedAt)
        try WorkoutInputPersistence.toggleComplete(entry, context: context)
        XCTAssertTrue(entry.isLocked)
        XCTAssertNotNil(entry.lockedAt)
    }
    func testCompletingRequiresActualRepsButAcceptsBodyweight() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let context = ModelContext(container)
        let entry = SetEntry(sessionId: UUID(), exerciseId: UUID(), setIndex: 1, weight: 0, reps: 0)
        context.insert(entry); try context.save()
        XCTAssertThrowsError(try WorkoutInputPersistence.toggleComplete(entry, context: context))
        XCTAssertFalse(entry.isLocked)
        entry.reps = 12
        try WorkoutInputPersistence.toggleComplete(entry, context: context)
        XCTAssertTrue(entry.isLocked)
        XCTAssertEqual(entry.weight, 0)
    }

    func testCableCompletionFreezesExactProfileAtomicallyAndRetainsUnits() throws {
        enum Failure: Error { case save }
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV16.self))
        let context = ModelContext(container); context.autosaveEnabled = false
        let value = ResistanceProfileValue.voltra(chainType: .inverseChains, eccentricPercent: 30, chainPounds: 35)
        let profile = try ResistanceProfileService.create(workoutKind: .fixed, sessionId: UUID(),
            exerciseId: UUID(), value: value, profiles: [], modelContext: context)
        let entry = SetEntry(sessionId: profile.sessionId, exerciseId: profile.exerciseId, setIndex: 1, weight: 130, reps: 12)
        context.insert(entry); try context.save()
        XCTAssertThrowsError(try WorkoutInputPersistence.toggleComplete(entry, requiresProfile: true, context: context))
        XCTAssertThrowsError(try WorkoutInputPersistence.toggleComplete(entry, profile: profile, requiresProfile: true,
            context: context, save: { _ in throw Failure.save }))
        XCTAssertFalse(entry.isLocked); XCTAssertNil(profile.frozenAt)
        XCTAssertNil(try ModelContext(container).fetch(FetchDescriptor<ExerciseResistanceProfile>()).first?.frozenAt)
        try WorkoutInputPersistence.toggleComplete(entry, profile: profile, requiresProfile: true, context: context)
        XCTAssertTrue(entry.isLocked); XCTAssertNotNil(profile.frozenAt)
        XCTAssertEqual(ResistanceProfileService.value(profile), value)
        XCTAssertEqual(profile.chainPounds, 35); XCTAssertNil(profile.chainPercent)
        XCTAssertEqual(profile.eccentricPercent, 30)
    }

}
