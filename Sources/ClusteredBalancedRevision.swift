import Foundation
import SwiftData

extension FixedCycleClusterProgramService {
    static let balancedVersionID = "\(programIdentifier).v7"
    static let balancedTemplateName = "Clustered Hypertrophy v7"
    static let balancedIdentityKey = "openlift_clustered_hypertrophy_v7"
    static let balancedLegNames = ["Back Extension", "Belt Squat", "Stiff-Leg Deadlift", "Bulgarian Split Squat",
                                   "Reverse Hyper", "Safety Bar Squat", "Leg Curl", "Leg Extension"]

    static func isBalancedTemplate(_ template: CycleTemplate) -> Bool {
        guard template.rotationPools.contains(where: { $0.key == balancedIdentityKey && $0.entries.isEmpty }),
              template.days.count == 34, Set(template.days.map(\.position)) == Set(0..<34) else { return false }
        return Cluster.allCases.allSatisfy { cluster in
            (0..<rotationLength(cluster, version: balancedVersionID)).allSatisfy { step in
                guard let day = template.days.first(where: { $0.position == templatePosition(cluster, step: step, version: balancedVersionID) }) else { return false }
                let roles: [MuscleGroup] = cluster == .cluster1 ? [.chest, .back]
                    : cluster == .cluster2 ? [step % 2 == 0 ? .hamstrings : .quads, .triceps, .biceps]
                    : step % 2 == 0 ? [.sideDelts, .calves, .traps] : [.sideDelts, .forearms]
                let slots = CycleOrdering.sortedSlots(day.slots)
                return day.label == "\(cluster.displayName) · \(variantLabel(step))" && slots.count == roles.count
                    && slots.enumerated().allSatisfy { $0.element.position == $0.offset && $0.element.muscle == roles[$0.offset] && $0.element.defaultSetCount > 0 }
            }
        }
    }

    static func balancedMovementKey(role: String, exerciseId: UUID) -> String {
        "\(balancedVersionID).movement.\(role).\(exerciseId.uuidString.lowercased())"
    }

    static func isBalancedMovementKey(_ key: String, exerciseId: UUID) -> Bool {
        ["legs", "shoulders", "calves"].contains { key == balancedMovementKey(role: $0, exerciseId: exerciseId) }
    }

    /// Explicit v7 continuity aliases are UUID- and role-scoped. They never
    /// rename old snapshots or borrow a different exercise's slot history.
    static func acceptsBalancedHistory(requestedKey: String, exerciseId: UUID,
        snapshot: ClusterExerciseProgressionSnapshot, occurrence: ClusterOccurrenceRecord) -> Bool {
        guard snapshot.exerciseId == exerciseId, supports(programVersionID: occurrence.programVersionID),
              isBalancedMovementKey(requestedKey, exerciseId: exerciseId) else { return false }
        if requestedKey == balancedMovementKey(role: "legs", exerciseId: exerciseId) {
            return occurrence.clusterID == Cluster.cluster2.rawValue && snapshot.position == 0
                && [.quads, .hamstrings].contains(snapshot.muscle)
        }
        if requestedKey == balancedMovementKey(role: "shoulders", exerciseId: exerciseId) {
            return occurrence.clusterID == Cluster.cluster3.rawValue && snapshot.position == 0 && snapshot.muscle == .sideDelts
        }
        return occurrence.clusterID == Cluster.cluster3.rawValue && snapshot.position == 1 && snapshot.muscle == .calves
    }

    static func balancedProgressionKey(selection: Selection, slotPosition: Int, exerciseId: UUID) -> String? {
        guard selection.programVersionID == balancedVersionID else { return nil }
        switch selection.cluster {
        case .cluster1:
            if slotPosition == 1 && [1, 3].contains(selection.effectiveStep) {
                if exerciseId == CSDBRowIdentity.canonicalID { return chestBackProgressionKey(step: 3, slotPosition: 1) }
                if exerciseId == pairedCableRowID { return chestBackProgressionKey(step: 1, slotPosition: 1) }
            }
            return chestBackProgressionKey(step: selection.effectiveStep, slotPosition: slotPosition)
        case .cluster2:
            return slotPosition == 0 ? balancedMovementKey(role: "legs", exerciseId: exerciseId)
                : progressionKey(cluster: .cluster2, effectiveStep: selection.effectiveStep % 3, slotPosition: slotPosition)
        case .cluster3:
            if slotPosition == 0 { return balancedMovementKey(role: "shoulders", exerciseId: exerciseId) }
            if slotPosition == 2 { return shrugProgressionKey }
            return selection.effectiveStep % 2 == 0 ? balancedMovementKey(role: "calves", exerciseId: exerciseId)
                : progressionKey(cluster: .cluster3, effectiveStep: selection.effectiveStep, slotPosition: slotPosition)
        }
    }

