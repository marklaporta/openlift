import Foundation
import SwiftData

/// A revision file is inert until its freshly generated preview is explicitly applied.
struct ProgramRevisionPackage: Codable, Equatable {
    struct Carry: Codable, Equatable {
        let targetDay: Int
        let targetSlot: Int
        let sourceDay: Int
        let sourceSlot: Int
    }
    struct Counter: Codable, Equatable {
        let clusterID: String
        let expectedPosition: Int
        let resumePosition: Int
    }
    let formatVersion: Int
    let sourceProgramVersionID: String
    let definition: ClusterProgramDefinition
    let counters: [Counter]
    let carry: [Carry]
}

enum ProgramImportService {
    typealias Program = FixedCycleClusterProgramService
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
    }
    struct Preview {
        let package: ProgramRevisionPackage
        let fingerprint: String
        let changes: [String]
        let upcoming: [String]
        let blockedByDraft: Bool
    }
    struct Result { let didApply: Bool; let backupURL: URL? }

    static func decode(_ data: Data) throws -> ProgramRevisionPackage {
        guard data.count <= 262144 else { throw Failure.invalid("Program file exceeds 256 KB.") }
        let object = try JSONSerialization.jsonObject(with: data)
        func fields(_ value: Any?, _ allowed: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw Failure.invalid("Unknown fields or unsupported mechanics in the revision file.") }
            return object
        }
        let root = try fields(object, ["formatVersion", "sourceProgramVersionID", "definition", "counters", "carry"])
        let definition = try fields(root["definition"], ["formatVersion", "programVersionID", "templateName", "identityKey", "exercises", "clusters"])
        for cluster in definition["clusters"] as? [Any] ?? [] {
            let item = try fields(cluster, ["id", "steps"])
            for step in item["steps"] as? [Any] ?? [] {
                let step = try fields(step, ["templatePosition", "label", "slots"])
                for slot in step["slots"] as? [Any] ?? [] {
                    let slot = try fields(slot, ["muscle", "exercise", "defaultSetCount", "progression"])
                    _ = try fields(slot["progression"], ["key", "appendExerciseID", "exerciseAliases"])
                }
            }
        }
        for reference in (definition["exercises"] as? [String: Any] ?? [:]).values {
            _ = try fields(reference, ["candidates", "setupSource"])
        }
        for counter in root["counters"] as? [Any] ?? [] { _ = try fields(counter, ["clusterID", "expectedPosition", "resumePosition"]) }
        for carry in root["carry"] as? [Any] ?? [] { _ = try fields(carry, ["targetDay", "targetSlot", "sourceDay", "sourceSlot"]) }
        let package = try JSONDecoder().decode(ProgramRevisionPackage.self, from: data)
        guard package.formatVersion == 1 else { throw Failure.invalid("Unsupported revision file format.") }
        try package.definition.validateImportedShape()
        return package
    }

    @MainActor
    static func preview(_ package: ProgramRevisionPackage, context: ModelContext) throws -> Preview {
        guard !context.hasChanges else { throw Failure.invalid("Save pending edits before previewing a program update.") }
        try package.definition.validateImportedShape()
        guard package.formatVersion == 1 else { throw Failure.invalid("Unsupported revision file format.") }
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard cycles.count == 1, let cycle = cycles.first,
              let source = templates.first(where: { $0.id == cycle.templateId }), Program.isProgramTemplate(source), Program.versionNumber(for: source) >= 8,
              Program.versionID(for: source) == package.sourceProgramVersionID,
              package.definition.versionNumber > Program.versionNumber(for: source),
              !templates.contains(where: { Program.versionID(for: $0) == package.definition.programVersionID || $0.name == package.definition.templateName })
        else { throw Failure.invalid("The revision does not match the active program, or its version already exists.") }
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let preferences = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>()).filter {
            $0.cycleInstanceId == cycle.id && $0.templateId == source.id && $0.programVersionID == package.sourceProgramVersionID
        }
        guard states.count == 3, Set(states.map(\.clusterID)).count == 3,
              package.counters.count == 3, Set(package.counters.map(\.clusterID)) == Set(Program.Cluster.allCases.map(\.rawValue)),
              package.counters.allSatisfy({ mapping in
                  states.contains { $0.clusterID == mapping.clusterID && $0.positionIndex == mapping.expectedPosition }
                    && mapping.resumePosition == mapping.expectedPosition && mapping.resumePosition >= 0
              }) else { throw Failure.invalid("Rotation positions changed or the transition attempts to reset a raw counter. Refresh the revision.") }
        let target = try package.definition.makeRecoveryTemplate(exercises: catalog)
        var sources: [String: Program.ResolvedSlot] = [:]
        var sourceProgressions: [String: ClusterProgramDefinition.Progression] = [:]
        for cluster in Program.Cluster.allCases {
            let scratch = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: source.id, programVersionID: package.sourceProgramVersionID)
            for step in 0..<Program.rotationLength(cluster, version: package.sourceProgramVersionID, definition: ClusterProgramDefinition.embedded(in: source)) {
                scratch.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
                let selection = try Program.selection(cluster: cluster, template: source, cycleInstanceId: cycle.id, states: scratch)
                for item in Program.resolvedSlots(selection: selection, sessionId: UUID(), preferences: preferences, overrides: []) {
                    let address = "\(selection.day.position):\(item.slot.position)"
                    sources[address] = item
                    sourceProgressions[address] = retainedProgression(selection: selection, item: item)
                }
            }
        }
        let carryKeys = package.carry.map { "\($0.targetDay):\($0.targetSlot)" }
        guard Set(carryKeys).count == carryKeys.count else { throw Failure.invalid("Duplicate progression transition targets.") }
        let targetKeys = Set(target.days.flatMap { day in day.slots.map { "\(day.position):\($0.position)" } })
        guard Set(carryKeys).isSubset(of: targetKeys) else { throw Failure.invalid("A progression transition names an unknown target slot.") }
        var changes: [String] = []
        var identities: [String: UUID] = [:]
        for cluster in package.definition.clusters {
            for step in cluster.steps {
                for (position, slot) in step.slots.enumerated() {
                    guard let exercise = package.definition.exercises[slot.exercise]?.resolve(in: catalog), exercise.isActive else {
                        throw Failure.invalid("A referenced exercise is missing or inactive.")
                    }
                    let key = slot.progression.resolve(exerciseID: exercise.id)
                    if let mapping = package.carry.first(where: { $0.targetDay == step.templatePosition && $0.targetSlot == position }) {
                        guard let old = sources["\(mapping.sourceDay):\(mapping.sourceSlot)"], old.exerciseId == exercise.id, old.progressionKey == key,
                              sourceProgressions["\(mapping.sourceDay):\(mapping.sourceSlot)"] == slot.progression else {
                            throw Failure.invalid("Carried progression must match the source's effective exercise and complete identity rule exactly.")
                        }
                        if mapping.sourceDay != mapping.targetDay || mapping.sourceSlot != mapping.targetSlot {
                            let oldLabel = source.days.first { $0.position == mapping.sourceDay }?.label ?? "Previous step"
                            changes.append("\(exercise.name): \(oldLabel), slot \(mapping.sourceSlot + 1) → \(step.label), slot \(position + 1).")
                        }
                        if old.slot.defaultSetCount != slot.defaultSetCount {
                            changes.append("\(exercise.name): starting sets \(old.slot.defaultSetCount) → \(slot.defaultSetCount); previous completed set counts still carry forward.")
                        }
                    } else {
                        if let previous = identities[key], previous != exercise.id { throw Failure.invalid("A new progression identity cannot represent different exercises.") }
                        identities[key] = exercise.id
                        guard slot.progression.key.hasPrefix(package.definition.programVersionID + "."),
                              slot.progression.exerciseAliases.allSatisfy({ id, key in catalog.contains { $0.id == id } && key.hasPrefix(package.definition.programVersionID + ".") }),
                              !sources.values.contains(where: { $0.progressionKey == key }) else {
                            throw Failure.invalid("Every retained identity needs an explicit source mapping; new identities must use the new version namespace.")
                        }
                        changes.append("\(exercise.name): new progression identity (no carried targets).")
                    }
                }
            }
        }
        let retainedAddresses = Set(package.carry.map { "\($0.sourceDay):\($0.sourceSlot)" })
        for (address, item) in sources.sorted(by: { $0.key < $1.key }) where !retainedAddresses.contains(address) {
            let name = catalog.first { $0.id == item.exerciseId }?.name ?? "Exercise"
            changes.append("\(name), source slot \(address): removed from this position or assigned new progression.")
        }
        var upcoming: [String] = []
        for cluster in package.definition.clusters {
            let position = package.counters.first { $0.clusterID == cluster.id }!.resumePosition
            let sourceState = states.first { $0.clusterID == cluster.id }!
            let oldSelection = try Program.selection(cluster: Program.Cluster(rawValue: cluster.id)!, template: source, cycleInstanceId: cycle.id, states: states)
            let oldNames = Program.resolvedSlots(selection: oldSelection, sessionId: UUID(), preferences: preferences, overrides: []).compactMap { item in catalog.first { $0.id == item.exerciseId }?.name }.joined(separator: ", ")
            let step = cluster.steps[position % cluster.steps.count]
            let names = step.slots.compactMap { package.definition.exercises[$0.exercise]?.resolve(in: catalog)?.name }.joined(separator: ", ")
            upcoming.append("\(Program.Cluster(rawValue: cluster.id)!.displayName), counter \(sourceState.positionIndex) → \(position):\nNow: \(oldNames)\nNext: \(names)")
            let oldLength = Program.rotationLength(Program.Cluster(rawValue: cluster.id)!, version: package.sourceProgramVersionID, definition: ClusterProgramDefinition.embedded(in: source))
            changes.append("\(Program.Cluster(rawValue: cluster.id)!.displayName): \(oldLength) → \(cluster.steps.count) rotation steps.")
        }
        // Fingerprint all source selections, prescriptions, pointers and setup text, not only the package.
        let sourceRows = sources.sorted { $0.key < $1.key }.map { "\($0.key)|\($0.value.exerciseId)|\($0.value.progressionKey)|\($0.value.slot.defaultSetCount)" }
        let catalogRows = catalog.sorted { $0.id.uuidString < $1.id.uuidString }.map { "\($0.id)|\($0.name)|\($0.notes)|\($0.isActive)" }
        let drafts = try context.fetch(FetchDescriptor<Session>()).filter { $0.status == .draft }.map { $0.id.uuidString }
            + context.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).filter { $0.status == .draft }.map { $0.id.uuidString }
        let fingerprint = ([cycle.id.uuidString, source.id.uuidString, source.name] + source.rotationPools.map(\.key).sorted() + source.days.sorted { $0.position < $1.position }.map { "\($0.position)|\($0.label)" } + sourceRows + catalogRows + drafts.sorted()
            + states.sorted { $0.clusterID < $1.clusterID }.map { "\($0.clusterID)|\($0.positionIndex)" }).joined(separator: "\n")
        return Preview(package: package, fingerprint: fingerprint, changes: changes, upcoming: upcoming, blockedByDraft: !drafts.isEmpty)
    }

    @MainActor
    static func apply(_ preview: Preview, context: ModelContext, backupDirectory: URL? = nil,
                      snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot,
                      save: (ModelContext) throws -> Void = { try $0.save() },
                      beforeSave: (CycleTemplate, URL) throws -> Void = { _, _ in }) throws -> Result {
        guard !context.hasChanges else { throw Failure.invalid("Save pending edits before applying a revision.") }
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard cycles.count == 1 else { throw Failure.invalid("The active clustered program is ambiguous.") }
        if let active = cycles.first, let existing = templates.first(where: { $0.id == active.templateId }),
           ClusterProgramDefinition.embedded(in: existing) == preview.package.definition { return Result(didApply: false, backupURL: nil) }
        let current = try self.preview(preview.package, context: context)
        guard current.fingerprint == preview.fingerprint else { throw Failure.invalid("The workout or program changed after preview. Import again to review a fresh preview.") }
        guard !current.blockedByDraft else { throw Failure.invalid("Finish your current workout before applying this program update. Your draft has not been changed.") }
        guard let storeURL = context.container.configurations.first?.url, FileManager.default.fileExists(atPath: storeURL.path) else {
            throw Failure.invalid("Activation requires a persistent store and a verified backup.")
        }
        let root = try backupDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backup = root.appendingPathComponent("before-program-import-\(UUID().uuidString).sqlite")
        try snapshot(storeURL, backup)
        guard StoreBackupService.isValidSnapshot(at: backup) else { throw Failure.invalid("The pre-update backup did not pass integrity verification.") }
        let cycle = cycles[0]
        let originalID = cycle.templateId
        let markers = try context.fetch(FetchDescriptor<TrainingPreference>())
        let rollout = markers.first { $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey }
        let oldMarker = rollout?.modeRawValue
        do {
            let template = try preview.package.definition.makeRecoveryTemplate(exercises: context.fetch(FetchDescriptor<Exercise>()))
            context.insert(template)
            for mapping in preview.package.counters {
                context.insert(ClusterRotationState(cycleInstanceId: cycle.id, templateId: template.id, programVersionID: preview.package.definition.programVersionID, clusterID: mapping.clusterID, positionIndex: mapping.resumePosition))
            }
            cycle.templateId = template.id
            rollout?.modeRawValue = "\(template.id.uuidString)|\(cycle.id.uuidString)"
            try beforeSave(template, backup)
            try save(context)
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
            return Result(didApply: true, backupURL: backup)
        } catch {
            context.rollback()
            cycle.templateId = originalID
            if let oldMarker { rollout?.modeRawValue = oldMarker }
            context.rollback()
            throw error
        }
    }
}

