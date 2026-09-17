import Foundation
import SwiftData

extension FixedCycleClusterProgramService {
    static let chestBackVersionID = "\(programIdentifier).v6"
    static let chestBackTemplateName = "Clustered Hypertrophy v6"
    static let chestBackIdentityKey = "openlift_clustered_hypertrophy_v6"
    static let singleArmPulldownID = UUID(uuidString: "D6FB95A8-A882-4CDE-99C8-3804530E0A76")!
    static let recoveryMovements: [(UUID, String)] = [
        (UUID(uuidString: "AD41745F-6104-43B0-A886-3A7065BB8466")!, "Seated Cable Flye"),
        (singleArmPulldownID, "Single-Arm Lat Pulldown"),
        (UUID(uuidString: "420AFD52-9446-41C3-92C5-1E9239709263")!, "Incline Dumbbell Flye"),
        (UUID(uuidString: "3122AC62-0E70-467F-AFA8-B890D6B334D1")!, "Chest-Supported Dumbbell Row")
    ]

    static func rotationLength(_ cluster: Cluster, version: String) -> Int {
        version == chestBackVersionID && cluster == .cluster1 ? 4 : cluster.rotationLength
    }

    static func templatePosition(_ cluster: Cluster, step: Int, version: String) -> Int {
        let effective = step % rotationLength(cluster, version: version)
        // Keep other clusters' existing exact-slot addresses unchanged.
        return version == chestBackVersionID && cluster == .cluster1 && effective == 3
            ? 15 : cluster.templateBasePosition + effective
    }

    static func chestBackProgressionKey(step: Int, slotPosition: Int) -> String {
        if slotPosition == 0 {
            return progressionKey(cluster: .cluster1, effectiveStep: [1, 2, 0, 2][step % 4], slotPosition: 0)
        }
        switch step % 4 {
        case 0: return progressionKey(cluster: .cluster1, effectiveStep: 0, slotPosition: 1)
        case 1: return progressionKey(cluster: .cluster1, effectiveStep: 2, slotPosition: 1)
        case 2: return "\(chestBackVersionID).cluster-1.back.single-arm-pulldown"
        default: return "\(chestBackVersionID).cluster-1.back.dumbbell-row"
        }
    }

    static func makeChestBackTemplate(exercises: [Exercise], preserving old: CycleTemplate? = nil) throws -> CycleTemplate {
        let base = try old ?? makeTemplate(exercises: exercises, thirdSideDelt: true)
        func existing(_ index: Int) throws -> UUID {
            let item = recoveryMovements[index]
            guard let exercise = exercises.first(where: { $0.id == item.0 })
                    ?? exercises.first(where: { $0.name == item.1 }) else {
                throw ProgramError.requiredExerciseMissing(item.1)
            }
            return exercise.id
        }
        func source(_ day: Int, _ slot: Int) throws -> CycleSlot {
            guard let found = base.days.first(where: { $0.position == day })?.slots.first(where: { $0.position == slot }) else {
                throw ProgramError.invalidClusterContext
            }
            return found
        }
        let chest = try [source(0, 0).exerciseId, existing(0), source(1, 0).exerciseId, existing(2)]
        let back = try [source(0, 1).exerciseId, source(1, 1).exerciseId, existing(1), existing(3)]
        var days = base.days.filter { (3...14).contains($0.position) }.map { day in
            CycleDay(label: day.label, slots: day.slots.map {
                CycleSlot(position: $0.position, muscle: $0.muscle, exerciseId: $0.exerciseId, defaultSetCount: $0.defaultSetCount)
            }, position: day.position)
        }
        for step in 0..<4 {
            days.append(CycleDay(label: "Cluster 1 · \(variantLabel(step))", slots: [
                CycleSlot(position: 0, muscle: .chest, exerciseId: chest[step], defaultSetCount: 2),
                CycleSlot(position: 1, muscle: .back, exerciseId: back[step], defaultSetCount: 2)
            ], position: templatePosition(.cluster1, step: step, version: chestBackVersionID)))
        }
        return CycleTemplate(name: chestBackTemplateName, days: days,
            rotationPools: [RotationPool(key: chestBackIdentityKey, entries: [])])
    }
}

extension BootstrapDataService {
    static let chestBackRevisionMarker = "clustered-program-revision-2026-09-17-v6"

