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
    case forearms
    case glutes
    case calves
    case abs
    case traps

    var displayName: String {
        switch self {
        // Preserve the legacy raw value for existing stores while presenting
        // the broader programming bucket used by Adaptive profiles.
        case .sideDelts: return "Shoulders"
        default: return rawValue.capitalized
        }
    }

    static let initialAdaptiveRankOrder: [MuscleGroup] = [
        .chest,
        .back,
        .triceps,
        .biceps,
        .sideDelts,
        .quads,
        .hamstrings,
        .forearms,
        .glutes,
        .calves
    ]
}

enum ExerciseType: String, Codable, CaseIterable {
    case compound
    case isolation
}

enum EquipmentType: String, Codable, CaseIterable {
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

enum TrainingMode: String, Codable, CaseIterable, Hashable {
    case rotation
    case adaptive

    var displayName: String {
        switch self {
        case .rotation:
            return "Fixed Cycle"
        case .adaptive:
            return "Adaptive Floating"
        }
    }
}

enum MovementDifficulty: String, Codable, CaseIterable, Hashable {
    case easy
    case moderate
    case hard

    var cost: Int {
        switch self {
        case .easy: return 1
        case .moderate: return 2
        case .hard: return 3
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

enum SorenessLevel: String, Codable, CaseIterable, Hashable {
    case none
    case mild
    case high

    var displayName: String { rawValue.capitalized }
}

enum ConnectiveTissuePainLevel: String, Codable, CaseIterable, Hashable {
    case none
    case caution
    case stop

    var displayName: String {
        switch self {
        case .none: return "None"
        case .caution: return "Caution"
        case .stop: return "Stop"
        }
    }
}

enum EagernessLevel: String, Codable, CaseIterable, Hashable {
    case eager
    case neutral
    case reluctant

    var displayName: String { rawValue.capitalized }
}

enum AdaptivePlanStatus: String, Codable, CaseIterable, Hashable {
    case proposed
    case frozen
    case inProgress
    case completed
}

enum ComplexFeedbackRating: String, Codable, CaseIterable, Hashable {
    case tooLittle
    case justRight
    case tooMuch
    case notSure
    case painProblem

    var displayName: String {
        switch self {
        case .tooLittle: return "Too little"
        case .justRight: return "Just right"
        case .tooMuch: return "Too much"
        case .notSure: return "Not sure"
        case .painProblem: return "Pain/problem"
        }
    }
}

enum AdaptiveOverrideKind: String, Codable, CaseIterable, Hashable {
    case addExercise
    case removeExercise
    case skipComplex
    case skipExercise
    case substituteExercise
    case painBlock
}

@Model
final class TrainingPreference {
    @Attribute(.unique) var key: String
    var modeRawValue: String

    init(
        key: String = TrainingModeService.activeModeKey,
        modeRawValue: String = TrainingMode.rotation.rawValue
    ) {
        self.key = key
        self.modeRawValue = modeRawValue
    }
}

@Model
final class AdaptiveMuscleRule {
    @Attribute(.unique) var id: UUID
    var muscle: MuscleGroup
    var priorityRank: Int
    var rollingSetFloor: Int
    var rollingWindowDays: Int
    var maxRecoveredDayGap: Int
    var maxExercisesPerExposure: Int
    var maxSetsPerExercise: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        muscle: MuscleGroup,
        priorityRank: Int,
        rollingSetFloor: Int,
        rollingWindowDays: Int,
        maxRecoveredDayGap: Int,
        maxExercisesPerExposure: Int,
        maxSetsPerExercise: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.muscle = muscle
        self.priorityRank = priorityRank
        self.rollingSetFloor = rollingSetFloor
        self.rollingWindowDays = rollingWindowDays
        self.maxRecoveredDayGap = maxRecoveredDayGap
        self.maxExercisesPerExposure = maxExercisesPerExposure
        self.maxSetsPerExercise = maxSetsPerExercise
        self.isEnabled = isEnabled
    }
}

@Model
final class AdaptiveComplexComponent {
    @Attribute(.unique) var id: UUID
    var position: Int
    var exerciseId: UUID
    var prescribedSetCount: Int
    var primaryMuscle: MuscleGroup
    var secondaryMuscle: MuscleGroup?
    var difficulty: MovementDifficulty

    init(
        id: UUID = UUID(),
        position: Int,
        exerciseId: UUID,
        prescribedSetCount: Int,
        primaryMuscle: MuscleGroup,
        secondaryMuscle: MuscleGroup? = nil,
        difficulty: MovementDifficulty
    ) {
        self.id = id
        self.position = position
        self.exerciseId = exerciseId
        self.prescribedSetCount = prescribedSetCount
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscle = secondaryMuscle
        self.difficulty = difficulty
    }
}

@Model
final class AdaptiveExerciseComplex {
    @Attribute(.unique) var id: UUID
    var definitionId: UUID
    var version: Int
    var name: String
    var position: Int
    var primaryMuscle: MuscleGroup
    var qualifiesForPrimaryFloor: Bool
    var isEnabled: Bool
    @Relationship(deleteRule: .cascade) var components: [AdaptiveComplexComponent]

    init(
        id: UUID = UUID(),
        definitionId: UUID = UUID(),
        version: Int,
        name: String,
        position: Int,
        primaryMuscle: MuscleGroup,
        qualifiesForPrimaryFloor: Bool,
        isEnabled: Bool = true,
        components: [AdaptiveComplexComponent]
    ) {
        self.id = id
        self.definitionId = definitionId
        self.version = version
        self.name = name
        self.position = position
        self.primaryMuscle = primaryMuscle
        self.qualifiesForPrimaryFloor = qualifiesForPrimaryFloor
        self.isEnabled = isEnabled
        self.components = components
    }
}

@Model
final class AdaptiveProgram {
    @Attribute(.unique) var id: UUID
    var lineageId: UUID
    var version: Int
    var name: String
    var createdAt: Date
    var isActiveVersion: Bool
    var isReviewedForUse: Bool
    var globalMaxMovements: Int
    var maxDifficultyCost: Int
    @Relationship(deleteRule: .cascade) var muscleRules: [AdaptiveMuscleRule]
    @Relationship(deleteRule: .cascade) var complexes: [AdaptiveExerciseComplex]

    init(
        id: UUID = UUID(),
        lineageId: UUID = UUID(),
        version: Int,
        name: String,
        createdAt: Date = .now,
        isActiveVersion: Bool = true,
        isReviewedForUse: Bool = false,
        globalMaxMovements: Int,
        maxDifficultyCost: Int,
        muscleRules: [AdaptiveMuscleRule],
        complexes: [AdaptiveExerciseComplex]
    ) {
        self.id = id
        self.lineageId = lineageId
        self.version = version
        self.name = name
        self.createdAt = createdAt
        self.isActiveVersion = isActiveVersion
        self.isReviewedForUse = isReviewedForUse
        self.globalMaxMovements = globalMaxMovements
        self.maxDifficultyCost = maxDifficultyCost
        self.muscleRules = muscleRules
        self.complexes = complexes
    }
}

@Model
final class AdaptiveReadinessResponse {
    @Attribute(.unique) var id: UUID
    var muscle: MuscleGroup
    var soreness: SorenessLevel
    var connectiveTissuePain: ConnectiveTissuePainLevel
    var eagerness: EagernessLevel

    init(
        id: UUID = UUID(),
        muscle: MuscleGroup,
        soreness: SorenessLevel,
        connectiveTissuePain: ConnectiveTissuePainLevel,
        eagerness: EagernessLevel
    ) {
        self.id = id
        self.muscle = muscle
        self.soreness = soreness
        self.connectiveTissuePain = connectiveTissuePain
        self.eagerness = eagerness
    }
}

@Model
final class DailyReadinessCheck {
    @Attribute(.unique) var id: UUID
    var localDateKey: String
    var timeZoneIdentifier: String
    var revision: Int
    var createdAt: Date
    var adaptiveProgramId: UUID
    var adaptiveProgramVersion: Int
    @Relationship(deleteRule: .cascade) var responses: [AdaptiveReadinessResponse]

    init(
        id: UUID = UUID(),
        localDateKey: String,
        timeZoneIdentifier: String,
        revision: Int,
        createdAt: Date = .now,
        adaptiveProgramId: UUID,
        adaptiveProgramVersion: Int,
        responses: [AdaptiveReadinessResponse]
    ) {
        self.id = id
        self.localDateKey = localDateKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.revision = revision
        self.createdAt = createdAt
        self.adaptiveProgramId = adaptiveProgramId
        self.adaptiveProgramVersion = adaptiveProgramVersion
        self.responses = responses
    }
}

@Model
final class PlannedExerciseSnapshot {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var occurrenceId: UUID
    var position: Int
    var exerciseId: UUID
    var exerciseName: String
    var primaryMuscle: MuscleGroup
    var secondaryMuscle: MuscleGroup?
    var difficulty: MovementDifficulty
    var prescribedSetCount: Int

    init(
        id: UUID = UUID(),
        occurrenceId: UUID = UUID(),
        position: Int,
        exerciseId: UUID,
        exerciseName: String,
        primaryMuscle: MuscleGroup,
        secondaryMuscle: MuscleGroup? = nil,
        difficulty: MovementDifficulty,
        prescribedSetCount: Int
    ) {
        self.id = id
        self.occurrenceId = occurrenceId
        self.position = position
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscle = secondaryMuscle
        self.difficulty = difficulty
        self.prescribedSetCount = prescribedSetCount
    }
}

@Model
final class PlannedComplexSnapshot {
    @Attribute(.unique) var id: UUID
    var sourceDefinitionId: UUID
    var sourceVersion: Int
    var position: Int
    var name: String
    var primaryMuscle: MuscleGroup
    var reasonCodes: [String]
    @Relationship(deleteRule: .cascade) var exercises: [PlannedExerciseSnapshot]

    init(
        id: UUID = UUID(),
        sourceDefinitionId: UUID,
        sourceVersion: Int,
        position: Int,
        name: String,
        primaryMuscle: MuscleGroup,
        reasonCodes: [String],
        exercises: [PlannedExerciseSnapshot]
    ) {
        self.id = id
        self.sourceDefinitionId = sourceDefinitionId
        self.sourceVersion = sourceVersion
        self.position = position
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.reasonCodes = reasonCodes
        self.exercises = exercises
    }
}

@Model
final class GeneratedWorkoutPlan {
    @Attribute(.unique) var id: UUID
    var localDateKey: String
    var timeZoneIdentifier: String
    var createdAt: Date
    var frozenAt: Date?
    var status: AdaptivePlanStatus
    var adaptiveProgramId: UUID
    var adaptiveProgramVersion: Int
    var readinessCheckId: UUID
    var plannerVersion: Int
    var reasonCodes: [String]
    var sessionId: UUID?
    @Relationship(deleteRule: .cascade) var complexes: [PlannedComplexSnapshot]

    init(
        id: UUID = UUID(),
        localDateKey: String,
        timeZoneIdentifier: String,
        createdAt: Date = .now,
        frozenAt: Date? = nil,
        status: AdaptivePlanStatus,
        adaptiveProgramId: UUID,
        adaptiveProgramVersion: Int,
        readinessCheckId: UUID,
        plannerVersion: Int,
        reasonCodes: [String],
        sessionId: UUID? = nil,
        complexes: [PlannedComplexSnapshot]
    ) {
        self.id = id
        self.localDateKey = localDateKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.frozenAt = frozenAt
        self.status = status
        self.adaptiveProgramId = adaptiveProgramId
        self.adaptiveProgramVersion = adaptiveProgramVersion
        self.readinessCheckId = readinessCheckId
        self.plannerVersion = plannerVersion
        self.reasonCodes = reasonCodes
        self.sessionId = sessionId
        self.complexes = complexes
    }
}

@Model
final class AdaptiveWorkoutSession {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var generatedPlanId: UUID
    var createdAt: Date
    var finishedAt: Date?
    var status: SessionStatus
    var exportStatus: ExportStatus

    init(
        id: UUID = UUID(),
        generatedPlanId: UUID,
        createdAt: Date = .now,
        finishedAt: Date? = nil,
        status: SessionStatus = .draft,
        exportStatus: ExportStatus = .pending
    ) {
        self.id = id
        self.generatedPlanId = generatedPlanId
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.exportStatus = exportStatus
    }
}

@Model
final class AdaptiveSetEntry {
    @Attribute(.unique) var id: UUID
    var adaptiveSessionId: UUID
    var occurrenceId: UUID
    var exerciseId: UUID
    var setIndex: Int
    var weight: Double
    var reps: Int
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        adaptiveSessionId: UUID,
        occurrenceId: UUID,
        exerciseId: UUID,
        setIndex: Int,
        weight: Double = 0,
        reps: Int = 0,
        isLocked: Bool = false
    ) {
        self.id = id
        self.adaptiveSessionId = adaptiveSessionId
        self.occurrenceId = occurrenceId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.weight = weight
        self.reps = reps
        self.isLocked = isLocked
    }
}

@Model
final class AdaptiveSetOccurrenceLink {
    @Attribute(.unique) var setEntryId: UUID
    var generatedPlanId: UUID
    var occurrenceId: UUID

