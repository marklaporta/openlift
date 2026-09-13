import Foundation
import SwiftData

extension BootstrapDataService {
    static let sideDeltRevisionMarker = "clustered-program-revision-2026-09-12-v4"

    struct SideDeltApplicationResult {
        let revision: ClusteredProgramRolloutResult
        let backupURL: URL?
    }

    /// User-initiated, synchronous on the main actor: no UI write can interleave
    /// between the fresh consolidated snapshot and the revision transaction.
    /// Daily snapshots are intentionally not reused; they can predate today's work.
    @MainActor
    static func applySideDeltRevisionWithFreshBackup(
        modelContext: ModelContext,
        backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> SideDeltApplicationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == sideDeltRevisionMarker }) {
            return SideDeltApplicationResult(
                revision: try prepareSideDeltClusterRevision(modelContext: modelContext), backupURL: nil)
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
        let backupURL = directory.appendingPathComponent("before-third-side-delt-\(UUID().uuidString).sqlite")
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
        let revision = try prepareSideDeltClusterRevision(modelContext: modelContext, backupConfirmed: true)
        return SideDeltApplicationResult(revision: revision, backupURL: backupURL)
    }

    /// Explicit, backup-gated content revision. No schema or completed history
    /// changes; surviving progression identities remain authoritative.
    @discardableResult
    static func prepareSideDeltClusterRevision(
        modelContext: ModelContext,
        backupConfirmed: Bool = false
    ) throws -> ClusteredProgramRolloutResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        do {
            let markers = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
            if let marker = markers.first(where: { $0.key == sideDeltRevisionMarker }) {
                let ids = marker.modeRawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                guard ids.count == 2,
                      let template = templates.first(where: { $0.id == ids[0] }),
                      FixedCycleClusterProgramService.isProgramTemplate(template),
                      FixedCycleClusterProgramService.versionID(for: template) == FixedCycleClusterProgramService.sideDeltVersionID,
                      cycles.contains(where: { $0.id == ids[1] && $0.templateId == ids[0] }) else {
                    throw ClusterRevisionError.invalidState
                }
                try validateSideDeltRevisionStates(states.filter {
                    $0.cycleInstanceId == ids[1] && $0.templateId == ids[0]
                        && $0.programVersionID == FixedCycleClusterProgramService.sideDeltVersionID
                })
                return ClusteredProgramRolloutResult(templateId: ids[0], cycleId: ids[1], didApply: false)
            }
            guard backupConfirmed else { throw ClusterRevisionError.backupRequired }
            let candidates = cycles.filter { cycle in
                templates.contains { $0.id == cycle.templateId && FixedCycleClusterProgramService.isProgramTemplate($0) }
            }
            guard candidates.count == 1, let cycle = candidates.first,
                  let oldTemplate = templates.first(where: { $0.id == cycle.templateId }),
                  FixedCycleClusterProgramService.versionID(for: oldTemplate) == FixedCycleClusterProgramService.shrugVersionID,
                  !templates.contains(where: {
                      $0.name.caseInsensitiveCompare(FixedCycleClusterProgramService.sideDeltTemplateName) == .orderedSame
                          || $0.rotationPools.contains { $0.key == FixedCycleClusterProgramService.sideDeltIdentityKey }
                  }),
                  !states.contains(where: { $0.programVersionID == FixedCycleClusterProgramService.sideDeltVersionID }) else {
                throw ClusterRevisionError.invalidState
            }
            let oldStates = states.filter {
                $0.cycleInstanceId == cycle.id && $0.templateId == oldTemplate.id
                    && $0.programVersionID == FixedCycleClusterProgramService.shrugVersionID
            }
            try validateSideDeltRevisionStates(oldStates)
            guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
                  !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
                throw ClusterRevisionError.draftHasWork
            }
            let exercises = try ensureExerciseCatalog(modelContext: modelContext, saveChanges: false)
            let template = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises, thirdSideDelt: true)
            let oldPreferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
                .filter { $0.programVersionID == FixedCycleClusterProgramService.shrugVersionID }
            typealias Program = FixedCycleClusterProgramService
            guard Set(oldPreferences.map(\.key)).count == oldPreferences.count else {
                throw ClusterRevisionError.invalidState
            }
            var carried: [ClusterExercisePreference] = []
            var consumed = Set<String>()
            let shoulderStep = oldStates.first { $0.clusterID == Program.Cluster.cluster3.rawValue }!.positionIndex
            for newDay in template.days {
                for newSlot in newDay.slots {
                    let sources: [(CycleDay, CycleSlot)]
                    if newDay.position >= 9 && newSlot.position == 0 {
                        if newSlot.exerciseId == Program.sideDeltExerciseID || newSlot.exerciseId == exercises.first(where: { $0.name == Program.sideDeltExerciseName })?.id {
                            continue // Two blank rows, no old identity or substitution is inherited.
                        }
                        sources = oldTemplate.days.filter { $0.position >= 9 }.compactMap { day in
                            day.slots.first { $0.position == 0 && $0.exerciseId == newSlot.exerciseId }.map { (day, $0) }
                        }
                        guard sources.count == 3 else { throw ClusterRevisionError.invalidState }
                    } else {
                        guard let day = oldTemplate.days.first(where: { $0.position == newDay.position }),
                              let slot = day.slots.first(where: { $0.position == newSlot.position }),
                              slot.exerciseId == newSlot.exerciseId, slot.muscle == newSlot.muscle else {
                            throw ClusterRevisionError.invalidState
                        }
                        sources = [(day, slot)]
                    }
                    // A two-exercise lane had three structural occurrences of each
                    // identity. Contradictory exact-slot substitutions cannot be
                    // collapsed into the new two occurrences without losing intent.
                    let mapped = sources.map { day, slot in
                        let key = ClusterExercisePreference.key(programVersionID: Program.shrugVersionID,
                            templateDayPosition: day.position, slotPosition: slot.position)
                        return (day, slot, oldPreferences.first { $0.key == key })
                    }
                    guard Set(mapped.map { $0.2?.exerciseId ?? $0.1.exerciseId }).count == 1 else {
                        throw ClusterRevisionError.invalidState
                    }
                    // Carry the most recently scheduled source's fallback dose;
                    // actual qualifying performance still supplies literal rows.
                    let source = mapped.min { lhs, rhs in
                        let last = (shoulderStep + 5) % 6
                        return (last - (lhs.0.position - 9) + 6) % 6 < (last - (rhs.0.position - 9) + 6) % 6
                    }!
                    newSlot.defaultSetCount = source.1.defaultSetCount
                    for item in mapped { if let preference = item.2 { consumed.insert(preference.key) } }
                    if let preference = mapped.compactMap({ $0.2 }).max(by: { $0.updatedAt < $1.updatedAt }) {
                        carried.append(ClusterExercisePreference(programVersionID: Program.sideDeltVersionID,
                            templateDayPosition: newDay.position, slotPosition: newSlot.position,
                            exerciseId: preference.exerciseId, updatedAt: preference.updatedAt))
                    }
                }
            }
            guard consumed == Set(oldPreferences.map(\.key)) else { throw ClusterRevisionError.invalidState }
            try FixedCycleClusterProgramService.validatePersistentExercisePreferences(template: template,
                exerciseIDsByPreferenceKey: FixedCycleClusterProgramService.persistentExerciseIDsByKey(
                    preferences: carried, programVersionID: FixedCycleClusterProgramService.sideDeltVersionID))
            modelContext.insert(template)
            carried.forEach(modelContext.insert)
            for old in oldStates {
                modelContext.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id,
                    programVersionID: FixedCycleClusterProgramService.sideDeltVersionID, clusterID: old.clusterID,
                    positionIndex: old.positionIndex, updatedAt: old.updatedAt,
                    lastCompletedOccurrenceID: old.lastCompletedOccurrenceID, isDerived: old.isDerived))
            }
            cycle.templateId = template.id
            let markerValue = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            modelContext.insert(TrainingPreference(key: sideDeltRevisionMarker, modeRawValue: markerValue))
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
    static func sideDeltRevisionAudit(modelContext: ModelContext) throws -> String {
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
        try validateSideDeltRevisionStates(states)
        let pointers = states.sorted { $0.clusterID < $1.clusterID }.map { String($0.positionIndex) }.joined(separator: ",")
        let names = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Exercise>()).map { ($0.id, $0.name) })
        let lane = template.days.filter { $0.position >= 9 }.sorted { $0.position < $1.position }.map { day in
            names[day.slots.first { $0.position == 0 }!.exerciseId] ?? "missing"
        }.joined(separator: "|")
        let marker = try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains { $0.key == sideDeltRevisionMarker }
        return "version=\(version) pointers=\(pointers) sideDelts=\(lane) marker=\(marker)"
    }

    private static func validateSideDeltRevisionStates(_ states: [ClusterRotationState]) throws {
        guard states.count == 3,
              Set(states.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)),
              states.allSatisfy({ $0.positionIndex >= 0 }) else { throw ClusterRevisionError.invalidState }
    }
}
