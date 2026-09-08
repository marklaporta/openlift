import Foundation
import SwiftData

extension BootstrapDataService {
    static let seatedShrugRevisionMarker = "clustered-program-revision-2026-09-08-v3"

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
