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
        .quads,
        .hamstrings,
        .triceps,
        .biceps,
        .sideDelts
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

    var supportsResistanceProfile: Bool {
        self == .cable
    }
}

enum ResistanceSource: String, Codable, CaseIterable, Hashable {
    case weightStack = "weight_stack"
    case voltra

    var displayName: String {
        switch self {
        case .weightStack: return "Weight Stack"
        case .voltra: return "VOLTRA"
        }
    }
}

enum VOLTRAChainType: String, Codable, CaseIterable, Hashable {
    case none
    case chains
    case inverseChains = "inverse_chains"

    var displayName: String {
        switch self {
        case .none: return "No Chains"
        case .chains: return "Chains"
        case .inverseChains: return "Inverse Chains"
        }
    }
}

enum ResistanceProfileWorkoutKind: String, Codable, CaseIterable, Hashable {
    case fixed
    case adHoc = "ad_hoc"
    case adaptive
}

/// Canonical raw resistance settings for one performed exercise occurrence.
/// A missing row means the historical resistance profile is unknown.
@Model
final class ExerciseResistanceProfile {
    @Attribute(.unique) var id: UUID
    var workoutKind: ResistanceProfileWorkoutKind
    var sessionId: UUID
    var exerciseId: UUID
    /// Adaptive has a durable occurrence ID. Fixed/ad-hoc currently identify
    /// an occurrence by session + exercise and therefore leave this nil.
    var occurrenceId: UUID?
    var resistanceSource: ResistanceSource
    var chainType: VOLTRAChainType?
    var chainPercent: Int?
    var eccentricPercent: Int?
    var frozenAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workoutKind: ResistanceProfileWorkoutKind,
        sessionId: UUID,
        exerciseId: UUID,
        occurrenceId: UUID? = nil,
        resistanceSource: ResistanceSource,
        chainType: VOLTRAChainType? = nil,
        chainPercent: Int? = nil,
        eccentricPercent: Int? = nil,
        frozenAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.workoutKind = workoutKind
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.occurrenceId = occurrenceId
        self.resistanceSource = resistanceSource
        self.chainType = chainType
        self.chainPercent = chainPercent
        self.eccentricPercent = eccentricPercent
        self.frozenAt = frozenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum SessionStatus: String, Codable {
    case draft
    case completed
}

enum ExportStatus: String, Codable {
    case pending
    case success
    case failed

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .success: "Uploaded"
        case .failed: "Needs Attention"
        }
    }
}

enum ExportSessionKind: String, Codable {
    case fixed
    case adaptive
    case adaptiveReadiness
}

enum FixedCycleOccurrenceOverrideKind: String, Codable, CaseIterable, Hashable {
    case skipExercise
    case skipMuscle
}

/// Persistent evidence for the distinction between a recovery mirror, a file
/// queued in the ubiquitous container, and an item confirmed uploaded by iCloud.
@Model
final class ExportDiagnostic {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var sessionKind: ExportSessionKind
    var status: ExportStatus
    var filename: String
    var containerIdentifier: String?
    var ubiquityContainerPath: String?
    var iCloudDestinationPath: String?
    var localMirrorPath: String?
    var detail: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        sessionKind: ExportSessionKind,
        status: ExportStatus,
        filename: String,
        containerIdentifier: String? = nil,
        ubiquityContainerPath: String? = nil,
        iCloudDestinationPath: String? = nil,
        localMirrorPath: String? = nil,
        detail: String,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionKind = sessionKind
        self.status = status
        self.filename = filename
        self.containerIdentifier = containerIdentifier
        self.ubiquityContainerPath = ubiquityContainerPath
        self.iCloudDestinationPath = iCloudDestinationPath
        self.localMirrorPath = localMirrorPath
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

enum RotationPoolKey: String, Codable, CaseIterable {
    case quadsCompound = "quads_compound"
    /// Reserved structural identity. User-authored/imported templates cannot
    /// create or overwrite this versioned program through CycleView.
    case clusteredHypertrophyV1 = "openlift_clustered_hypertrophy_v1"
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
    case moderate
    case high

