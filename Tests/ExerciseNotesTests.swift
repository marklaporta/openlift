import SwiftData
import XCTest
@testable import OpenLift

final class ExerciseNotesTests: XCTestCase {
    @MainActor
    func testNotesSurviveStoreReopenRenameEditAndClearWithoutAWorkout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.store")
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        func openStore() throws -> ModelContainer {
            try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        }
        let exerciseID = UUID()
        let note = "Pin hole: 12 · visible number: 14\nStraps ready"
        try autoreleasepool {
            let container = try openStore()
            let context = ModelContext(container)
            let exercise = Exercise(id: exerciseID, name: "SLDL", primaryMuscle: .hamstrings,
                type: .compound, equipment: .barbell)
            let other = Exercise(name: "Squat", primaryMuscle: .quads,
                type: .compound, equipment: .barbell, notes: "Safeties: 8")
            context.insert(exercise)
            context.insert(other)
            try ExerciseNotesService.save("  \(note)\n", for: exercise, modelContext: context)
        }
        try autoreleasepool {
            let container = try openStore()
            let context = ModelContext(container)
            let exercises = try context.fetch(FetchDescriptor<Exercise>())
            let exercise = try XCTUnwrap(exercises.first { $0.id == exerciseID })
            XCTAssertEqual(exercise.notes, note)
            XCTAssertEqual(exercises.first { $0.name == "Squat" }?.notes, "Safeties: 8")
            exercise.name = "Stiff-Leg Deadlift"
            try ExerciseNotesService.save("Pin hole: 13 · visible number: 15", for: exercise, modelContext: context)
        }
        try autoreleasepool {
            let container = try openStore()
            let context = ModelContext(container)
            let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
            XCTAssertEqual(exercise.name, "Stiff-Leg Deadlift")
            XCTAssertEqual(exercise.notes, "Pin hole: 13 · visible number: 15")
            try ExerciseNotesService.save(" \n ", for: exercise, modelContext: context)
        }
        let container = try openStore()
        let context = ModelContext(container)
        let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        XCTAssertEqual(exercise.notes, "")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetEntry>()), 0)
    }
}
