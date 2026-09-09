import Foundation
import SwiftData

extension BootstrapDataService {
    static let seatedShrugRevisionMarker = "clustered-program-revision-2026-09-08-v3"

    struct SeatedShrugApplicationResult {
        let revision: ClusteredProgramRolloutResult
        let backupURL: URL?
    }

    enum SeatedShrugBackupError: LocalizedError {
        case persistentStoreRequired, verificationFailed

        var errorDescription: String? {
            switch self {
            case .persistentStoreRequired: return "The workout store is unavailable for a fresh backup. No program changes were made."
            case .verificationFailed: return "The fresh workout backup could not be verified. No program changes were made."
            }
        }
    }

    /// User-initiated, synchronous on the main actor: no UI write can interleave
    /// between the fresh consolidated snapshot and the revision transaction.
    /// Daily snapshots are intentionally not reused; they can predate today's work.
    @MainActor
    static func applySeatedShrugRevisionWithFreshBackup(
        modelContext: ModelContext,
        backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> SeatedShrugApplicationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == seatedShrugRevisionMarker }) {
            return SeatedShrugApplicationResult(
                revision: try prepareSeatedShrugClusterRevision(modelContext: modelContext), backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw ClusterRevisionError.draftHasWork
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else {
            throw SeatedShrugBackupError.persistentStoreRequired
        }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenLift/revision-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("before-alternating-shrugs-\(UUID().uuidString).sqlite")
        // A unique, previously absent destination proves this attempt cannot
        // accidentally accept a valid but stale daily recovery point.
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw SeatedShrugBackupError.verificationFailed
        }
        do {
            try snapshot(storeURL, backupURL)
            guard StoreBackupService.isValidSnapshot(at: backupURL) else {
                throw SeatedShrugBackupError.verificationFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
        // Retain the verified backup even if program validation refuses the
        // revision. Completed history and any pending draft remain untouched.
        let revision = try prepareSeatedShrugClusterRevision(modelContext: modelContext, backupConfirmed: true)
        return SeatedShrugApplicationResult(revision: revision, backupURL: backupURL)
    }

    /// Explicit, backup-gated content revision. No schema or completed history
    /// changes; existing v2 progression identities remain authoritative.
    @discardableResult
    static func prepareSeatedShrugClusterRevision(
        modelContext: ModelContext,
        backupConfirmed: Bool = false
    ) throws -> ClusteredProgramRolloutResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        do {
            let markers = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
            if let marker = markers.first(where: { $0.key == seatedShrugRevisionMarker }) {
                let ids = marker.modeRawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                guard ids.count == 2,
                      let template = templates.first(where: { $0.id == ids[0] }),
                      FixedCycleClusterProgramService.isProgramTemplate(template),
                      FixedCycleClusterProgramService.versionID(for: template) == FixedCycleClusterProgramService.shrugVersionID,
                      cycles.contains(where: { $0.id == ids[1] && $0.templateId == ids[0] }) else {
                    throw ClusterRevisionError.invalidState
                }
                try validateShrugRevisionStates(states.filter {
                    $0.cycleInstanceId == ids[1] && $0.templateId == ids[0]
                        && $0.programVersionID == FixedCycleClusterProgramService.shrugVersionID
                })
                return ClusteredProgramRolloutResult(templateId: ids[0], cycleId: ids[1], didApply: false)
            }
            guard backupConfirmed else { throw ClusterRevisionError.backupRequired }
            let candidates = cycles.filter { cycle in
                templates.contains { $0.id == cycle.templateId && FixedCycleClusterProgramService.isProgramTemplate($0) }
            }
            guard candidates.count == 1, let cycle = candidates.first,
                  let oldTemplate = templates.first(where: { $0.id == cycle.templateId }),
                  FixedCycleClusterProgramService.versionID(for: oldTemplate) == FixedCycleClusterProgramService.revisionVersionID,
                  !templates.contains(where: {
                      $0.name.caseInsensitiveCompare(FixedCycleClusterProgramService.shrugTemplateName) == .orderedSame
                          || $0.rotationPools.contains { $0.key == FixedCycleClusterProgramService.shrugIdentityKey }
                  }),
                  !states.contains(where: { $0.programVersionID == FixedCycleClusterProgramService.shrugVersionID }) else {
                throw ClusterRevisionError.invalidState
            }
            let oldStates = states.filter {
                $0.cycleInstanceId == cycle.id && $0.templateId == oldTemplate.id
                    && $0.programVersionID == FixedCycleClusterProgramService.revisionVersionID
            }
            try validateShrugRevisionStates(oldStates)
            guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
                  !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
                throw ClusterRevisionError.draftHasWork
            }
            let exercises = try ensureExerciseCatalog(modelContext: modelContext, saveChanges: false)
            let template = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises, shrugs: true)
            let oldPreferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
                .filter { $0.programVersionID == FixedCycleClusterProgramService.revisionVersionID }
            // Positions and canonical identities are unchanged; carry only the
            // previous two/three slots, never source a new shrug dose or load.
            var carried: [ClusterExercisePreference] = []
            for oldDay in oldTemplate.days {
                guard let newDay = template.days.first(where: { $0.position == oldDay.position }) else {
                    throw ClusterRevisionError.invalidState
                }
                for oldSlot in oldDay.slots {
                    guard let newSlot = newDay.slots.first(where: { $0.position == oldSlot.position }),
                          newSlot.muscle == oldSlot.muscle,
                          newSlot.exerciseId == oldSlot.exerciseId else {
                        throw ClusterRevisionError.invalidState
                    }
                    newSlot.defaultSetCount = oldSlot.defaultSetCount
                    let key = ClusterExercisePreference.key(programVersionID: FixedCycleClusterProgramService.revisionVersionID,
                        templateDayPosition: oldDay.position, slotPosition: oldSlot.position)
                    if let preference = oldPreferences.first(where: { $0.key == key }) {
                        carried.append(ClusterExercisePreference(programVersionID: FixedCycleClusterProgramService.shrugVersionID,
                            templateDayPosition: oldDay.position, slotPosition: oldSlot.position,
                            exerciseId: preference.exerciseId, updatedAt: preference.updatedAt))
                    }
                }
            }
            guard carried.count == oldPreferences.count else { throw ClusterRevisionError.invalidState }
            try FixedCycleClusterProgramService.validatePersistentExercisePreferences(template: template,
                exerciseIDsByPreferenceKey: FixedCycleClusterProgramService.persistentExerciseIDsByKey(
                    preferences: carried, programVersionID: FixedCycleClusterProgramService.shrugVersionID))
            modelContext.insert(template)
            carried.forEach(modelContext.insert)
            for old in oldStates {
                modelContext.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id,
                    programVersionID: FixedCycleClusterProgramService.shrugVersionID, clusterID: old.clusterID,
                    positionIndex: old.positionIndex, updatedAt: old.updatedAt,
                    lastCompletedOccurrenceID: old.lastCompletedOccurrenceID, isDerived: old.isDerived))
            }
            cycle.templateId = template.id
            let markerValue = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            modelContext.insert(TrainingPreference(key: seatedShrugRevisionMarker, modeRawValue: markerValue))
            markers.first(where: { $0.key == clusteredProgramRolloutMarkerKey })?.modeRawValue = markerValue
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return ClusteredProgramRolloutResult(templateId: template.id, cycleId: cycle.id, didApply: true)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Read-only launch audit, also usable before activation. Does not create
    /// drafts, export workouts, or advance any cluster.
    static func seatedShrugRevisionAudit(modelContext: ModelContext) throws -> String {
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let candidates = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && FixedCycleClusterProgramService.isProgramTemplate($0) }
        }
        guard candidates.count == 1, let cycle = candidates.first,
              let template = templates.first(where: { $0.id == cycle.templateId }) else { throw ClusterRevisionError.invalidState }
        let version = FixedCycleClusterProgramService.versionID(for: template)
        let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>()).filter {
            $0.cycleInstanceId == cycle.id && $0.templateId == template.id && $0.programVersionID == version
        }
        try validateShrugRevisionStates(states)
        let pointers = states.sorted { $0.clusterID < $1.clusterID }.map { String($0.positionIndex) }.joined(separator: ",")
        let shrugDays = template.days.sorted { $0.position < $1.position }.filter { day in
            day.position >= 9 && day.slots.contains { $0.position == 2 && $0.muscle == .traps }
        }
        let positions = shrugDays.map { String($0.position) }.joined(separator: ",")
        let counts = shrugDays.compactMap { $0.slots.first { $0.position == 2 && $0.muscle == .traps }?.defaultSetCount }
        let marker = try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == seatedShrugRevisionMarker }
        return "version=\(version) pointers=\(pointers) shrugSlots=\(counts.count) shrugPositions=\(positions) shrugRows=\(counts.map(String.init).joined(separator: ",")) marker=\(marker)"
    }

    private static func validateShrugRevisionStates(_ states: [ClusterRotationState]) throws {
        guard states.count == 3,
              Set(states.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)),
              states.allSatisfy({ $0.positionIndex >= 0 }) else { throw ClusterRevisionError.invalidState }
    }
}