    static func makeBalancedRecoveryTemplate(exercises: [Exercise]) throws -> CycleTemplate {
        let old = try makeChestBackTemplate(exercises: exercises)
        // A fresh catalog may not yet contain the unilateral cable-row identity;
        // occurrence exports restore the exact performed selections afterward.
        let previousCable = old.days.first { $0.position == 1 }!.slots.first { $0.position == 1 }!.exerciseId
        old.days.first { $0.position == 1 }?.slots.first { $0.position == 1 }?.exerciseId = old.days.first { $0.position == 15 }!.slots.first { $0.position == 1 }!.exerciseId
        if exercises.contains(where: { $0.id == pairedCableRowID }) {
            old.days.first { $0.position == 15 }?.slots.first { $0.position == 1 }?.exerciseId = pairedCableRowID
        } else {
            old.days.first { $0.position == 15 }?.slots.first { $0.position == 1 }?.exerciseId = previousCable
        }
        return try makeBalancedTemplate(exercises: exercises, preserving: old, preferences: [], cycleId: UUID())
    }

    static func makeBalancedTemplate(exercises: [Exercise], preserving old: CycleTemplate,
        preferences: [ClusterExercisePreference], cycleId: UUID) throws -> CycleTemplate {
        guard versionID(for: old) == chestBackVersionID, isProgramTemplate(old) else { throw ProgramError.invalidClusterContext }
        guard Set(preferences.map(\.key)).count == preferences.count else { throw ProgramError.invalidClusterContext }
        try validatePersistentExercisePreferences(template: old, exerciseIDsByPreferenceKey: persistentExerciseIDsByKey(preferences: preferences, programVersionID: chestBackVersionID))
        func required(_ name: String) throws -> Exercise {
            guard let item = CompactExerciseName.resolve(name, in: exercises) else { throw ProgramError.requiredExerciseMissing(name) }
            return item
        }
        let legs = try balancedLegNames.map(required)
        let shoulders = try [sideDeltExerciseName, "Super ROM DB Lateral Raise", "Cable Lateral Raise"].map(required)
        let states = makeRotationStates(cycleInstanceId: cycleId, templateId: old.id, programVersionID: chestBackVersionID)
        func source(_ cluster: Cluster, _ step: Int) throws -> [ResolvedSlot] {
            states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
            return resolvedSlots(selection: try selection(cluster: cluster, template: old, cycleInstanceId: cycleId, states: states),
                                 sessionId: UUID(), preferences: preferences, overrides: [])
        }
        let oldLegs = try (0..<6).map { try source(.cluster2, $0)[0] }
        var days: [CycleDay] = []
        for cluster in Cluster.allCases {
            for step in 0..<rotationLength(cluster, version: balancedVersionID) {
                let existing = try source(cluster, step % rotationLength(cluster, version: chestBackVersionID))
                let slots = existing.map { CycleSlot(position: $0.slot.position, muscle: $0.slot.muscle,
                    exerciseId: $0.exerciseId, defaultSetCount: $0.slot.defaultSetCount) }
                if cluster == .cluster2 {
                    let leg = legs[step % 8]
                    slots[0].exerciseId = leg.id
                    slots[0].muscle = step % 2 == 0 ? .hamstrings : .quads
                    slots[0].defaultSetCount = oldLegs.first { $0.exerciseId == leg.id }?.slot.defaultSetCount ?? 2
                } else if cluster == .cluster3 {
                    slots[0].exerciseId = shoulders[step % 3].id
                }
                days.append(CycleDay(label: "\(cluster.displayName) · \(variantLabel(step))", slots: slots,
                    position: templatePosition(cluster, step: step, version: balancedVersionID)))
            }
        }
        let template = CycleTemplate(name: balancedTemplateName, days: days,
            rotationPools: [RotationPool(key: balancedIdentityKey, entries: [])])
        guard isBalancedTemplate(template) else { throw ProgramError.invalidClusterContext }
        try template.validate(exercisesById: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) }))
        try validatePersistentExercisePreferences(template: template, exerciseIDsByPreferenceKey: [:])
        return template
    }
}

