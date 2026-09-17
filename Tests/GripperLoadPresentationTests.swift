import XCTest
@testable import OpenLift

final class GripperLoadPresentationTests: XCTestCase {
    func testExactModelsAndUnknownValuesAreNeverCoerced() {
        XCTAssertEqual(GripperLoadPresentation.models.map(\.value), [1, 2, 3])
        XCTAssertEqual(GripperLoadPresentation.models.map(\.label), ["G", "T", "1"])
        XCTAssertEqual(GripperLoadPresentation.set(3, reps: 6, name: "Captain of Crush"), "Model 1 × 6")
        XCTAssertEqual(GripperLoadPresentation.set(2, reps: 17, name: "CoC Gripper"), "Model T × 17")
        XCTAssertEqual(GripperLoadPresentation.load(1, exerciseId: GripperLoadPresentation.exerciseId, name: "Custom"), "Model G")
        XCTAssertNil(GripperLoadPresentation.modelLabel(1.01))
        XCTAssertTrue(GripperLoadPresentation.load(1.01, name: "Captain of Crush").contains("1.01"))
        XCTAssertTrue(GripperLoadPresentation.load(5, name: "Captain of Crush").contains("Unknown model"))
        XCTAssertFalse(GripperLoadPresentation.applies(name: "CoC Gripper Wrist Curl"))
        XCTAssertEqual(GripperLoadPresentation.set(225, reps: 12, name: "Stair Calves"), "225 × 12")
        XCTAssertEqual(GripperLoadPresentation.set(22.5, reps: 10, name: "DB Curl"), "22.5 × 10")
    }

    func testSelectionUsesExistingWeightEditingAndLockedRowsRemainUnchanged() {
        var rows = [
            WorkoutEntryEditing.EntryState(setIndex: 1, weight: 2, reps: 17, isLocked: false),
            WorkoutEntryEditing.EntryState(setIndex: 2, weight: 2, reps: 10, isLocked: false),
            WorkoutEntryEditing.EntryState(setIndex: 3, weight: 2, reps: 12, isLocked: true)
        ]
        for model in GripperLoadPresentation.models {
            WorkoutEntryEditing.applyWeightEdit(to: &rows, setIndex: 1, newWeight: model.value)
            XCTAssertEqual(rows[0].weight, model.value)
            XCTAssertEqual(rows[1].weight, model.value)
            XCTAssertEqual(rows[2].weight, 2)
            XCTAssertEqual(rows.map(\.reps), [17, 10, 12])
            XCTAssertEqual(GripperLoadPresentation.modelLabel(rows[0].weight), model.label)
        }
    }

    func testPreviousEffortUsesModelsWithoutChangingStoredRows() {
        let rows: [ComparableSetRow] = [
            .init(setIndex: 1, weight: 3, reps: 6, isLocked: true),
            .init(setIndex: 2, weight: 2, reps: 17, isLocked: true)
        ]
        let effort = ExerciseEffortLookupResult(
            sessionId: UUID(), completedAt: .now, sourceKind: .fixedCycle,
            matchKind: .sameProgressionIdentity, cycleName: nil, dayLabel: nil,
            rows: rows, resistanceProfile: nil, profileComparison: .exact
        )
        XCTAssertEqual(effort.compactSummary(exerciseId: GripperLoadPresentation.exerciseId, name: "Captain of Crush"), "Model 1 × 6 · Model T × 17")
        XCTAssertEqual(effort.compactSummary, "3 × 6 · 2 × 17")
        XCTAssertEqual(effort.rows, rows)
    }

    func testExportLabelsKeepRawHistoryAndOldExportsDecode() throws {
        let payload = SessionExportService.ExportExercise(
            exercise_id: GripperLoadPresentation.exerciseId.uuidString,
            exercise_name: "Captain of Crush", muscle: "forearms",
            sets: [.init(set_index: 1, weight: 3, reps: 6), .init(set_index: 2, weight: 2, reps: 17)]
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SessionExportService.ExportExercise.self, from: encoded)
        XCTAssertEqual(decoded.sets.map(\.weight), [3, 2])
        XCTAssertEqual(decoded.weight_encoding, GripperLoadPresentation.exportEncoding)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "weight_encoding")
        let old = try JSONDecoder().decode(SessionExportService.ExportExercise.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.weight_encoding)
        XCTAssertEqual(old.sets.map(\.weight), [3, 2])
        let ordinary = SessionExportService.ExportExercise(exercise_name: "Stair Calves", muscle: "calves", sets: [.init(set_index: 1, weight: 225, reps: 12)])
        XCTAssertNil(ordinary.weight_encoding)
        XCTAssertEqual(ordinary.sets[0].weight, 225)
    }
}
