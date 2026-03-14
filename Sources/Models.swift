import Foundation
import SwiftData

enum MuscleGroup: String, Codable, CaseIterable {
    case chest
    case back
    case quads
    case hamstrings
    case biceps
    case triceps
    case sideDelts
}

enum ExerciseType: String, Codable {
    case compound
    case isolation
}

enum EquipmentType: String, Codable {
    case machine
    case barbell
    case dumbbell
    case cable
    case bodyweight
}

enum SessionStatus: String, Codable {
    case draft
    case completed
}

enum ExportStatus: String, Codable {
    case pending
    case success
    case failed
}

enum RotationPoolKey: String, Codable, CaseIterable {
    case quadsCompound = "quads_compound"
}

@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var name: String
    var primaryMuscle: MuscleGroup
    var type: ExerciseType
    var equipment: EquipmentType
    var notes: String
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        primaryMuscle: MuscleGroup,
        type: ExerciseType,
        equipment: EquipmentType,
        notes: String = "",
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.type = type
        self.equipment = equipment
        self.notes = notes
        self.isActive = isActive
    }

    func validate() throws {
        try OpenLiftValidator.validate(self)
    }
}

@Model
final class CycleSlot {
    var position: Int = 0
    var muscle: MuscleGroup
    var exerciseId: UUID
    var defaultSetCount: Int

    init(position: Int = 0, muscle: MuscleGroup, exerciseId: UUID, defaultSetCount: Int = 3) {
        self.position = position
        self.muscle = muscle
        self.exerciseId = exerciseId
        self.defaultSetCount = defaultSetCount
    }
}

@Model
final class CycleDay {
    var position: Int = 0
    var label: String
    @Relationship(deleteRule: .cascade) var slots: [CycleSlot]

    init(label: String, slots: [CycleSlot], position: Int = 0) {
        self.position = position
        self.label = label
        self.slots = slots
    }
}

@Model
final class RotationPoolEntry {
    var exerciseId: UUID

    init(exerciseId: UUID) {
        self.exerciseId = exerciseId
    }
}

@Model
final class RotationPool {
    var key: String
    @Relationship(deleteRule: .cascade) var entries: [RotationPoolEntry]

    init(key: String, entries: [RotationPoolEntry]) {
        self.key = key
        self.entries = entries
    }
}

@Model
final class CycleTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    @Relationship(deleteRule: .cascade) var days: [CycleDay]
    @Relationship(deleteRule: .cascade) var rotationPools: [RotationPool]

    init(
        id: UUID = UUID(),
        name: String,
        days: [CycleDay],
        rotationPools: [RotationPool] = []
    ) {
        self.id = id
        self.name = name
        self.days = days
        self.rotationPools = rotationPools
    }

    func validate(exercisesById: [UUID: Exercise]) throws {
        try OpenLiftValidator.validate(self, exercisesById: exercisesById)
    }
}

@Model
final class RotationIndex {
    var key: String
    var value: Int

    init(key: String, value: Int) {
        self.key = key
        self.value = value
    }
}

@Model
final class ActiveCycleInstance {
    @Attribute(.unique) var id: UUID
    var templateId: UUID
    var currentDayIndex: Int
    @Relationship(deleteRule: .cascade) var rotationIndices: [RotationIndex]

    init(
        id: UUID = UUID(),
        templateId: UUID,
        currentDayIndex: Int = 0,
        rotationIndices: [RotationIndex] = [RotationIndex(key: RotationPoolKey.quadsCompound.rawValue, value: 0)]
    ) {
        self.id = id
        self.templateId = templateId
        self.currentDayIndex = currentDayIndex
        self.rotationIndices = rotationIndices
    }

    func validate(template: CycleTemplate) throws {
        try OpenLiftValidator.validate(self, template: template)
    }
}

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var cycleInstanceId: UUID
    var cycleDayIndex: Int
    var cycleNameSnapshot: String?
    var dayLabelSnapshot: String?
    var createdAt: Date
    var finishedAt: Date?
    var status: SessionStatus
    var exportStatus: ExportStatus

    init(
        id: UUID = UUID(),
        cycleInstanceId: UUID,
        cycleDayIndex: Int,
        cycleNameSnapshot: String? = nil,
        dayLabelSnapshot: String? = nil,
        createdAt: Date = .now,
        finishedAt: Date? = nil,
        status: SessionStatus = .draft,
        exportStatus: ExportStatus = .pending
    ) {
        self.id = id
        self.cycleInstanceId = cycleInstanceId
        self.cycleDayIndex = cycleDayIndex
        self.cycleNameSnapshot = cycleNameSnapshot
        self.dayLabelSnapshot = dayLabelSnapshot
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.exportStatus = exportStatus
    }

    func validate() throws {
        try OpenLiftValidator.validate(self)
    }
}

@Model
final class SetEntry {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var exerciseId: UUID
    var setIndex: Int
    var weight: Double
    var reps: Int
    var isLocked: Bool = false

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        exerciseId: UUID,
        setIndex: Int,
        weight: Double,
        reps: Int,
        isLocked: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.weight = weight
        self.reps = reps
        self.isLocked = isLocked
    }

    func validate() throws {
        try OpenLiftValidator.validate(self)
    }
}

@Model
final class SessionSlotOverride {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var slotPosition: Int
    var exerciseId: UUID

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        slotPosition: Int,
        exerciseId: UUID
    ) {
        self.id = id
        self.sessionId = sessionId
        self.slotPosition = slotPosition
        self.exerciseId = exerciseId
    }
}
