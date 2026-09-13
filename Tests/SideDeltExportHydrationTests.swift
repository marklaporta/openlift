import XCTest
import SwiftData
@testable import OpenLift

final class SideDeltExportHydrationTests: XCTestCase {
    typealias Program = FixedCycleClusterProgramService

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let exercises: [Exercise]
        let template: CycleTemplate
        let cycle: ActiveCycleInstance
    }

    private func fixture() throws -> Fixture {
        let container = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let context = ModelContext(container)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let cycle = try XCTUnwrap(try context.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        let original = try XCTUnwrap(try context.fetch(FetchDescriptor<CycleTemplate>()).first)
        _ = try completeSession(context: context, template: original, cycle: cycle, exercises: exercises, timestamp: 1_000)
        let revised = try BootstrapDataService.prepareSeptember2026ClusterRevision(modelContext: context, backupConfirmed: true)
        let template = try XCTUnwrap(try context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == revised.templateId })
        for day in template.days {
            for slot in day.slots { slot.defaultSetCount = 1 + ((day.position + slot.position) % 4) }
        }
        let cablePullover = try XCTUnwrap(exercises.first { $0.name == "Cable Lat Pullover" })
        context.insert(ClusterExercisePreference(programVersionID: Program.revisionVersionID,
            templateDayPosition: 2, slotPosition: 1, exerciseId: cablePullover.id, updatedAt: Date(timeIntervalSince1970: 1_100)))
        try context.save()
        // Continuous immutable evidence, with independent completion counts.
        // Recovery correctly rejects merely jumping pointers over missing work.
        for step in 1..<20 {
            let clusters = zip(Program.Cluster.allCases, [19, 20, 17]).compactMap { cluster, target in
                step < target ? cluster : nil
            }
            _ = try completeSession(context: context, template: template, cycle: cycle, exercises: exercises,
                timestamp: Double(2_000 + step), clusters: clusters)
        }
        return Fixture(container: container, context: context, exercises: exercises, template: template, cycle: cycle)
    }

    @discardableResult
    private func completeSession(context: ModelContext, template: CycleTemplate, cycle: ActiveCycleInstance,
                                 exercises: [Exercise], timestamp: Double, shrugRows: Int = 1,
                                 clusters: [Program.Cluster] = Program.Cluster.allCases) throws -> Session {
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        let preferences = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0, cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Clustered Workout", finishedAt: Date(timeIntervalSince1970: timestamp), status: .completed)
        context.insert(session)
        for selection in try Program.selections(template: template, cycleInstanceId: cycle.id, states: states) where clusters.contains(selection.cluster) {
            let resolved = Program.resolvedSlots(selection: selection, sessionId: session.id, preferences: preferences, overrides: [])
            let entries = resolved.flatMap { item in
                (1...(item.slot.muscle == .traps ? shrugRows : 2)).map {
                    SetEntry(sessionId: session.id, exerciseId: item.exerciseId, setIndex: $0,
                        weight: item.slot.muscle == .traps ? 45 : 20, reps: 15 - $0, isLocked: true)
                }
            }
            entries.forEach(context.insert)
            for item in resolved where exercises.first(where: { $0.id == item.exerciseId })?.equipment == .cable {
                context.insert(ExerciseResistanceProfile(workoutKind: .fixed, sessionId: session.id, exerciseId: item.exerciseId,
                    resistanceSource: .voltra, chainType: .inverseChains, chainPounds: 7, eccentricPounds: 3,
                    frozenAt: session.finishedAt, createdAt: session.finishedAt!, updatedAt: session.finishedAt!))
            }
            let occurrence = try Program.makeOccurrence(session: session, selection: selection, exercises: exercises,
                entries: entries, resistanceProfiles: try context.fetch(FetchDescriptor<ExerciseResistanceProfile>()),
                preferences: preferences, completedAt: session.finishedAt!)
            context.insert(occurrence)
            try Program.advanceCompletedCluster(selection: selection, occurrence: occurrence, states: states)
        }
        try context.save()
        return session
    }

    private func templateShape(_ template: CycleTemplate) -> [String] {
        template.days.sorted { $0.position < $1.position }.flatMap { day in
            ["\(day.position)|\(day.label)"] + day.slots.sorted { $0.position < $1.position }.map {
                "\($0.position)|\($0.muscle.rawValue)|\($0.exerciseId)|\($0.defaultSetCount)"
            }
        }
    }

    private func history(_ context: ModelContext) throws -> [UUID: [ClusterExerciseProgressionSnapshot]] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).map { ($0.id, $0.exerciseSnapshots) })
    }

    private func rows(_ context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<SetEntry>()).map {
            "\($0.id)|\($0.sessionId)|\($0.exerciseId)|\($0.setIndex)|\($0.weight)|\($0.reps)|\($0.isLocked)|\(String(describing: $0.lockedAt))"
        }.sorted()
    }

    func testFiveVersionExportHydrationRetainsSideDeltsProfilesAndArchivedHistory() throws {
        let f = try fixture()
        let result = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true)
        let template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == result.templateId })
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 3_000)
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 4_000)
        let v4 = try BootstrapDataService.prepareSideDeltClusterRevision(modelContext: f.context, backupConfirmed: true)
        let v4Template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == v4.templateId })
        _ = try completeSession(context: f.context, template: v4Template, cycle: f.cycle, exercises: f.exercises, timestamp: 5_000)
        _ = try completeSession(context: f.context, template: v4Template, cycle: f.cycle, exercises: f.exercises, timestamp: 6_000)
        let v5 = try BootstrapDataService.prepareSideDeltOrderRevision(modelContext: f.context, backupConfirmed: true)
        let v5Template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == v5.templateId })
        _ = try completeSession(context: f.context, template: v5Template, cycle: f.cycle, exercises: f.exercises, timestamp: 7_000)
        _ = try completeSession(context: f.context, template: v5Template, cycle: f.cycle, exercises: f.exercises, timestamp: 8_000)
        let occurrences = try f.context.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let states = try f.context.fetch(FetchDescriptor<ClusterRotationState>())
        let preferences = try f.context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let entries = try f.context.fetch(FetchDescriptor<SetEntry>())
        let templates = try f.context.fetch(FetchDescriptor<CycleTemplate>())
        let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ShrugExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let environment = SessionExportService.ExportEnvironment(containerIdentifier: nil, iCloudContainerURL: nil,
            localDocumentsURL: exportRoot, coordinatedWrite: { data, url in try data.write(to: url, options: .atomic) },
            ubiquityMetadata: { _ in SessionExportService.UbiquityMetadata(isUbiquitousItem: false,
                isUploaded: false, isUploading: false, uploadingErrorDescription: nil) })
        let exports = try f.context.fetch(FetchDescriptor<Session>()).map { session in
            let owner = templates.first { $0.id == occurrences.first { $0.sessionId == session.id }!.templateId }!
            let metadata = SessionExportService.fixedCycleMetadata(session: session, template: owner, day: owner.days[0],
                exercises: f.exercises, setEntries: entries, readiness: [], overrides: [],
                clusterOccurrences: occurrences, clusterRotationStates: states, clusterExercisePreferences: preferences)
            let written = try SessionExportService.export(session: session, cycleName: owner.name, exercises: f.exercises,
                setEntries: entries.filter { $0.sessionId == session.id }, fixedCycleMetadata: metadata, environment: environment)
            return try JSONDecoder().decode(SessionExportService.ExportPayload.self,
                from: Data(contentsOf: XCTUnwrap(written.localMirrorURL)))
        }
        XCTAssertEqual(Set(exports.compactMap { $0.fixed_cycle?.program_version }), [1, 2, 3, 4, 5])
        let encoded = try JSONEncoder().encode(exports)
        let roundTripped = try JSONDecoder().decode([SessionExportService.ExportPayload].self, from: encoded)
        let destination = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let recovered = ModelContext(destination)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let cycle = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped, cycle: cycle, modelContext: recovered)
        let recoveredTemplates = try recovered.fetch(FetchDescriptor<CycleTemplate>())
        let active = try XCTUnwrap(recoveredTemplates.first { $0.id == cycle.templateId })
        XCTAssertEqual(Program.versionID(for: active), Program.sideDeltOrderVersionID)
        XCTAssertEqual(Set(recoveredTemplates.map { Program.versionNumber(for: $0) }), [1, 2, 3, 4, 5])
        // Recovery resolves catalog UUIDs by name; verify the whole canonical
        // shoulder mapping and semantic keys, plus frozen evidence below.
        let restoredCatalog = try recovered.fetch(FetchDescriptor<Exercise>())
        for step in 0..<6 {
            let sourceStates = Program.makeRotationStates(cycleInstanceId: f.cycle.id, templateId: v5Template.id,
                programVersionID: Program.sideDeltOrderVersionID)
            let destinationStates = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: active.id,
                programVersionID: Program.sideDeltOrderVersionID)
            sourceStates.first { $0.clusterID == "cluster-3" }!.positionIndex = step
            destinationStates.first { $0.clusterID == "cluster-3" }!.positionIndex = step
            let sourceSelection = try Program.selection(cluster: .cluster3, template: v5Template,
                cycleInstanceId: f.cycle.id, states: sourceStates)
            let restoredSelection = try Program.selection(cluster: .cluster3, template: active,
                cycleInstanceId: cycle.id, states: destinationStates)
            let sourceID = sourceSelection.day.slots.first { $0.position == 0 }!.exerciseId
            let restoredID = restoredSelection.day.slots.first { $0.position == 0 }!.exerciseId
            XCTAssertEqual(restoredCatalog.first { $0.id == restoredID }?.name,
                f.exercises.first { $0.id == sourceID }?.name)
            XCTAssertEqual(Program.progressionKey(selection: restoredSelection, slotPosition: 0),
                Program.progressionKey(selection: sourceSelection, slotPosition: 0))
        }
        let restoredStates = try recovered.fetch(FetchDescriptor<ClusterRotationState>())
        XCTAssertEqual(try Program.selections(template: active, cycleInstanceId: cycle.id, states: restoredStates).map(\.absoluteStep), [25, 26, 23])
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<SetEntry>()).count, entries.count)
        let restored = try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        XCTAssertEqual(restored.count, occurrences.count)
        for original in occurrences {
            let copy = try XCTUnwrap(restored.first { $0.sessionId == original.sessionId && $0.clusterID == original.clusterID })
            XCTAssertEqual(copy.programVersionID, original.programVersionID)
            XCTAssertEqual(copy.exerciseSnapshots.map(\.progressionKey), original.exerciseSnapshots.map(\.progressionKey))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.exerciseName), original.exerciseSnapshots.map(\.exerciseName))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.prescribedSetCount), original.exerciseSnapshots.map(\.prescribedSetCount))
            XCTAssertEqual(copy.exerciseSnapshots.map(\.resistanceProfile), original.exerciseSnapshots.map(\.resistanceProfile))
        }
        let newPrefs = try recovered.fetch(FetchDescriptor<ClusterExercisePreference>())
        XCTAssertEqual(Set(newPrefs.map(\.programVersionID)), [Program.revisionVersionID, Program.shrugVersionID, Program.sideDeltVersionID, Program.sideDeltOrderVersionID])
        XCTAssertEqual(newPrefs.filter { $0.programVersionID == Program.shrugVersionID }.count, 1)
        let recoveredProfile = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first { $0.chainPounds == 7 })
        XCTAssertEqual(recoveredProfile.eccentricPounds, 3)
        let count = restored.count
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped.filter { $0.fixed_cycle?.program_version == 2 }, cycle: cycle, modelContext: recovered)
        XCTAssertEqual(cycle.templateId, active.id, "Older exports must not downgrade the active program")
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).count, count)
    }
}