extension BootstrapDataService {
    static let balancedRevisionMarker = "clustered-program-revision-2026-09-18-v7"

    @MainActor
    static func applyBalancedRevisionWithFreshBackup(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot) throws -> SideDeltApplicationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == balancedRevisionMarker }) {
            return SideDeltApplicationResult(revision: try prepareBalancedRevision(modelContext: modelContext), backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-balanced-rotation-\(UUID().uuidString).sqlite")
        do {
            try snapshot(storeURL, backup)
            guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        } catch { try? FileManager.default.removeItem(at: backup); throw error }
        return SideDeltApplicationResult(revision: try prepareBalancedRevision(modelContext: modelContext, backupConfirmed: true), backupURL: backup)
    }

    @discardableResult
    static func prepareBalancedRevision(modelContext: ModelContext, backupConfirmed: Bool = false) throws -> ClusteredProgramRolloutResult {
        typealias Program = FixedCycleClusterProgramService
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        do {
            let markers = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
            if let marker = markers.first(where: { $0.key == balancedRevisionMarker }) {
                let ids = marker.modeRawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                guard ids.count == 2, let template = templates.first(where: { $0.id == ids[0] }), Program.isBalancedTemplate(template),
                      cycles.contains(where: { $0.id == ids[1] && $0.templateId == ids[0] }) else { throw ClusterRevisionError.invalidState }
                try validateBalancedStates(states.filter { $0.templateId == ids[0] && $0.cycleInstanceId == ids[1] && $0.programVersionID == Program.balancedVersionID })
                return ClusteredProgramRolloutResult(templateId: ids[0], cycleId: ids[1], didApply: false)
            }
            guard backupConfirmed else { throw ClusterRevisionError.backupRequired }
            guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
                  !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
            let candidates = cycles.filter { c in templates.contains { $0.id == c.templateId && Program.isProgramTemplate($0) } }
            guard candidates.count == 1, let cycle = candidates.first, let old = templates.first(where: { $0.id == cycle.templateId }),
                  Program.versionID(for: old) == Program.chestBackVersionID,
                  !templates.contains(where: { $0.name == Program.balancedTemplateName || Program.versionNumber(for: $0) == 7 }),
                  !states.contains(where: { $0.programVersionID == Program.balancedVersionID }) else { throw ClusterRevisionError.invalidState }
            let oldStates = states.filter { $0.templateId == old.id && $0.cycleInstanceId == cycle.id && $0.programVersionID == Program.chestBackVersionID }
            try validateBalancedStates(oldStates)
            let template = try Program.makeBalancedTemplate(exercises: modelContext.fetch(FetchDescriptor<Exercise>()), preserving: old,
                preferences: modelContext.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.chestBackVersionID }, cycleId: cycle.id)
            modelContext.insert(template)
            for state in oldStates {
                modelContext.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id,
                    programVersionID: Program.balancedVersionID, clusterID: state.clusterID, positionIndex: state.positionIndex,
                    updatedAt: state.updatedAt, lastCompletedOccurrenceID: state.lastCompletedOccurrenceID, isDerived: state.isDerived))
            }
            cycle.templateId = template.id
            let value = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            modelContext.insert(TrainingPreference(key: balancedRevisionMarker, modeRawValue: value))
            markers.first(where: { $0.key == clusteredProgramRolloutMarkerKey })?.modeRawValue = value
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return ClusteredProgramRolloutResult(templateId: template.id, cycleId: cycle.id, didApply: true)
        } catch { modelContext.rollback(); throw error }
    }

    private static func validateBalancedStates(_ states: [ClusterRotationState]) throws {
        guard states.count == 3, Set(states.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)),
              states.allSatisfy({ $0.positionIndex >= 0 }) else { throw ClusterRevisionError.invalidState }
    }
}

