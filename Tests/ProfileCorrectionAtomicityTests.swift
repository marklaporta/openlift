import SQLite3
import SwiftData
import XCTest
@testable import OpenLift

final class ProfileCorrectionAtomicityTests: XCTestCase {
    @MainActor
    func testMalformedLaterOccurrenceRejectsUpdateWithoutPartialCorrection() throws {
        try assertMalformedOccurrenceRejectsCorrection(hasProfile: true)
    }

    @MainActor
    func testMalformedLaterOccurrenceRejectsCreationWithoutPartialCorrection() throws {
        try assertMalformedOccurrenceRejectsCorrection(hasProfile: false)
    }

    @MainActor
    private func assertMalformedOccurrenceRejectsCorrection(hasProfile: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("synthetic.store")
        let schema = Schema(versionedSchema: OpenLiftSchemaV15.self)
        func container() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
            ])
        }
        let sessionID = UUID(), exerciseID = UUID(), cycleID = UUID(), templateID = UUID()
        let original: ResistanceProfileValue? = hasProfile ? .weightStack : nil
        let corrected = ResistanceProfileValue.voltra(chainType: .inverseChains,
                                                      chainPounds: 35, eccentricPounds: 12.5)
        try autoreleasepool {
            let context = ModelContext(try container())
            context.insert(Session(id: sessionID, cycleInstanceId: cycleID, cycleDayIndex: 0,
                finishedAt: Date(timeIntervalSince1970: 1000), status: .completed, exportStatus: .success))
            context.insert(Exercise(id: exerciseID, name: "Original name", primaryMuscle: .back,
                                    type: .compound, equipment: .cable))
            context.insert(SetEntry(sessionId: sessionID, exerciseId: exerciseID,
                setIndex: 1, weight: 70, reps: 10, isLocked: false))
            if let original {
                let profile = try ResistanceProfileService.create(workoutKind: .fixed,
                    sessionId: sessionID, exerciseId: exerciseID, value: original,
                    profiles: [], modelContext: context)
                profile.frozenAt = Date(timeIntervalSince1970: 1000)
            }
            for clusterID in ["cluster-1", "cluster-2"] {
                context.insert(try ClusterOccurrenceRecord(sessionId: sessionID,
                    cycleInstanceId: cycleID, templateId: templateID,
                    programVersionID: FixedCycleClusterProgramService.programVersionID,
                    clusterID: clusterID, positionIndex: 0, templateDayPosition: 0, dayLabel: clusterID,
                    exerciseSnapshots: [.init(position: 0, exerciseId: exerciseID,
                        exerciseName: "Frozen row", muscle: .back, prescribedSetCount: 1,
                        progressionKey: "key", resistanceProfile: original, completionStatus: .performed)]))
            }
            try context.save()
        }
        // Corrupt only this synthetic fixture after its writer has closed.
        // Using SQLite avoids adding a production API for invalid snapshot bytes.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database,
            "UPDATE ZCLUSTEROCCURRENCERECORD SET ZEXERCISESNAPSHOTSDATA = X'7B' WHERE ZCLUSTERID = 'cluster-2'",
            nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(database), 1)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let modelContainer = try container()
        let context = ModelContext(modelContainer)
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<Session>()).first)
        let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<SetEntry>()).first)
        let occurrences = try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let first = try XCTUnwrap(occurrences.first { $0.clusterID == "cluster-1" })
        let beforeSnapshot = first.exerciseSnapshots
        let profiles = try context.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        let beforeUpdatedAt = profiles.first?.updatedAt
        exercise.name = "Unrelated pending edit"

        XCTAssertThrowsError(try {
            if let profile = profiles.first {
                try ResistanceProfileService.update(profile, to: corrected,
                    confirmedOccurrenceWideCorrection: true, modelContext: context)
            } else {
                try ResistanceProfileService.createPerformedOccurrence(workoutKind: .fixed,
                    sessionId: sessionID, exerciseId: exerciseID, value: corrected, profiles: [],
                    confirmedOccurrenceWideCorrection: true, modelContext: context)
            }
        }())
        XCTAssertEqual(first.exerciseSnapshots, beforeSnapshot)
        XCTAssertEqual(ResistanceProfileService.value(
            try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first), original)
        XCTAssertEqual(profiles.first?.updatedAt, beforeUpdatedAt)
        XCTAssertEqual([row.weight, Double(row.reps)], [70, 10])
        XCTAssertEqual(session.exportStatus, .success)
        XCTAssertEqual(exercise.name, "Unrelated pending edit")
        XCTAssertTrue(context.hasChanges)
        let persistedBeforeSave = ModelContext(modelContainer)
        XCTAssertEqual(try persistedBeforeSave.fetch(FetchDescriptor<Exercise>()).first?.name,
                       "Original name")
        // Persisting unrelated work afterwards must not also persist a rejected correction.
        try context.save()
        let reopened = ModelContext(modelContainer)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
            .first { $0.clusterID == "cluster-1" }?.exerciseSnapshots, beforeSnapshot)
        XCTAssertEqual(ResistanceProfileService.value(
            try reopened.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first), original)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<ExerciseResistanceProfile>()), hasProfile ? 1 : 0)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<Exercise>()).first?.name, "Unrelated pending edit")
    }
}
