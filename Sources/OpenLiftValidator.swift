import Foundation

enum OpenLiftValidationError: LocalizedError {
    case emptyName(entity: String)
    case emptyDays
    case emptyDayLabel
    case invalidDefaultSetCount(dayLabel: String, muscle: MuscleGroup, count: Int)
    case exerciseNotFound(exerciseId: UUID)
    case exerciseMuscleMismatch(dayLabel: String, exerciseId: UUID, expected: MuscleGroup, actual: MuscleGroup)
    case invalidRotationPoolKey(key: String)
    case rotationPoolExerciseNotCompoundQuads(exerciseId: UUID)
    case invalidCurrentDayIndex(index: Int, dayCount: Int)
    case invalidRotationIndex(key: String, value: Int)
    case finishedAtRequiredForCompletedSession
    case finishedBeforeCreated
    case invalidCycleDayIndex(Int)
    case invalidSetIndex(Int)
    case invalidWeight(Double)
    case invalidReps(Int)

    var errorDescription: String? {
        switch self {
        case .emptyName(let entity): return "\(entity) name cannot be empty."
        case .emptyDays: return "Cycle template must include at least one day."
        case .emptyDayLabel: return "Cycle day label cannot be empty."
        case .invalidDefaultSetCount(let dayLabel, let muscle, let count):
            return "Day '\(dayLabel)' slot '\(muscle.rawValue)' has invalid set count \(count). Max is 3 in v1."
        case .exerciseNotFound(let exerciseId): return "Exercise \(exerciseId.uuidString) does not exist."
        case .exerciseMuscleMismatch(let dayLabel, let exerciseId, let expected, let actual):
            return "Day '\(dayLabel)' exercise \(exerciseId.uuidString) muscle mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
        case .invalidRotationPoolKey(let key): return "Rotation pool key '\(key)' is not supported."
        case .rotationPoolExerciseNotCompoundQuads(let exerciseId):
            return "Rotation pool exercise \(exerciseId.uuidString) must be a quads compound exercise."
        case .invalidCurrentDayIndex(let index, let dayCount):
            return "currentDayIndex \(index) out of bounds for \(dayCount) day(s)."
        case .invalidRotationIndex(let key, let value):
            return "rotation index for '\(key)' must be >= 0. Got \(value)."
        case .finishedAtRequiredForCompletedSession:
            return "Completed sessions must have finishedAt."
        case .finishedBeforeCreated:
            return "finishedAt cannot be earlier than createdAt."
        case .invalidCycleDayIndex(let index):
            return "cycleDayIndex must be >= 0. Got \(index)."
        case .invalidSetIndex(let index):
            return "setIndex must be >= 1. Got \(index)."
        case .invalidWeight(let weight):
            return "weight must be >= 0. Got \(weight)."
        case .invalidReps(let reps):
            return "reps must be >= 0. Got \(reps)."
        }
    }
}

enum OpenLiftValidator {
    static func validate(_ exercise: Exercise) throws {
        if exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenLiftValidationError.emptyName(entity: "Exercise")
        }
    }

    static func validate(_ template: CycleTemplate, exercisesById: [UUID: Exercise]) throws {
        if template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenLiftValidationError.emptyName(entity: "CycleTemplate")
        }
        if template.days.isEmpty {
            throw OpenLiftValidationError.emptyDays
        }

        for day in template.days {
            if day.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OpenLiftValidationError.emptyDayLabel
            }

            for slot in day.slots {
                if slot.defaultSetCount < 1 || slot.defaultSetCount > 3 {
                    throw OpenLiftValidationError.invalidDefaultSetCount(dayLabel: day.label, muscle: slot.muscle, count: slot.defaultSetCount)
                }

                guard let exercise = exercisesById[slot.exerciseId] else {
                    throw OpenLiftValidationError.exerciseNotFound(exerciseId: slot.exerciseId)
                }

                if exercise.primaryMuscle != slot.muscle {
                    throw OpenLiftValidationError.exerciseMuscleMismatch(
                        dayLabel: day.label,
                        exerciseId: exercise.id,
                        expected: slot.muscle,
                        actual: exercise.primaryMuscle
                    )
                }

            }
        }

        for pool in template.rotationPools {
            guard let key = RotationPoolKey(rawValue: pool.key) else {
                throw OpenLiftValidationError.invalidRotationPoolKey(key: pool.key)
            }

            switch key {
            case .quadsCompound:
                for entry in pool.entries {
                    guard let exercise = exercisesById[entry.exerciseId] else {
                        throw OpenLiftValidationError.exerciseNotFound(exerciseId: entry.exerciseId)
                    }
                    if !(exercise.primaryMuscle == .quads && exercise.type == .compound) {
                        throw OpenLiftValidationError.rotationPoolExerciseNotCompoundQuads(exerciseId: entry.exerciseId)
                    }
                }
            }
        }
    }

    static func validate(_ instance: ActiveCycleInstance, template: CycleTemplate) throws {
        if instance.currentDayIndex < 0 || instance.currentDayIndex >= template.days.count {
            throw OpenLiftValidationError.invalidCurrentDayIndex(index: instance.currentDayIndex, dayCount: template.days.count)
        }
        for index in instance.rotationIndices {
            if RotationPoolKey(rawValue: index.key) == nil {
                throw OpenLiftValidationError.invalidRotationPoolKey(key: index.key)
            }
            if index.value < 0 {
                throw OpenLiftValidationError.invalidRotationIndex(key: index.key, value: index.value)
            }
        }
    }

    static func validate(_ session: Session) throws {
        if session.cycleDayIndex < 0 {
            throw OpenLiftValidationError.invalidCycleDayIndex(session.cycleDayIndex)
        }
        if session.status == .completed && session.finishedAt == nil {
            throw OpenLiftValidationError.finishedAtRequiredForCompletedSession
        }
        if let finishedAt = session.finishedAt, finishedAt < session.createdAt {
            throw OpenLiftValidationError.finishedBeforeCreated
        }
    }

    static func validate(_ setEntry: SetEntry) throws {
        if setEntry.setIndex < 1 {
            throw OpenLiftValidationError.invalidSetIndex(setEntry.setIndex)
        }
        if setEntry.weight < 0 {
            throw OpenLiftValidationError.invalidWeight(setEntry.weight)
        }
        if setEntry.reps < 0 {
            throw OpenLiftValidationError.invalidReps(setEntry.reps)
        }
    }
}