extension BootstrapDataService {
    struct ClusterSquatSwapResult {
        let didApply: Bool
        let backupURL: URL?
    }

    /// Two exact-slot overlays, not a new template or program version. The
    /// existing v3 template remains the recovery authority for source identities.
    @MainActor
    static func applyClusterSquatSwapWithFreshBackup(
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
              Program.versionID(for: template) == Program.shrugVersionID else { throw ClusterRevisionError.invalidState }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        guard let d = template.days.first(where: { $0.position == 6 })?.slots.first(where: { $0.position == 0 }),
              let f = template.days.first(where: { $0.position == 8 })?.slots.first(where: { $0.position == 0 }),
              exercises.first(where: { $0.id == d.exerciseId })?.name == "Safety Bar Squat",
              exercises.first(where: { $0.id == f.exerciseId })?.name == "Bulgarian Split Squat" else {
            throw ClusterRevisionError.invalidState
        }
        let preferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        let targets = [(6, f.exerciseId, d.exerciseId), (8, d.exerciseId, f.exerciseId)]
        var ids = Program.persistentExerciseIDsByKey(preferences: preferences, programVersionID: Program.shrugVersionID)
        var changed = false
        for (position, target, original) in targets {
            let key = ClusterExercisePreference.key(programVersionID: Program.shrugVersionID,
                templateDayPosition: position, slotPosition: 0)
            guard preferences.filter({ $0.key == key }).count <= 1,
                  ids[key] == nil || ids[key] == original || ids[key] == target else { throw ClusterRevisionError.invalidState }
            changed = changed || ids[key] != target
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
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenLift/revision-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("before-squat-swap-\(UUID().uuidString).sqlite")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { throw SeatedShrugBackupError.verificationFailed }
        do {
            try snapshot(storeURL, backupURL)
            guard StoreBackupService.isValidSnapshot(at: backupURL) else { throw SeatedShrugBackupError.verificationFailed }
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw error
        }
        do {
            let now = Date.now
            for (position, target, _) in targets {
                let key = ClusterExercisePreference.key(programVersionID: Program.shrugVersionID,
                    templateDayPosition: position, slotPosition: 0)
                if let existing = preferences.first(where: { $0.key == key }) {
                    if existing.exerciseId != target {
                        existing.exerciseId = target
                        existing.updatedAt = now
                    }
                } else {
                    modelContext.insert(ClusterExercisePreference(programVersionID: Program.shrugVersionID,
                        templateDayPosition: position, slotPosition: 0, exerciseId: target, updatedAt: now))
                }
            }
            try modelContext.save()
            return ClusterSquatSwapResult(didApply: true, backupURL: backupURL)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    static func clusterSquatSwapAudit(modelContext: ModelContext) throws -> String {
        typealias Program = FixedCycleClusterProgramService
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let candidates = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard candidates.count == 1, let cycle = candidates.first,
              let template = templates.first(where: { $0.id == cycle.templateId }),
              Program.versionID(for: template) == Program.shrugVersionID else { throw ClusterRevisionError.invalidState }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let preferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        // Detached states enumerate the lane without moving persisted pointers.
        let detached = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id,
            programVersionID: Program.shrugVersionID)
        let legState = detached.first { $0.clusterID == Program.Cluster.cluster2.rawValue }!
        let legs = try (0..<6).map { step -> String in
            legState.positionIndex = step
            let selection = try Program.selection(cluster: .cluster2, template: template, cycleInstanceId: cycle.id, states: detached)
            guard let leg = Program.resolvedSlots(selection: selection, sessionId: UUID(), preferences: preferences, overrides: []).first,
                  let exercise = exercises.first(where: { $0.id == leg.exerciseId }) else { throw ClusterRevisionError.invalidState }
            return "\(Program.variantLabel(step))=[\(exercise.name);key=\(leg.progressionKey);rows=\(leg.slot.defaultSetCount)]"
        }.joined(separator: " ")
        return "\(try seatedShrugRevisionAudit(modelContext: modelContext)) \(legs)"
    }

}
