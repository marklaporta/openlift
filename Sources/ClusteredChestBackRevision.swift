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
                    ?? CompactExerciseName.resolve(item.1, in: exercises) else {
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

extension BootstrapDataService {
    struct RowConsolidationResult {
        let didApply: Bool
        let backupURL: URL?
    }

    @MainActor
    static func consolidateCSDBRow(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> RowConsolidationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == CSDBRowIdentity.marker }) {
            let legacy = exercises.filter { CSDBRowIdentity.legacyIDs.contains($0.id) }
            guard CSDBRowIdentity.canonical(in: exercises) != nil,
                  Set(legacy.map(\.id)) == CSDBRowIdentity.legacyIDs,
                  legacy.allSatisfy({ !$0.isActive }) else {
                throw ClusterRevisionError.invalidState
            }
            return RowConsolidationResult(didApply: false, backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw ClusterRevisionError.draftHasWork
        }
        let ids = CSDBRowIdentity.legacyIDs.union([CSDBRowIdentity.canonicalID])
        guard let canonical = exercises.first(where: { $0.id == CSDBRowIdentity.canonicalID }),
              Set(exercises.filter { ids.contains($0.id) }.map(\.id)) == ids,
              !exercises.contains(where: { !ids.contains($0.id) && CSDBRowIdentity.matches($0.name) }) else {
            throw ClusterRevisionError.invalidState
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-cs-db-row-consolidation-\(UUID().uuidString).sqlite")
        try snapshot(storeURL, backup)
        guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        do {
            let provenance = exercises.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }.map {
                "\($0.name) [\($0.id.uuidString)]:\n\($0.notes.isEmpty ? "No prior setup notes." : $0.notes)"
            }.joined(separator: "\n\n")
            canonical.name = CSDBRowIdentity.name
            canonical.primaryMuscle = .back
            canonical.type = .compound
            canonical.equipment = .dumbbell
            canonical.isActive = true
            canonical.notes = "Chest-supported DB row using the back of a bench (Helms setup) or Rogue multi-use lat seat. These are the same movement; keep support setup consistent when comparing efforts.\n\nPreserved pre-consolidation setup notes:\n\(provenance)"
            for old in exercises where CSDBRowIdentity.legacyIDs.contains(old.id) { old.isActive = false }
            try normalizeCSDBRowSelections(modelContext: modelContext)
            modelContext.insert(TrainingPreference(key: CSDBRowIdentity.marker, modeRawValue: CSDBRowIdentity.canonicalID.uuidString))
            try modelContext.save()
            return RowConsolidationResult(didApply: true, backupURL: backup)
        } catch { modelContext.rollback(); throw error }
    }

    /// Remove only the two rows proven newly inserted by name-only export
    /// hydration after consolidation. Never deduplicate sets by value.
    @MainActor
    static func repairCSDBRowRecoveryDuplicates(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> RowConsolidationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        guard !sessions.contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw ClusterRevisionError.draftHasWork
        }
        guard CSDBRowIdentity.canonical(in: try modelContext.fetch(FetchDescriptor<Exercise>())) != nil,
              try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == CSDBRowIdentity.marker }) else {
            throw ClusterRevisionError.invalidState
        }
        let sessionID = UUID(uuidString: "35AB747E-1761-41C4-963B-877C62D0B472")!
        let legacyID = UUID(uuidString: "45F7D9A2-52D5-4172-ACE7-78AEB5BF2C6F")!
        guard sessions.contains(where: { $0.id == sessionID && $0.status == .completed }) else {
            throw ClusterRevisionError.invalidState
        }
        let evidence: [(duplicate: UUID, original: UUID, index: Int, reps: Int)] = [
            (UUID(uuidString: "6F101C1C-4233-4AB5-884E-B61F9DDA12C0")!, UUID(uuidString: "6CEEFF75-B0D7-4542-AA56-2329FC4611EB")!, 1, 15),
            (UUID(uuidString: "AADC432A-80B9-45AC-97BF-693F09C494B9")!, UUID(uuidString: "42D2AB5B-04A2-48CE-A4C4-6B2AA649D9FA")!, 2, 8)
        ]
        let entries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        var duplicates: [SetEntry] = []
        for item in evidence {
            func matches(_ row: SetEntry, exerciseID: UUID) -> Bool {
                row.sessionId == sessionID && row.exerciseId == exerciseID && row.setIndex == item.index
                    && row.weight == 40 && row.reps == item.reps && row.isLocked
                    && row.lockedAt == nil && row.gripperModel == nil
            }
            guard let original = entries.first(where: { $0.id == item.original }),
                  matches(original, exerciseID: legacyID) else { throw ClusterRevisionError.invalidState }
            if let duplicate = entries.first(where: { $0.id == item.duplicate }) {
                guard matches(duplicate, exerciseID: CSDBRowIdentity.canonicalID) else { throw ClusterRevisionError.invalidState }
                duplicates.append(duplicate)
            }
        }
        guard !duplicates.isEmpty else { return RowConsolidationResult(didApply: false, backupURL: nil) }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-cs-db-row-recovery-repair-\(UUID().uuidString).sqlite")
        try snapshot(storeURL, backup)
        guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        do {
            duplicates.forEach(modelContext.delete)
            try modelContext.save()
            return RowConsolidationResult(didApply: true, backupURL: backup)
        } catch { modelContext.rollback(); throw error }
    }

    /// Only future selection references change. Completed evidence is untouched.
    static func normalizeCSDBRowSelections(modelContext: ModelContext) throws {
        func mapped(_ id: UUID) -> UUID { CSDBRowIdentity.legacyIDs.contains(id) ? CSDBRowIdentity.canonicalID : id }
        for row in try modelContext.fetch(FetchDescriptor<CycleSlot>()) where CSDBRowIdentity.legacyIDs.contains(row.exerciseId) { row.exerciseId = mapped(row.exerciseId) }
        for row in try modelContext.fetch(FetchDescriptor<RotationPoolEntry>()) where CSDBRowIdentity.legacyIDs.contains(row.exerciseId) { row.exerciseId = mapped(row.exerciseId) }
        for row in try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>()) where CSDBRowIdentity.legacyIDs.contains(row.exerciseId) { row.exerciseId = mapped(row.exerciseId) }
        for row in try modelContext.fetch(FetchDescriptor<AdaptiveComplexComponent>()) where CSDBRowIdentity.legacyIDs.contains(row.exerciseId) { row.exerciseId = mapped(row.exerciseId) }
        for row in try modelContext.fetch(FetchDescriptor<AdaptiveExerciseSelectionPreference>()) {
            if let id = row.pinnedExerciseId, CSDBRowIdentity.legacyIDs.contains(id) { row.pinnedExerciseId = mapped(id) }
            if row.eligibleExerciseIds.contains(where: CSDBRowIdentity.legacyIDs.contains) {
                var seen = Set<UUID>()
                row.eligibleExerciseIds = row.eligibleExerciseIds.map(mapped).filter { seen.insert($0).inserted }
            }
        }
    }
}