    init(setEntryId: UUID, generatedPlanId: UUID, occurrenceId: UUID) {
        self.setEntryId = setEntryId
        self.generatedPlanId = generatedPlanId
        self.occurrenceId = occurrenceId
    }
}

@Model
final class ComplexFeedback {
    @Attribute(.unique) var id: UUID
    var generatedPlanId: UUID
    var plannedComplexId: UUID
    var rating: ComplexFeedbackRating
    var createdAt: Date

    init(
        id: UUID = UUID(),
        generatedPlanId: UUID,
        plannedComplexId: UUID,
        rating: ComplexFeedbackRating,
        createdAt: Date = .now
    ) {
        self.id = id
        self.generatedPlanId = generatedPlanId
        self.plannedComplexId = plannedComplexId
        self.rating = rating
        self.createdAt = createdAt
    }
}

@Model
final class AdHocExerciseFeedback {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var exerciseId: UUID
    var rating: ComplexFeedbackRating
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        exerciseId: UUID,
        rating: ComplexFeedbackRating,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.rating = rating
        self.createdAt = createdAt
    }
}

@Model
final class AdaptiveOverrideEvent {
    @Attribute(.unique) var id: UUID
    var generatedPlanId: UUID
    var plannedComplexId: UUID?
    var occurrenceId: UUID?
    var kind: AdaptiveOverrideKind
    var muscle: MuscleGroup?
    var originalExerciseId: UUID?
    var replacementExerciseId: UUID?
    var reasonCode: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        generatedPlanId: UUID,
        plannedComplexId: UUID? = nil,
        occurrenceId: UUID? = nil,
        kind: AdaptiveOverrideKind,
        muscle: MuscleGroup? = nil,
        originalExerciseId: UUID? = nil,
        replacementExerciseId: UUID? = nil,
        reasonCode: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.generatedPlanId = generatedPlanId
        self.plannedComplexId = plannedComplexId
        self.occurrenceId = occurrenceId
        self.kind = kind
        self.muscle = muscle
        self.originalExerciseId = originalExerciseId
        self.replacementExerciseId = replacementExerciseId
        self.reasonCode = reasonCode
        self.createdAt = createdAt
    }
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