extension BootstrapDataService {
    static let quadPhaseRevisionMarker = "clustered-quad-phase-2026-09-19"

    /// September 19's leg extension counts as the preceding quad exposure.
    /// Only future exact-slot preferences change; v7 movement keys already follow UUIDs.
    @MainActor
    static func applyQuadPhaseWithFreshBackup(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot) throws -> ClusterSquatSwapResult {
        typealias Program = FixedCycleClusterProgramService
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == quadPhaseRevisionMarker }) {
            return ClusterSquatSwapResult(didApply: false, backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
        let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard cycles.count == 1, let cycle = cycles.first,
              let template = templates.first(where: { $0.id == cycle.templateId }),
              Program.isBalancedTemplate(template) else { throw ClusterRevisionError.invalidState }
        let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>()).filter {
            $0.cycleInstanceId == cycle.id && $0.templateId == template.id && $0.programVersionID == Program.balancedVersionID
        }
        try validateBalancedStates(states)
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let quadNames = ["Leg Extension", "Belt Squat", "Bulgarian Split Squat", "Safety Bar Squat"]
        let targets = try quadNames.map { name -> UUID in
            guard let exercise = CompactExerciseName.resolve(name, in: exercises) else { throw Program.ProgramError.requiredExerciseMissing(name) }
            return exercise.id
        }
        let preferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        guard Set(preferences.map(\.key)).count == preferences.count else { throw ClusterRevisionError.invalidState }
        var ids = Program.persistentExerciseIDsByKey(preferences: preferences, programVersionID: Program.balancedVersionID)
        var changes: [(String, Int, UUID)] = []
        for step in stride(from: 1, to: 24, by: 2) {
            let position = Program.templatePosition(.cluster2, step: step, version: Program.balancedVersionID)
            let key = ClusterExercisePreference.key(programVersionID: Program.balancedVersionID, templateDayPosition: position, slotPosition: 0)
            guard let slot = template.days.first(where: { $0.position == position })?.slots.first(where: { $0.position == 0 }),
                  slot.muscle == .quads, targets.contains(ids[key] ?? slot.exerciseId) else { throw ClusterRevisionError.invalidState }
            let target = targets[(step / 2) % 4]
            ids[key] = target
            changes.append((key, position, target))
        }
        try Program.validatePersistentExercisePreferences(template: template, exerciseIDsByPreferenceKey: ids)
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-quad-phase-\(UUID().uuidString).sqlite")
        do {
            try snapshot(storeURL, backup)
            guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        } catch { try? FileManager.default.removeItem(at: backup); throw error }
        do {
            for (key, position, target) in changes {
                if let existing = preferences.first(where: { $0.key == key }) {
                    if existing.exerciseId != target { existing.exerciseId = target; existing.updatedAt = .now }
                } else {
                    modelContext.insert(ClusterExercisePreference(programVersionID: Program.balancedVersionID,
                        templateDayPosition: position, slotPosition: 0, exerciseId: target))
                }
            }
            modelContext.insert(TrainingPreference(key: quadPhaseRevisionMarker,
                modeRawValue: "\(template.id.uuidString)|\(cycle.id.uuidString)"))
            try modelContext.save()
            return ClusterSquatSwapResult(didApply: true, backupURL: backup)
        } catch { modelContext.rollback(); throw error }
    }
}

// MARK: Explicit synchronized arm revision (v8)
extension FixedCycleClusterProgramService {
    static let syncedArmsVersionID = "\(programIdentifier).v8"
    static let syncedArmsTemplateName = "Clustered Hypertrophy v8"
    static let syncedArmsIdentityKey = "openlift_clustered_hypertrophy_v8"
    static let hammerCurlID = UUID(uuidString: "A8D6049B-0E33-43C8-91A9-6A4A689F2218")!
    static let singleArmOverheadID = UUID(uuidString: "17BC2F9D-F0A2-4604-AA41-33ADD79ED16B")!