    @MainActor
    static func applyChestBackRevisionWithFreshBackup(modelContext: ModelContext,
        backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> SideDeltApplicationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == chestBackRevisionMarker }) {
            return SideDeltApplicationResult(revision: try prepareChestBackRevision(modelContext: modelContext), backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw ClusterRevisionError.draftHasWork
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-chest-back-recovery-\(UUID().uuidString).sqlite")
        do {
            try snapshot(storeURL, backup)
            guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
        return SideDeltApplicationResult(revision: try prepareChestBackRevision(modelContext: modelContext, backupConfirmed: true), backupURL: backup)
    }

    @discardableResult
    static func prepareChestBackRevision(modelContext: ModelContext, backupConfirmed: Bool = false) throws -> ClusteredProgramRolloutResult {
        typealias Program = FixedCycleClusterProgramService
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        do {
            let markers = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
            if let marker = markers.first(where: { $0.key == chestBackRevisionMarker }) {
                let ids = marker.modeRawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                guard ids.count == 2, let template = templates.first(where: { $0.id == ids[0] }),
                      Program.isProgramTemplate(template), Program.versionID(for: template) == Program.chestBackVersionID,
                      cycles.contains(where: { $0.id == ids[1] && $0.templateId == ids[0] }) else { throw ClusterRevisionError.invalidState }
                try validateRecoveryStates(states.filter { $0.templateId == ids[0] && $0.cycleInstanceId == ids[1] && $0.programVersionID == Program.chestBackVersionID })
                return ClusteredProgramRolloutResult(templateId: ids[0], cycleId: ids[1], didApply: false)
            }
            guard backupConfirmed else { throw ClusterRevisionError.backupRequired }
            guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
                  !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
            let candidates = cycles.filter { cycle in templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) } }
            guard candidates.count == 1, let cycle = candidates.first,
                  let old = templates.first(where: { $0.id == cycle.templateId }),
                  Program.versionID(for: old) == Program.sideDeltVersionID,
                  !templates.contains(where: { $0.name == Program.chestBackTemplateName || Program.versionID(for: $0) == Program.chestBackVersionID }),
                  !states.contains(where: { $0.programVersionID == Program.chestBackVersionID }) else { throw ClusterRevisionError.invalidState }
            let oldStates = states.filter { $0.cycleInstanceId == cycle.id && $0.templateId == old.id && $0.programVersionID == Program.sideDeltVersionID }
            try validateRecoveryStates(oldStates)
            let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
            let template = try Program.makeChestBackTemplate(exercises: exercises, preserving: old)
            let preferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.sideDeltVersionID }
            guard Set(preferences.map(\.key)).count == preferences.count else { throw ClusterRevisionError.invalidState }
            var carried: [ClusterExercisePreference] = []
            for preference in preferences {
                var destination = preference.templateDayPosition
                if destination < 3 {
                    if destination == 2 { continue } // Explicit replacement of both C lanes; old preferences remain archived.
                    if destination == 1 && preference.slotPosition == 0 { destination = 2 }
                }
                carried.append(ClusterExercisePreference(programVersionID: Program.chestBackVersionID,
                    templateDayPosition: destination, slotPosition: preference.slotPosition,
                    exerciseId: preference.exerciseId, updatedAt: preference.updatedAt))
            }
            try Program.validatePersistentExercisePreferences(template: template,
                exerciseIDsByPreferenceKey: Program.persistentExerciseIDsByKey(preferences: carried, programVersionID: Program.chestBackVersionID))
            modelContext.insert(template)
            carried.forEach(modelContext.insert)
            for oldState in oldStates {
                // Raw counters are immutable completion counts, not a slot
                // number to reset. Verified counter24 starts v6 at A.
                modelContext.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id,
                    programVersionID: Program.chestBackVersionID, clusterID: oldState.clusterID, positionIndex: oldState.positionIndex,
                    updatedAt: oldState.updatedAt, lastCompletedOccurrenceID: oldState.lastCompletedOccurrenceID, isDerived: oldState.isDerived))
            }
            cycle.templateId = template.id
            let value = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            modelContext.insert(TrainingPreference(key: chestBackRevisionMarker, modeRawValue: value))
            markers.first(where: { $0.key == clusteredProgramRolloutMarkerKey })?.modeRawValue = value
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return ClusteredProgramRolloutResult(templateId: template.id, cycleId: cycle.id, didApply: true)
        } catch { modelContext.rollback(); throw error }
    }

    private static func validateRecoveryStates(_ states: [ClusterRotationState]) throws {
        guard states.count == 3, Set(states.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)),
              states.allSatisfy({ $0.positionIndex >= 0 }) else { throw ClusterRevisionError.invalidState }
    }
}