extension FixedCycleClusterProgramService {
    static let pairedCableRowID = UUID(uuidString: "9FCBF4C1-2E7E-4A2E-AD81-F0FB1CA7B2B8")!

    /// B/D exchange equipment, not progression identities. Other substitutions
    /// retain the existing slot-isolation semantics.
    static func pairedRowProgressionKey(selection: Selection, slotPosition: Int, exerciseId: UUID) -> String? {
        guard selection.programVersionID == chestBackVersionID, selection.cluster == .cluster1,
              slotPosition == 1, [1, 3].contains(selection.effectiveStep) else { return nil }
        if exerciseId == CSDBRowIdentity.canonicalID { return chestBackProgressionKey(step: 3, slotPosition: 1) }
        if exerciseId == pairedCableRowID { return chestBackProgressionKey(step: 1, slotPosition: 1) }
        return nil
    }
}

extension BootstrapDataService {
    @MainActor
    static func applyChestBackRowPairingWithFreshBackup(
        modelContext: ModelContext,
        backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> ClusterSquatSwapResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        typealias Program = FixedCycleClusterProgramService
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard cycles.count == 1, let cycle = cycles.first,
              let template = templates.first(where: { $0.id == cycle.templateId }),
              Program.versionID(for: template) == Program.chestBackVersionID else { throw ClusterRevisionError.invalidState }
        let preferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let targets = [(1, CSDBRowIdentity.canonicalID, Program.pairedCableRowID),
                       (15, Program.pairedCableRowID, CSDBRowIdentity.canonicalID)]
        var ids = Program.persistentExerciseIDsByKey(preferences: preferences, programVersionID: Program.chestBackVersionID)
        var changed = false
        for (position, target, original) in targets {
            let key = ClusterExercisePreference.key(programVersionID: Program.chestBackVersionID,
                templateDayPosition: position, slotPosition: 1)
            guard let day = template.days.first(where: { $0.position == position }),
                  let row = day.slots.first(where: { $0.position == 1 }),
                  day.slots.first(where: { $0.position == 0 })?.exerciseId == Program.recoveryMovements[position == 1 ? 0 : 2].0,
                  exercises.contains(where: { $0.id == target }),
                  preferences.filter({ $0.key == key }).count <= 1,
                  [original, target].contains(ids[key] ?? row.exerciseId) else { throw ClusterRevisionError.invalidState }
            changed = changed || (ids[key] ?? row.exerciseId) != target
            ids[key] = target
        }
        try Program.validatePersistentExercisePreferences(template: template, exerciseIDsByPreferenceKey: ids)
        guard changed else { return ClusterSquatSwapResult(didApply: false, backupURL: nil) }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw ClusterRevisionError.draftHasWork
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("before-row-pairing-\(UUID().uuidString).sqlite")
        do {
            try snapshot(storeURL, backupURL)
            guard StoreBackupService.isValidSnapshot(at: backupURL) else { throw SeatedShrugBackupError.verificationFailed }
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
        do {
            for (position, target, _) in targets {
                let key = ClusterExercisePreference.key(programVersionID: Program.chestBackVersionID,
                    templateDayPosition: position, slotPosition: 1)
                if let existing = preferences.first(where: { $0.key == key }) {
                    if existing.exerciseId != target { existing.exerciseId = target; existing.updatedAt = .now }
                } else {
                    modelContext.insert(ClusterExercisePreference(programVersionID: Program.chestBackVersionID,
                        templateDayPosition: position, slotPosition: 1, exerciseId: target))
                }
            }
            try modelContext.save()
            return ClusterSquatSwapResult(didApply: true, backupURL: backupURL)
        } catch { modelContext.rollback(); throw error }
    }
}