    var allowsAutomaticTraining: Bool {
        self == .none || self == .mild
    }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .mild: return "Light"
        case .moderate: return "Moderate"
        case .high: return "Heavy"
        }
    }

    /// Export/import aliases are intentionally separate from the persisted raw
    /// values. Existing SwiftData rows and JSON use `mild` and `high`; the UI
    /// presents those same values as Light and Heavy.
    static func decodeStoredOrExportedValue(_ value: String) -> SorenessLevel? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": return SorenessLevel.none
        case "mild", "light": return .mild
        case "moderate", "medium": return .moderate
        case "high", "heavy": return .high
        default: return nil
        }
    }
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

    static func leastEager<S: Sequence>(in values: S) -> EagernessLevel
    where S.Element == EagernessLevel {
        let values = Set(values)
        return allCases.reversed().first(where: values.contains) ?? .eager
    }
}

enum ReadinessEagernessResolver {
    static func resolve<S: Sequence>(
        systemicEagerness: EagernessLevel?,
        legacyResponseEagerness: S
    ) -> EagernessLevel where S.Element == EagernessLevel? {
        systemicEagerness
            ?? EagernessLevel.leastEager(in: legacyResponseEagerness.compactMap { $0 })
    }

    static func resolve(_ check: DailyReadinessCheck) -> EagernessLevel {
        resolve(
            systemicEagerness: check.systemicEagerness,
            legacyResponseEagerness: check.responses.lazy.map(\.eagerness)
        )
    }

    static func resolve(_ observation: FixedCycleReadinessObservation) -> EagernessLevel {
        resolve(
            systemicEagerness: observation.systemicEagerness,
            legacyResponseEagerness: observation.responses.lazy.map(\.eagerness)
        )
    }
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
    case addComplex
    case removeComplex
    case reorderComplex
    case addExercise
    case removeExercise
    case reorderExercise
    case skipComplex
    case unskipComplex
    case skipExercise
    case unskipExercise
    case substituteExercise
    case painBlock
}

/// Additive profile metadata introduced after Adaptive programs were already
/// persisted. Keeping it parallel avoids changing the checksum of V3 programs.
@Model
final class AdaptiveWorkoutSizePreference {
    @Attribute(.unique) var adaptiveProgramId: UUID
    var defaultComplexCount: Int
    var updatedAt: Date

    init(adaptiveProgramId: UUID, defaultComplexCount: Int, updatedAt: Date = .now) {
        self.adaptiveProgramId = adaptiveProgramId
        self.defaultComplexCount = defaultComplexCount
        self.updatedAt = updatedAt
    }
}

/// Mutable design metadata is deliberately separate from the immutable plan
/// snapshot. It persists today's exposure target and the canonical proposal
/// signature used when readiness is revised.
@Model
final class AdaptivePlanDesignState {
    @Attribute(.unique) var generatedPlanId: UUID
    var targetComplexCount: Int
    var readinessRevision: Int
    var canonicalSignature: String
    var updatedAt: Date

    init(
        generatedPlanId: UUID,
        targetComplexCount: Int,
        readinessRevision: Int,
        canonicalSignature: String,
        updatedAt: Date = .now
    ) {
        self.generatedPlanId = generatedPlanId
        self.targetComplexCount = targetComplexCount
        self.readinessRevision = readinessRevision
        self.canonicalSignature = canonicalSignature
        self.updatedAt = updatedAt
    }
}

/// Version-scoped volume settings are stored beside, rather than inside, the
/// original AdaptiveProgram graph so older stores and completed snapshots keep
/// their existing schema identity.
@Model
final class AdaptiveMuscleVolumeTarget {
    @Attribute(.unique) var key: String
    var adaptiveProgramId: UUID
    var lineageId: UUID
    var muscle: MuscleGroup
    var weeklySetTarget: Int
    var dailySetCap: Int
    var effectiveAt: Date

    init(
        adaptiveProgramId: UUID,
        lineageId: UUID,
        muscle: MuscleGroup,
        weeklySetTarget: Int,
        dailySetCap: Int,
        effectiveAt: Date
    ) {
        self.key = Self.key(programId: adaptiveProgramId, muscle: muscle)
        self.adaptiveProgramId = adaptiveProgramId
        self.lineageId = lineageId
        self.muscle = muscle
        self.weeklySetTarget = weeklySetTarget
        self.dailySetCap = dailySetCap
        self.effectiveAt = effectiveAt
    }

