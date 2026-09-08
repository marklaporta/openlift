import XCTest
import SwiftData
@testable import OpenLift

final class SeatedShrugRevisionTests: XCTestCase {
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

    func testRevisionAddsTwoShrugRowsOnlyToAlternatingThirdClusterVariantsWithoutChangingExistingWork() throws {
        let f = try fixture()
        let oldShape = templateShape(f.template)
        let oldHistory = try history(f.context)
        let oldRows = try rows(f.context)
        let oldStates = try f.context.fetch(FetchDescriptor<ClusterRotationState>()).filter { $0.programVersionID == Program.revisionVersionID }
        let oldProfiles = ResistanceProfileService.snapshots(try f.context.fetch(FetchDescriptor<ExerciseResistanceProfile>()))
        let result = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true)
        let template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == result.templateId })
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(result.cycleId, f.cycle.id)
        XCTAssertEqual(try history(f.context), oldHistory)
        XCTAssertEqual(try rows(f.context), oldRows)
        XCTAssertEqual(templateShape(f.template), oldShape)
        XCTAssertEqual(ResistanceProfileService.snapshots(try f.context.fetch(FetchDescriptor<ExerciseResistanceProfile>())), oldProfiles)
        XCTAssertTrue(Program.isProgramTemplate(template))
        let states = try f.context.fetch(FetchDescriptor<ClusterRotationState>())
        XCTAssertEqual(states.count, 9)
        for old in oldStates {
            let new = try XCTUnwrap(states.first { $0.programVersionID == Program.shrugVersionID && $0.clusterID == old.clusterID })
            XCTAssertEqual(new.positionIndex, old.positionIndex)
            XCTAssertEqual(new.updatedAt, old.updatedAt)
            XCTAssertEqual(new.lastCompletedOccurrenceID, old.lastCompletedOccurrenceID)
            XCTAssertEqual(new.isDerived, old.isDerived)
        }
        let shrug = try XCTUnwrap(f.exercises.first { $0.name == Program.shrugExerciseName })
        XCTAssertEqual(shrug.primaryMuscle, .traps)
        XCTAssertEqual(shrug.type, .isolation)
        XCTAssertEqual(shrug.equipment, .dumbbell)
        XCTAssertFalse(shrug.equipment.supportsResistanceProfile)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<ExerciseResistanceProfile>()).contains { $0.exerciseId == shrug.id })
        for newDay in template.days {
            let oldDay = try XCTUnwrap(f.template.days.first { $0.position == newDay.position })
            XCTAssertEqual(newDay.slots.count, oldDay.slots.count + ([9, 11, 13].contains(newDay.position) ? 1 : 0))
            for old in oldDay.slots {
                let new = try XCTUnwrap(newDay.slots.first { $0.position == old.position })
                XCTAssertEqual(new.exerciseId, old.exerciseId)
                XCTAssertEqual(new.defaultSetCount, old.defaultSetCount)
            }
            if [9, 11, 13].contains(newDay.position) {
                let slot = try XCTUnwrap(newDay.slots.first { $0.position == 2 })
                XCTAssertEqual(slot.muscle, .traps)
                XCTAssertEqual(slot.exerciseId, shrug.id)
                XCTAssertEqual(slot.defaultSetCount, 2)
            }
        }
        let preferences = try f.context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let oldPreference = try XCTUnwrap(preferences.first { $0.programVersionID == Program.revisionVersionID })
        let newPreference = try XCTUnwrap(preferences.first { $0.programVersionID == Program.shrugVersionID })
        XCTAssertEqual(newPreference.templateDayPosition, oldPreference.templateDayPosition)
        XCTAssertEqual(newPreference.slotPosition, oldPreference.slotPosition)
        XCTAssertEqual(newPreference.exerciseId, oldPreference.exerciseId)
        XCTAssertEqual(newPreference.updatedAt, oldPreference.updatedAt)
        XCTAssertTrue(try BootstrapDataService.seatedShrugRevisionAudit(modelContext: f.context).contains("pointers=19,20,17 shrugSlots=3 shrugPositions=9,11,13 shrugRows=2,2,2 marker=true"))
        XCTAssertFalse(try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context).didApply)
        XCTAssertFalse(try BootstrapDataService.prepareClusteredProgramRollout(modelContext: f.context).didApply)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ClusterRotationState>()).count, 9)
    }

    func testExistingProgressionKeysSurviveAndShrugHistoryUsesOneIsolatedIdentity() throws {
        let f = try fixture()
        let result = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true)
        let template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == result.templateId })
        for cluster in Program.Cluster.allCases {
            for step in 0..<cluster.rotationLength {
                let oldDay = try XCTUnwrap(f.template.days.first { $0.position == cluster.templateBasePosition + step })
                let newDay = try XCTUnwrap(template.days.first { $0.position == oldDay.position })
                let old = Program.Selection(cluster: cluster, cycleInstanceId: f.cycle.id, templateId: f.template.id,
                    absoluteStep: step, effectiveStep: step, day: oldDay, programVersionID: Program.revisionVersionID)
                let new = Program.Selection(cluster: cluster, cycleInstanceId: f.cycle.id, templateId: template.id,
                    absoluteStep: step, effectiveStep: step, day: newDay, programVersionID: Program.shrugVersionID)
                for slot in oldDay.slots {
                    XCTAssertEqual(Program.progressionKey(selection: old, slotPosition: slot.position),
                        Program.progressionKey(selection: new, slotPosition: slot.position))
                }
                if cluster == .cluster3 && step % 2 == 0 {
                    XCTAssertEqual(Program.progressionKey(selection: new, slotPosition: 2), Program.shrugProgressionKey)
                    XCTAssertNotEqual(Program.progressionKey(selection: new, slotPosition: 1), Program.shrugProgressionKey)
                }
            }
        }
        let shrug = try XCTUnwrap(f.exercises.first { $0.name == Program.shrugExerciseName })
        func effort() throws -> ExerciseEffortLookupResult? {
            ExerciseEffortLookupService.fixedCycleEffort(exerciseId: shrug.id, cycleInstanceId: f.cycle.id, cycleDayIndex: 9,
                adaptiveSessions: [], adaptiveSetEntries: [], rotationSessions: try f.context.fetch(FetchDescriptor<Session>()),
                rotationSetEntries: try f.context.fetch(FetchDescriptor<SetEntry>()), progressionKey: Program.shrugProgressionKey,
                progressionOccurrences: try f.context.fetch(FetchDescriptor<ClusterOccurrenceRecord>()))
        }
        XCTAssertNil(try effort(), "A fresh shrug must not inherit shoulder, calf or forearm work")
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 3_000, shrugRows: 1)
        XCTAssertNil(try effort(), "The current F variant stays shrug-free; no forced first exposure")
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 4_000, shrugRows: 1)
        let repeated = try XCTUnwrap(try effort())
        XCTAssertEqual(repeated.rows.count, 1, "The literal completed count replaces the two-row starting dose")
        XCTAssertEqual(repeated.rows.first?.weight, 45)
        XCTAssertEqual(repeated.rows.first?.reps, 14)
    }

    func testRevisionRejectsMissingBackupAndAnyDraftWithoutMutation() throws {
        let f = try fixture()
        let oldShape = templateShape(f.template)
        let oldRows = try rows(f.context)
        XCTAssertThrowsError(try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context))
        let draft = Session(cycleInstanceId: f.cycle.id, cycleDayIndex: 0, status: .draft)
        f.context.insert(draft)
        try f.context.save()
        XCTAssertThrowsError(try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true))
        XCTAssertEqual(f.cycle.templateId, f.template.id)
        XCTAssertEqual(templateShape(f.template), oldShape)
        XCTAssertEqual(try rows(f.context), oldRows)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ClusterRotationState>()).count, 6)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == BootstrapDataService.seatedShrugRevisionMarker })
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Session>()).filter { $0.status == .draft }.map(\.id), [draft.id])
    }

    func testRevisionRejectsIncompletePointersWithoutMutation() throws {
        let f = try fixture()
        let removed = try XCTUnwrap(try f.context.fetch(FetchDescriptor<ClusterRotationState>()).first {
            $0.programVersionID == Program.revisionVersionID && $0.clusterID == "cluster-2"
        })
        f.context.delete(removed)
        try f.context.save()
        XCTAssertThrowsError(try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true))
        XCTAssertEqual(f.cycle.templateId, f.template.id)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ClusterRotationState>()).count, 5)
        XCTAssertFalse(try f.context.fetch(FetchDescriptor<CycleTemplate>()).contains { $0.name == Program.shrugTemplateName })
    }

    func testThreeVersionExportHydrationRetainsShrugsProfilesAndArchivedHistory() throws {
        let f = try fixture()
        let result = try BootstrapDataService.prepareSeatedShrugClusterRevision(modelContext: f.context, backupConfirmed: true)
        let template = try XCTUnwrap(try f.context.fetch(FetchDescriptor<CycleTemplate>()).first { $0.id == result.templateId })
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 3_000)
        _ = try completeSession(context: f.context, template: template, cycle: f.cycle, exercises: f.exercises, timestamp: 4_000)
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
        XCTAssertEqual(Set(exports.compactMap { $0.fixed_cycle?.program_version }), [1, 2, 3])
        let encoded = try JSONEncoder().encode(exports)
        let roundTripped = try JSONDecoder().decode([SessionExportService.ExportPayload].self, from: encoded)
        let destination = OpenLiftModelContainerFactory.makeInMemory(schema: Schema(versionedSchema: OpenLiftSchemaV15.self))
        let recovered = ModelContext(destination)
        _ = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: recovered)
        let cycle = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ActiveCycleInstance>()).first)
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped, cycle: cycle, modelContext: recovered)
        let recoveredTemplates = try recovered.fetch(FetchDescriptor<CycleTemplate>())
        let active = try XCTUnwrap(recoveredTemplates.first { $0.id == cycle.templateId })
        XCTAssertEqual(Program.versionID(for: active), Program.shrugVersionID)
        XCTAssertEqual(Set(recoveredTemplates.map { Program.versionNumber(for: $0) }), [1, 2, 3])
        let restoredStates = try recovered.fetch(FetchDescriptor<ClusterRotationState>())
        XCTAssertEqual(try Program.selections(template: active, cycleInstanceId: cycle.id, states: restoredStates).map(\.absoluteStep), [21, 22, 19])
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
        XCTAssertEqual(Set(newPrefs.map(\.programVersionID)), [Program.revisionVersionID, Program.shrugVersionID])
        XCTAssertEqual(newPrefs.filter { $0.programVersionID == Program.shrugVersionID }.count, 1)
        let recoveredProfile = try XCTUnwrap(try recovered.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first { $0.chainPounds == 7 })
        XCTAssertEqual(recoveredProfile.eccentricPounds, 3)
        let count = restored.count
        _ = try BootstrapDataService.reconcileWorkoutExports(roundTripped.filter { $0.fixed_cycle?.program_version == 2 }, cycle: cycle, modelContext: recovered)
        XCTAssertEqual(cycle.templateId, active.id, "Older exports must not downgrade the active program")
        XCTAssertEqual(try recovered.fetch(FetchDescriptor<ClusterOccurrenceRecord>()).count, count)
    }
}