    static func isSyncedArmsTemplate(_ template: CycleTemplate) -> Bool {
        guard template.rotationPools.contains(where: { $0.key == syncedArmsIdentityKey && $0.entries.isEmpty }),
              template.days.count == 18, Set(template.days.map(\.position)) == Set(0..<18) else { return false }
        return Cluster.allCases.allSatisfy { cluster in
            (0..<rotationLength(cluster, version: syncedArmsVersionID)).allSatisfy { step in
                guard let day = template.days.first(where: { $0.position == templatePosition(cluster, step: step, version: syncedArmsVersionID) }) else { return false }
                let roles: [MuscleGroup] = cluster == .cluster1 ? [.chest, .back, .triceps, .biceps]
                    : cluster == .cluster2 ? [step % 2 == 0 ? .hamstrings : .quads]
                    : step % 2 == 0 ? [.sideDelts, .calves, .traps] : [.sideDelts, .forearms]
                let slots = CycleOrdering.sortedSlots(day.slots)
                return day.label == "\(cluster.displayName) · \(variantLabel(step))" && slots.count == roles.count
                    && slots.enumerated().allSatisfy { $0.element.position == $0.offset && $0.element.muscle == roles[$0.offset] && $0.element.defaultSetCount > 0 }
            }
        }
    }

    static func syncedArmsProgressionKey(selection: Selection, slotPosition: Int, exerciseId: UUID) -> String? {
        guard selection.programVersionID == syncedArmsVersionID else { return nil }
        switch selection.cluster {
        case .cluster1:
            if slotPosition >= 2 {
                if selection.effectiveStep < 3 {
                    return progressionKey(cluster: .cluster2, effectiveStep: selection.effectiveStep, slotPosition: slotPosition - 1)
                }
                return "\(syncedArmsVersionID).movement.\(slotPosition == 2 ? "triceps" : "biceps").\(exerciseId.uuidString.lowercased())"
            }
            if slotPosition == 1 && [1, 3].contains(selection.effectiveStep) {
                if exerciseId == CSDBRowIdentity.canonicalID { return chestBackProgressionKey(step: 3, slotPosition: 1) }
                if exerciseId == pairedCableRowID { return chestBackProgressionKey(step: 1, slotPosition: 1) }
            }
            return chestBackProgressionKey(step: selection.effectiveStep, slotPosition: slotPosition)
        case .cluster2: return balancedMovementKey(role: "legs", exerciseId: exerciseId)
        case .cluster3:
            if slotPosition == 0 { return balancedMovementKey(role: "shoulders", exerciseId: exerciseId) }
            if slotPosition == 2 { return shrugProgressionKey }
            return selection.effectiveStep % 2 == 0 ? balancedMovementKey(role: "calves", exerciseId: exerciseId)
                : progressionKey(cluster: .cluster3, effectiveStep: selection.effectiveStep, slotPosition: slotPosition)
        }
    }

    static func makeSyncedArmsRecoveryTemplate(exercises: [Exercise]) throws -> CycleTemplate {
        try makeSyncedArmsTemplate(exercises: exercises, preserving: makeBalancedRecoveryTemplate(exercises: exercises), preferences: [], cycleId: UUID())
    }