    static func key(programId: UUID, muscle: MuscleGroup) -> String {
        "\(programId.uuidString)|\(muscle.rawValue)"
    }
}

/// Per-version workout time/capacity limits. These are planner limits, not
/// restrictions on manual logging.
@Model
final class AdaptiveWorkoutCapacityPreference {
    @Attribute(.unique) var adaptiveProgramId: UUID
    var maxMuscleGroupCount: Int
    var maxExerciseCount: Int
    var maxExercisesPerMuscle: Int
    var maxWorkingSetCount: Int
    var maxSetsPerExercise: Int
    var updatedAt: Date

    init(
        adaptiveProgramId: UUID,
        maxMuscleGroupCount: Int = 5,
        maxExerciseCount: Int = 7,
        maxExercisesPerMuscle: Int = 2,
        maxWorkingSetCount: Int = 20,
        maxSetsPerExercise: Int = 4,
        updatedAt: Date = .now
    ) {
        self.adaptiveProgramId = adaptiveProgramId
        self.maxMuscleGroupCount = maxMuscleGroupCount
        self.maxExerciseCount = maxExerciseCount
        self.maxExercisesPerMuscle = maxExercisesPerMuscle
        self.maxWorkingSetCount = maxWorkingSetCount
        self.maxSetsPerExercise = maxSetsPerExercise
        self.updatedAt = updatedAt
    }
}

/// A one-time starting balance for a profile lineage. The balance is seeded
/// from direct completed work in the preceding seven days; later balances are
/// derived from immutable history and versioned target changes.
@Model
final class AdaptiveMuscleVolumeAnchor {
    @Attribute(.unique) var key: String
    var lineageId: UUID
    var muscle: MuscleGroup
    var activatedAt: Date
    var initialBalance: Double
    var seededDirectSetEntryIds: [UUID]

    init(
        lineageId: UUID,
        muscle: MuscleGroup,
        activatedAt: Date,
        initialBalance: Double,
        seededDirectSetEntryIds: [UUID] = []
    ) {
        self.key = Self.key(lineageId: lineageId, muscle: muscle)
        self.lineageId = lineageId
        self.muscle = muscle
        self.activatedAt = activatedAt
        self.initialBalance = initialBalance
        self.seededDirectSetEntryIds = seededDirectSetEntryIds
    }

    static func key(lineageId: UUID, muscle: MuscleGroup) -> String {
        "\(lineageId.uuidString)|\(muscle.rawValue)"
    }
}

enum AdaptiveCadenceKind: String, Codable, CaseIterable, Hashable {
    case fixedCalendarDays
    case lateralDelts2221

    var displayName: String {
        switch self {
        case .fixedCalendarDays: return "Fixed recovery days"
        case .lateralDelts2221: return "Floating 2, 2, 2, 1 days"
        }
    }
}

enum AdaptiveExerciseSplitKind: String, Codable, CaseIterable, Hashable {
    case none
    case chestCompoundIsolation
    case backVerticalHorizontal

    var displayName: String {
        switch self {
        case .none: return "Single exercise"
        case .chestCompoundIsolation: return "Compound + isolation"
        case .backVerticalHorizontal: return "Vertical + horizontal"
        }
    }
}

/// Version-scoped automatic-planning configuration introduced by schema V8.
/// It is intentionally parallel to the legacy V7 weekly-volume records so
/// workout history and stores that already contain those rows remain intact.
@Model
final class AdaptiveMuscleExposureConfiguration {
    @Attribute(.unique) var key: String
    var adaptiveProgramId: UUID
    var lineageId: UUID
    var muscle: MuscleGroup
    var isAutomaticPlanningEnabled: Bool
    var normalSetCount: Int
    var cadenceKind: AdaptiveCadenceKind
    var minimumCalendarDays: Int
    var cadencePattern: [Int]
    var exerciseSplitKind: AdaptiveExerciseSplitKind
    var firstSplitSetCount: Int
    var secondSplitSetCount: Int
    var effectiveAt: Date

