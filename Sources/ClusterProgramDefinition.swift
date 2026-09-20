import Foundation

/// Serializable program content, independent of SwiftData and historical revision procedures.
/// Existing templates and catalog notes are authoritative once materialized; this is not an activation.
struct ClusterProgramDefinition: Codable, Equatable {
    struct ExerciseReference: Codable, Equatable {
        enum Candidate: Codable, Equatable {
            case id(UUID)
            case name(String)
            case consolidatedRowName(String)
        }
        enum SetupSource: String, Codable { case exerciseCatalog }
        let candidates: [Candidate]
        let setupSource: SetupSource

        func resolve(in catalog: [Exercise]) -> Exercise? {
            for candidate in candidates {
                let found: Exercise?
                switch candidate {
                case .id(let id): found = catalog.first { $0.id == id }
                case .name(let name): found = CompactExerciseName.resolve(name, in: catalog)
                case .consolidatedRowName(let name):
                    found = CSDBRowIdentity.resolve(id: nil, name: name, exercises: catalog)
                        ?? CompactExerciseName.resolve(name, in: catalog)
                }
                if let found { return found }
            }
            return nil
        }
    }

    struct Progression: Codable, Equatable {
        /// A literal historical identity, or a namespace with the resolved exercise UUID appended.
        let key: String
        var appendExerciseID: Bool = false
        var exerciseAliases: [UUID: String] = [:]

        func resolve(exerciseID: UUID) -> String {
            exerciseAliases[exerciseID] ?? (key + (appendExerciseID ? exerciseID.uuidString.lowercased() : ""))
        }
    }

    struct Slot: Codable, Equatable {
        let muscle: MuscleGroup
        let exercise: String
        let defaultSetCount: Int
        let progression: Progression
    }
    struct Step: Codable, Equatable {
        let templatePosition: Int
        let label: String
        let slots: [Slot]
    }
    struct Cluster: Codable, Equatable {
        let id: String
        let steps: [Step]
    }

    let formatVersion: Int
    let programVersionID: String
    let templateName: String
    let identityKey: String
    let exercises: [String: ExerciseReference]
    let clusters: [Cluster]

    func cluster(_ id: String) -> Cluster? { clusters.first { $0.id == id } }
    func step(clusterID: String, counter: Int) -> Step? {
        guard let cluster = cluster(clusterID), !cluster.steps.isEmpty else { return nil }
        return cluster.steps[max(0, counter) % cluster.steps.count]
    }
    func progressionKey(clusterID: String, step: Int, slot: Int, exerciseID: UUID) -> String? {
        guard let selected = self.step(clusterID: clusterID, counter: step), selected.slots.indices.contains(slot) else { return nil }
        return selected.slots[slot].progression.resolve(exerciseID: exerciseID)
    }

    func validate() throws {
        let steps = clusters.flatMap(\.steps)
        guard formatVersion == 1, !programVersionID.isEmpty, !templateName.isEmpty, !identityKey.isEmpty,
              !clusters.isEmpty, Set(clusters.map(\.id)).count == clusters.count,
              clusters.allSatisfy({ !$0.id.isEmpty && !$0.steps.isEmpty }),
              Set(steps.map(\.templatePosition)).count == steps.count,
              steps.allSatisfy({ $0.templatePosition >= 0 && !$0.label.isEmpty && !$0.slots.isEmpty }),
              steps.flatMap(\.slots).allSatisfy({ slot in
                  slot.defaultSetCount > 0 && !slot.progression.key.isEmpty
                    && !(exercises[slot.exercise]?.candidates.isEmpty ?? true)
                    && slot.progression.exerciseAliases.values.allSatisfy { !$0.isEmpty }
              }) else { throw FixedCycleClusterProgramService.ProgramError.invalidClusterContext }
    }

    /// Match structure only: durable exercise choices and literal fallback counts may differ.
    func matches(_ template: CycleTemplate) -> Bool {
        let expected = clusters.flatMap(\.steps)
        guard template.rotationPools.contains(where: { $0.key == identityKey && $0.entries.isEmpty }),
              template.days.count == expected.count,
              Set(template.days.map(\.position)) == Set(expected.map(\.templatePosition)) else { return false }
        return expected.allSatisfy { step in
            guard let day = template.days.first(where: { $0.position == step.templatePosition }) else { return false }
            let slots = CycleOrdering.sortedSlots(day.slots)
            return day.label == step.label && slots.count == step.slots.count && slots.enumerated().allSatisfy {
                $0.element.position == $0.offset && $0.element.muscle == step.slots[$0.offset].muscle
                    && $0.element.defaultSetCount > 0
            }
        }
    }

    /// Only recovery creates a template here. Loading a definition never writes the live store.
    func makeRecoveryTemplate(exercises catalog: [Exercise]) throws -> CycleTemplate {
        try validate()
        let days = try clusters.flatMap(\.steps).map { step in
            let slots = try step.slots.enumerated().map { position, slot in
                guard let exercise = exercises[slot.exercise]?.resolve(in: catalog) else {
                    throw FixedCycleClusterProgramService.ProgramError.requiredExerciseMissing(slot.exercise)
                }
                return CycleSlot(position: position, muscle: slot.muscle, exerciseId: exercise.id, defaultSetCount: slot.defaultSetCount)
            }
            return CycleDay(label: step.label, slots: slots, position: step.templatePosition)
        }
        let template = CycleTemplate(name: templateName, days: days, rotationPools: [RotationPool(key: identityKey, entries: [])])
        try template.validate(exercisesById: Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) }))
        try FixedCycleClusterProgramService.validatePersistentExercisePreferences(template: template, exerciseIDsByPreferenceKey: [:])
        return template
    }
}