    static func makeSyncedArmsTemplate(exercises: [Exercise], preserving old: CycleTemplate,
        preferences: [ClusterExercisePreference], cycleId: UUID) throws -> CycleTemplate {
        guard versionID(for: old) == balancedVersionID, isBalancedTemplate(old),
              Set(preferences.map(\.key)).count == preferences.count else { throw ProgramError.invalidClusterContext }
        try validatePersistentExercisePreferences(template: old, exerciseIDsByPreferenceKey: persistentExerciseIDsByKey(preferences: preferences, programVersionID: balancedVersionID))
        guard exercises.contains(where: { $0.id == hammerCurlID }), exercises.contains(where: { $0.id == singleArmOverheadID }) else { throw ProgramError.requiredExerciseMissing("Synchronized arm movements") }
        let states = makeRotationStates(cycleInstanceId: cycleId, templateId: old.id, programVersionID: balancedVersionID)
        func source(_ cluster: Cluster, _ step: Int) throws -> [ResolvedSlot] {
            states.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
            return resolvedSlots(selection: try selection(cluster: cluster, template: old, cycleInstanceId: cycleId, states: states), sessionId: UUID(), preferences: preferences, overrides: [])
        }
        let legArmRows = try (0..<24).map { try source(.cluster2, $0) }
        // Exact-slot customizations may make a subcycle irreducible. Never discard them.
        for step in 0..<24 {
            let leg = legArmRows[step][0], canonicalLeg = legArmRows[step % 8][0]
            guard leg.exerciseId == canonicalLeg.exerciseId, leg.slot.defaultSetCount == canonicalLeg.slot.defaultSetCount else { throw ProgramError.invalidClusterContext }
            for slot in 1...2 {
                let arm = legArmRows[step][slot], canonicalArm = legArmRows[step % 3][slot]
                guard arm.exerciseId == canonicalArm.exerciseId, arm.slot.defaultSetCount == canonicalArm.slot.defaultSetCount else { throw ProgramError.invalidClusterContext }
            }
        }
        var days: [CycleDay] = []
        for cluster in Cluster.allCases {
            for step in 0..<rotationLength(cluster, version: syncedArmsVersionID) {
                let existing = try source(cluster, step)
                var slots = existing.filter { cluster != .cluster2 || $0.slot.position == 0 }.map {
                    CycleSlot(position: $0.slot.position, muscle: $0.slot.muscle, exerciseId: $0.exerciseId, defaultSetCount: $0.slot.defaultSetCount)
                }
                if cluster == .cluster1 {
                    if step < 3 {
                        slots += legArmRows[step].dropFirst().map { CycleSlot(position: $0.slot.position + 1, muscle: $0.slot.muscle, exerciseId: $0.exerciseId, defaultSetCount: $0.slot.defaultSetCount) }
                    } else {
                        slots += [CycleSlot(position: 2, muscle: .triceps, exerciseId: singleArmOverheadID, defaultSetCount: 2), CycleSlot(position: 3, muscle: .biceps, exerciseId: hammerCurlID, defaultSetCount: 2)]
                    }
                }
                days.append(CycleDay(label: "\(cluster.displayName) · \(variantLabel(step))", slots: slots, position: templatePosition(cluster, step: step, version: syncedArmsVersionID)))
            }
        }
        let template = CycleTemplate(name: syncedArmsTemplateName, days: days, rotationPools: [RotationPool(key: syncedArmsIdentityKey, entries: [])])
        guard isSyncedArmsTemplate(template) else { throw ProgramError.invalidClusterContext }
        try template.validate(exercisesById: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) }))
        try validatePersistentExercisePreferences(template: template, exerciseIDsByPreferenceKey: [:])
        return template
    }
}

extension BootstrapDataService {
    static func ensureSyncedArmExercises(modelContext: ModelContext, recovery: Bool) throws -> [Exercise] {
        typealias Program = FixedCycleClusterProgramService
        var catalog = try modelContext.fetch(FetchDescriptor<Exercise>())
        if !catalog.contains(where: { $0.id == Program.singleArmOverheadID }) {
            guard recovery, !catalog.contains(where: { CompactExerciseName.key($0.name) == CompactExerciseName.key("Overhead SA Cable Extension") }) else { throw ClusterRevisionError.invalidState }
            let exercise = Exercise(id: Program.singleArmOverheadID, name: "Overhead SA Cable Extension", primaryMuscle: .triceps, type: .isolation, equipment: .cable)
            modelContext.insert(exercise); catalog.append(exercise)
        }
        if !catalog.contains(where: { $0.id == Program.hammerCurlID }) {
            guard !catalog.contains(where: { $0.name.localizedCaseInsensitiveContains("hammer curl") }) else { throw ClusterRevisionError.invalidState }
            let exercise = Exercise(id: Program.hammerCurlID, name: "Seated DB Hammer Curl", primaryMuscle: .biceps, type: .isolation, equipment: .dumbbell,
                notes: "Seated with nearly upright back support; no preacher pad. Neutral grip, upper arms beside torso, comfortable elbow extension. Log weight per dumbbell and reps per side.")
            modelContext.insert(exercise); catalog.append(exercise)
        }
        return catalog
    }
}
extension BootstrapDataService {
    static let syncedArmsRevisionMarker = "clustered-program-revision-2026-09-19-v8"