    init(
        adaptiveProgramId: UUID,
        lineageId: UUID,
        muscle: MuscleGroup,
        isAutomaticPlanningEnabled: Bool,
        normalSetCount: Int,
        cadenceKind: AdaptiveCadenceKind,
        minimumCalendarDays: Int,
        cadencePattern: [Int] = [],
        exerciseSplitKind: AdaptiveExerciseSplitKind = .none,
        firstSplitSetCount: Int = 0,
        secondSplitSetCount: Int = 0,
        effectiveAt: Date
    ) {
        self.key = Self.key(programId: adaptiveProgramId, muscle: muscle)
        self.adaptiveProgramId = adaptiveProgramId
        self.lineageId = lineageId
        self.muscle = muscle
        self.isAutomaticPlanningEnabled = isAutomaticPlanningEnabled
        self.normalSetCount = normalSetCount
        self.cadenceKind = cadenceKind
        self.minimumCalendarDays = minimumCalendarDays
        self.cadencePattern = cadencePattern
        self.exerciseSplitKind = exerciseSplitKind
        self.firstSplitSetCount = firstSplitSetCount
        self.secondSplitSetCount = secondSplitSetCount
        self.effectiveAt = effectiveAt
    }

    static func key(programId: UUID, muscle: MuscleGroup) -> String {
        "\(programId.uuidString)|\(muscle.rawValue)"
    }
}

enum AdaptiveExerciseSelectionMode: String, Codable, CaseIterable, Hashable {
    case repeatLast
    case rotateRecent
    case pinned

    var displayName: String {
        switch self {
        case .repeatLast: return "Repeat latest"
        case .rotateRecent: return "Alternate recent"
        case .pinned: return "Pinned exercise"
        }
    }
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
final class AdaptiveExerciseSelectionPreference {
    @Attribute(.unique) var key: String
    var muscle: MuscleGroup
    var mode: AdaptiveExerciseSelectionMode
    var pinnedExerciseId: UUID?
    var eligibleExerciseIds: [UUID]

    init(
        muscle: MuscleGroup,
        mode: AdaptiveExerciseSelectionMode,
        pinnedExerciseId: UUID? = nil,
        eligibleExerciseIds: [UUID] = []
    ) {
        self.key = Self.key(for: muscle)
        self.muscle = muscle
        self.mode = mode
        self.pinnedExerciseId = pinnedExerciseId
        self.eligibleExerciseIds = eligibleExerciseIds
    }