extension ProgramImportService {
    static func retainedProgression(selection: Program.Selection, item: Program.ResolvedSlot) -> ClusterProgramDefinition.Progression {
        let definition = selection.definition ?? (selection.programVersionID == Program.syncedArmsVersionID ? BundledClusterPrograms.v8 : nil)
        return definition?.step(clusterID: selection.cluster.rawValue, counter: selection.effectiveStep)?.slots[item.slot.position].progression
            ?? .init(key: item.progressionKey)
    }

    /// Export an editable, identity-preserving revision starter from effective live selections.
    @MainActor
    static func revisionStarter(context: ModelContext) throws -> ProgramRevisionPackage {
        guard !context.hasChanges else { throw Failure.invalid("Save pending edits before exporting a revision starter.") }
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>()).filter { cycle in
            templates.contains { $0.id == cycle.templateId && Program.isProgramTemplate($0) }
        }
        guard cycles.count == 1, let cycle = cycles.first, let source = templates.first(where: { $0.id == cycle.templateId }), Program.isProgramTemplate(source), Program.versionNumber(for: source) >= 8 else {
            throw Failure.invalid("An active clustered program is required.")
        }
        let version = Program.versionID(for: source)
        let catalog = try context.fetch(FetchDescriptor<Exercise>())
        let next = max(9, Program.versionNumber(for: source) + 1)
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        let preferences = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        var exercises: [String: ClusterProgramDefinition.ExerciseReference] = [:]
        var clusters: [ClusterProgramDefinition.Cluster] = []
        var carry: [ProgramRevisionPackage.Carry] = []
        var counters: [ProgramRevisionPackage.Counter] = []
        for cluster in Program.Cluster.allCases {
            let selection = try Program.selection(cluster: cluster, template: source, cycleInstanceId: cycle.id, states: states)
            counters.append(.init(clusterID: cluster.rawValue, expectedPosition: selection.absoluteStep, resumePosition: selection.absoluteStep))
            var steps: [ClusterProgramDefinition.Step] = []
            let scratch = Program.makeRotationStates(cycleInstanceId: cycle.id, templateId: source.id, programVersionID: version)
            for step in 0..<Program.rotationLength(cluster, version: version, definition: ClusterProgramDefinition.embedded(in: source)) {
                scratch.first { $0.clusterID == cluster.rawValue }!.positionIndex = step
                let selected = try Program.selection(cluster: cluster, template: source, cycleInstanceId: cycle.id, states: scratch)
                let slots = Program.resolvedSlots(selection: selected, sessionId: UUID(), preferences: preferences, overrides: []).map { item in
                    let label = catalog.first { $0.id == item.exerciseId }?.name ?? "Exercise"
                    let name = "\(label) [\(item.exerciseId.uuidString.lowercased())]"
                    exercises[name] = .init(candidates: [.id(item.exerciseId)], setupSource: .exerciseCatalog)
                    carry.append(.init(targetDay: selected.day.position, targetSlot: item.slot.position, sourceDay: selected.day.position, sourceSlot: item.slot.position))
                    return ClusterProgramDefinition.Slot(muscle: item.slot.muscle, exercise: name, defaultSetCount: item.slot.defaultSetCount, progression: retainedProgression(selection: selected, item: item))
                }
                steps.append(.init(templatePosition: selected.day.position, label: selected.day.label, slots: slots))
            }
            clusters.append(.init(id: cluster.rawValue, steps: steps))
        }
        return ProgramRevisionPackage(formatVersion: 1, sourceProgramVersionID: version,
            definition: .init(formatVersion: 1, programVersionID: "\(Program.programIdentifier).v\(next)", templateName: "Clustered Hypertrophy v\(next)", identityKey: "openlift_clustered_hypertrophy_v\(next)", exercises: exercises, clusters: clusters), counters: counters, carry: carry)
    }
}