    @MainActor
    static func applySyncedArmsRevisionWithFreshBackup(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot) throws -> SideDeltApplicationResult {
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == syncedArmsRevisionMarker }) {
            return SideDeltApplicationResult(revision: try prepareSyncedArmsRevision(modelContext: modelContext), backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-synced-arms-\(UUID().uuidString).sqlite")
        do {
            try snapshot(storeURL, backup)
            guard StoreBackupService.isValidSnapshot(at: backup) else { throw SeatedShrugBackupError.verificationFailed }
        } catch { try? FileManager.default.removeItem(at: backup); throw error }
        return SideDeltApplicationResult(revision: try prepareSyncedArmsRevision(modelContext: modelContext, backupConfirmed: true), backupURL: backup)
    }

    @discardableResult
    static func prepareSyncedArmsRevision(modelContext: ModelContext, backupConfirmed: Bool = false) throws -> ClusteredProgramRolloutResult {
        typealias Program = FixedCycleClusterProgramService
        guard !modelContext.hasChanges else { throw ClusterRevisionError.pendingChanges }
        do {
            let markers = try modelContext.fetch(FetchDescriptor<TrainingPreference>())
            let templates = try modelContext.fetch(FetchDescriptor<CycleTemplate>())
            let cycles = try modelContext.fetch(FetchDescriptor<ActiveCycleInstance>())
            let states = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
            if let marker = markers.first(where: { $0.key == syncedArmsRevisionMarker }) {
                let ids = marker.modeRawValue.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
                guard ids.count == 2, let template = templates.first(where: { $0.id == ids[0] }), Program.isSyncedArmsTemplate(template),
                      cycles.contains(where: { $0.id == ids[1] && $0.templateId == ids[0] }) else { throw ClusterRevisionError.invalidState }
                try validateSyncedArmsStates(states.filter { $0.templateId == ids[0] && $0.cycleInstanceId == ids[1] && $0.programVersionID == Program.syncedArmsVersionID })
                return ClusteredProgramRolloutResult(templateId: ids[0], cycleId: ids[1], didApply: false)
            }
            guard backupConfirmed else { throw ClusterRevisionError.backupRequired }
            guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
                  !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else { throw ClusterRevisionError.draftHasWork }
            let candidates = cycles.filter { c in templates.contains { $0.id == c.templateId && Program.isProgramTemplate($0) } }
            guard candidates.count == 1, let cycle = candidates.first, let old = templates.first(where: { $0.id == cycle.templateId }),
                  Program.versionID(for: old) == Program.balancedVersionID,
                  !templates.contains(where: { $0.name == Program.syncedArmsTemplateName || Program.versionNumber(for: $0) == 8 }),
                  !states.contains(where: { $0.programVersionID == Program.syncedArmsVersionID }) else { throw ClusterRevisionError.invalidState }
            let oldStates = states.filter { $0.templateId == old.id && $0.cycleInstanceId == cycle.id && $0.programVersionID == Program.balancedVersionID }
            try validateSyncedArmsStates(oldStates)
            let catalog = try ensureSyncedArmExercises(modelContext: modelContext, recovery: false)
            let template = try Program.makeSyncedArmsTemplate(exercises: catalog, preserving: old,
                preferences: modelContext.fetch(FetchDescriptor<ClusterExercisePreference>()).filter { $0.programVersionID == Program.balancedVersionID }, cycleId: cycle.id)
            modelContext.insert(template)
            for state in oldStates {
                modelContext.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id,
                    programVersionID: Program.syncedArmsVersionID, clusterID: state.clusterID, positionIndex: state.positionIndex,
                    updatedAt: state.updatedAt, lastCompletedOccurrenceID: state.lastCompletedOccurrenceID, isDerived: state.isDerived))
            }
            cycle.templateId = template.id
            let value = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            modelContext.insert(TrainingPreference(key: syncedArmsRevisionMarker, modeRawValue: value))
            markers.first(where: { $0.key == clusteredProgramRolloutMarkerKey })?.modeRawValue = value
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return ClusteredProgramRolloutResult(templateId: template.id, cycleId: cycle.id, didApply: true)
        } catch { modelContext.rollback(); throw error }
    }

    private static func validateSyncedArmsStates(_ states: [ClusterRotationState]) throws {
        guard states.count == 3, Set(states.map(\.clusterID)) == Set(FixedCycleClusterProgramService.Cluster.allCases.map(\.rawValue)),
              states.allSatisfy({ $0.positionIndex >= 0 }) else { throw ClusterRevisionError.invalidState }
    }
}