    static func key(for muscle: MuscleGroup) -> String {
        "adaptive.exercise-selection.\(muscle.rawValue)"
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
    var eagerness: EagernessLevel?

    init(
        id: UUID = UUID(),
        muscle: MuscleGroup,
        soreness: SorenessLevel,
        connectiveTissuePain: ConnectiveTissuePainLevel,
        eagerness: EagernessLevel? = nil
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
    var systemicEagerness: EagernessLevel?
    @Relationship(deleteRule: .cascade) var responses: [AdaptiveReadinessResponse]

    init(
        id: UUID = UUID(),
        localDateKey: String,
        timeZoneIdentifier: String,
        revision: Int,
        createdAt: Date = .now,
        adaptiveProgramId: UUID,
        adaptiveProgramVersion: Int,
        systemicEagerness: EagernessLevel? = nil,
        responses: [AdaptiveReadinessResponse]
    ) {
        self.id = id
        self.localDateKey = localDateKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.revision = revision
        self.createdAt = createdAt
        self.adaptiveProgramId = adaptiveProgramId
        self.adaptiveProgramVersion = adaptiveProgramVersion
        self.systemicEagerness = systemicEagerness
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
    var lockedAt: Date?

    init(
        id: UUID = UUID(),
        adaptiveSessionId: UUID,
        occurrenceId: UUID,
        exerciseId: UUID,
        setIndex: Int,
        weight: Double = 0,
        reps: Int = 0,
        isLocked: Bool = false,
        lockedAt: Date? = nil
    ) {
        self.id = id
        self.adaptiveSessionId = adaptiveSessionId
        self.occurrenceId = occurrenceId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.weight = weight
        self.reps = reps
        self.isLocked = isLocked
        self.lockedAt = lockedAt
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
    var lockedAt: Date?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        exerciseId: UUID,
        setIndex: Int,
        weight: Double,
        reps: Int,
        isLocked: Bool = false,
        lockedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.weight = weight
        self.reps = reps
        self.isLocked = isLocked
        self.lockedAt = lockedAt
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

/// An immutable, dated readiness revision associated with one Fixed Cycle
/// draft. The draft can span local dates, so more than one observation may
/// legitimately point at the same session.
@Model
final class FixedCycleReadinessObservation {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var localDateKey: String
    var timeZoneIdentifier: String
    var revision: Int
    var createdAt: Date
    var systemicEagerness: EagernessLevel?
    @Relationship(deleteRule: .cascade) var responses: [FixedCycleReadinessResponse]

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        localDateKey: String,
        timeZoneIdentifier: String,
        revision: Int,
        createdAt: Date = .now,
        systemicEagerness: EagernessLevel? = nil,
        responses: [FixedCycleReadinessResponse]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.localDateKey = localDateKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.revision = revision
        self.createdAt = createdAt
        self.systemicEagerness = systemicEagerness
        self.responses = responses
    }
}

@Model
final class FixedCycleReadinessResponse {
    @Attribute(.unique) var id: UUID
    var muscle: MuscleGroup
    var soreness: SorenessLevel
    var connectiveTissuePain: ConnectiveTissuePainLevel
    var eagerness: EagernessLevel?

    init(
        id: UUID = UUID(),
        muscle: MuscleGroup,
        soreness: SorenessLevel,
        connectiveTissuePain: ConnectiveTissuePainLevel,
        eagerness: EagernessLevel? = nil
    ) {
        self.id = id
        self.muscle = muscle
        self.soreness = soreness
        self.connectiveTissuePain = connectiveTissuePain
        self.eagerness = eagerness
    }
}

/// Occurrence-only provenance. These rows never mutate the template and are
/// retained after completion for history/export recovery.
@Model
final class FixedCycleOccurrenceOverride {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var kind: FixedCycleOccurrenceOverrideKind
    var slotPosition: Int?
    var exerciseId: UUID?
    var muscle: MuscleGroup?
    var reasonCode: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        kind: FixedCycleOccurrenceOverrideKind,
        slotPosition: Int? = nil,
        exerciseId: UUID? = nil,
        muscle: MuscleGroup? = nil,
        reasonCode: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.slotPosition = slotPosition
        self.exerciseId = exerciseId
        self.muscle = muscle
        self.reasonCode = reasonCode
        self.createdAt = createdAt
    }
}

/// Immutable ordered membership for a completed Fixed Cycle occurrence. This
/// keeps history/export retries independent of later template edits.
@Model
final class FixedCycleExerciseSnapshot {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var position: Int
    var exerciseId: UUID
    var exerciseName: String
    var muscle: MuscleGroup
    var statusRawValue: String
    var skipReason: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        position: Int,
        exerciseId: UUID,
        exerciseName: String,
        muscle: MuscleGroup,
        statusRawValue: String,
        skipReason: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.position = position
        self.exerciseId = exerciseId
        self.exerciseName = exerciseName
        self.muscle = muscle
        self.statusRawValue = statusRawValue
        self.skipReason = skipReason
    }
}

enum ClusterExerciseCompletionStatus: String, Codable, Equatable, Sendable {
    case performed
    case skipped
}

/// Immutable value copied into a completed cluster occurrence. Progression
/// history is queried from this value, never re-derived from a later program
/// shape or an exercise name.
struct ClusterExerciseProgressionSnapshot: Codable, Equatable, Sendable {
    let position: Int
    let exerciseId: UUID
    let exerciseName: String
    let muscle: MuscleGroup
    let prescribedSetCount: Int
    let progressionKey: String
    let resistanceProfile: ResistanceProfileValue?
    let completionStatus: ClusterExerciseCompletionStatus
}

/// The authoritative next position for one independently advancing cluster.
/// This is the only mutable V13 clustered-program entity.
@Model
final class ClusterRotationState {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var cycleInstanceId: UUID
    var templateId: UUID
    var programVersionID: String
    var clusterID: String
    var positionIndex: Int
    var updatedAt: Date
    var lastCompletedOccurrenceID: UUID?
    /// True only when recovery had occurrence history but no exported pointer.
    /// Derived state is usable, but remains visible rather than masquerading as
    /// an explicitly exported pointer.
    var isDerived: Bool

    init(
        id: UUID = UUID(),
        cycleInstanceId: UUID,
        templateId: UUID,
        programVersionID: String,
        clusterID: String,
        positionIndex: Int,
        updatedAt: Date = .now,
        lastCompletedOccurrenceID: UUID? = nil,
        isDerived: Bool = false
    ) {
        self.id = id
        self.key = Self.key(
            cycleInstanceId: cycleInstanceId,
            programVersionID: programVersionID,
            clusterID: clusterID
        )
        self.cycleInstanceId = cycleInstanceId
        self.templateId = templateId
        self.programVersionID = programVersionID
        self.clusterID = clusterID
        self.positionIndex = positionIndex
        self.updatedAt = updatedAt
        self.lastCompletedOccurrenceID = lastCompletedOccurrenceID
        self.isDerived = isDerived
    }

    static func key(
        cycleInstanceId: UUID,
        programVersionID: String,
        clusterID: String
    ) -> String {
        "\(cycleInstanceId.uuidString)|\(programVersionID)|\(clusterID)"
    }
}

/// Immutable completion evidence for exactly one whole cluster. It references
/// the legacy Session by UUID so V12's Session shape remains untouched.
@Model
final class ClusterOccurrenceRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var sessionId: UUID
    var cycleInstanceId: UUID
    var templateId: UUID
    var programVersionID: String
    var clusterID: String
    var absoluteStep: Int
    var templateDayPosition: Int
    var dayLabel: String
    var completedAt: Date
    private var exerciseSnapshotsData: Data

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        cycleInstanceId: UUID,
        templateId: UUID,
        programVersionID: String,
        clusterID: String,
        absoluteStep: Int,
        templateDayPosition: Int,
        dayLabel: String,
        completedAt: Date = .now,
        exerciseSnapshots: [ClusterExerciseProgressionSnapshot]
    ) throws {
        self.id = id
        self.key = Self.key(sessionId: sessionId, clusterID: clusterID)
        self.sessionId = sessionId
        self.cycleInstanceId = cycleInstanceId
        self.templateId = templateId
        self.programVersionID = programVersionID
        self.clusterID = clusterID
        self.absoluteStep = absoluteStep
        self.templateDayPosition = templateDayPosition
        self.dayLabel = dayLabel
        self.completedAt = completedAt
        self.exerciseSnapshotsData = try JSONEncoder().encode(exerciseSnapshots)
    }

    convenience init(
        id: UUID = UUID(),
        sessionId: UUID,
        cycleInstanceId: UUID,
        templateId: UUID,
        programVersionID: String,
        clusterID: String,
        positionIndex: Int,
        templateDayPosition: Int,
        dayLabel: String,
        completedAt: Date = .now,
        exerciseSnapshots: [ClusterExerciseProgressionSnapshot]
    ) throws {
        try self.init(
            id: id,
            sessionId: sessionId,
            cycleInstanceId: cycleInstanceId,
            templateId: templateId,
            programVersionID: programVersionID,
            clusterID: clusterID,
            absoluteStep: positionIndex,
            templateDayPosition: templateDayPosition,
            dayLabel: dayLabel,
            completedAt: completedAt,
            exerciseSnapshots: exerciseSnapshots
        )
    }

    var exerciseSnapshots: [ClusterExerciseProgressionSnapshot] {
        (try? JSONDecoder().decode(
            [ClusterExerciseProgressionSnapshot].self,
            from: exerciseSnapshotsData
        )) ?? []
    }

    var positionIndex: Int { absoluteStep }

    static func key(sessionId: UUID, clusterID: String) -> String {
        "\(sessionId.uuidString)|\(clusterID)"
    }
}
