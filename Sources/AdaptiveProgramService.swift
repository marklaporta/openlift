import Foundation
import SwiftData

enum AdaptiveProgramValidationError: LocalizedError, Equatable {
    case emptyProgramName
    case invalidGlobalMovementCap(Int)
    case invalidDefaultComplexCount(Int)
    case invalidWorkoutLimit(field: String, value: Int)
    case invalidDifficultyBudget(Int)
    case missingMuscleRule(MuscleGroup)
    case duplicateMuscleRule(MuscleGroup)
    case invalidPriority(muscle: MuscleGroup, rank: Int)
    case duplicatePriority(Int)
    case invalidMuscleLimit(muscle: MuscleGroup, field: String, value: Int)
    case noEnabledComplexes
    case emptyComplexName(position: Int)
    case emptyComplex(name: String)
    case complexExceedsMovementCap(name: String, count: Int, cap: Int)
    case complexExceedsDifficultyBudget(name: String, cost: Int, budget: Int)
    case exerciseNotFound(UUID)
    case inactiveExercise(name: String)
    case componentMuscleMismatch(exercise: String, expected: MuscleGroup, actual: MuscleGroup)
    case duplicateExerciseOccurrence(complex: String, exercise: String)
    case invalidSecondaryMuscle(exercise: String)
    case invalidComponentSets(exercise: String, count: Int, cap: Int)
    case complexDoesNotAttributePrimary(name: String, muscle: MuscleGroup)
    case noFloorQualifyingComplex(MuscleGroup)

    var errorDescription: String? {
        switch self {
        case .emptyProgramName:
            return "Adaptive profile name cannot be empty."
        case .invalidGlobalMovementCap(let value):
            return "Maximum exercises per complex must be between 1 and 20. Got \(value)."
        case .invalidDefaultComplexCount(let value):
            return "Default muscle-group count must be between 1 and 12. Got \(value)."
        case .invalidWorkoutLimit(let field, let value):
            return "\(field) has an invalid value: \(value)."
        case .invalidDifficultyBudget(let value):
            return "Daily difficulty budget must be between 1 and 60. Got \(value)."
        case .missingMuscleRule(let muscle):
            return "Missing a rule for \(muscle.displayName). All supported muscles need an explicit rule."
        case .duplicateMuscleRule(let muscle):
            return "\(muscle.displayName) has more than one rule."
        case .invalidPriority(let muscle, let rank):
            return "\(muscle.displayName) priority rank \(rank) is outside the enabled-muscle range."
        case .duplicatePriority(let rank):
            return "Priority rank \(rank) is assigned more than once. Ranks must be strict."
        case .invalidMuscleLimit(let muscle, let field, let value):
            return "\(muscle.displayName) has invalid \(field): \(value)."
        case .noEnabledComplexes:
            return "The profile needs at least one enabled exercise complex."
        case .emptyComplexName(let position):
            return "Complex \(position + 1) needs a name."
        case .emptyComplex(let name):
            return "Complex '\(name)' needs at least one component exercise."
        case .complexExceedsMovementCap(let name, let count, let cap):
            return "Complex '\(name)' has \(count) component movements, exceeding the daily cap of \(cap)."
        case .complexExceedsDifficultyBudget(let name, let cost, let budget):
            return "Complex '\(name)' costs \(cost) difficulty points, exceeding the daily budget of \(budget)."
        case .exerciseNotFound(let id):
            return "Exercise \(id.uuidString) no longer exists."
        case .inactiveExercise(let name):
            return "Complex component '\(name)' is inactive."
        case .componentMuscleMismatch(let exercise, let expected, let actual):
            return "\(exercise) is cataloged as \(actual.displayName), not \(expected.displayName)."
        case .duplicateExerciseOccurrence(let complex, let exercise):
            return "Complex '\(complex)' contains \(exercise) more than once. Use separate complexes for repeated occurrences."
        case .invalidSecondaryMuscle(let exercise):
            return "\(exercise)'s secondary muscle must differ from its primary muscle."
        case .invalidComponentSets(let exercise, let count, let cap):
            return "\(exercise) prescribes \(count) sets, exceeding its muscle cap of \(cap)."
        case .complexDoesNotAttributePrimary(let name, let muscle):
            return "Complex '\(name)' does not attribute any component to its primary muscle, \(muscle.displayName)."
        case .noFloorQualifyingComplex(let muscle):
            return "\(muscle.displayName) has no enabled complex marked to satisfy its training-window/gap policy."
        }
    }
}

struct AdaptiveMuscleRuleDraft: Identifiable, Equatable {
    var id: UUID
    var muscle: MuscleGroup
    var priorityRank: Int
    var rollingSetFloor: Int
    var rollingWindowDays: Int
    var maxRecoveredDayGap: Int
    var maxExercisesPerExposure: Int
    var maxSetsPerExercise: Int
    var isEnabled: Bool
    var weeklySetTarget: Int
    var dailySetCap: Int

    init(
        id: UUID,
        muscle: MuscleGroup,
        priorityRank: Int,
        rollingSetFloor: Int,
        rollingWindowDays: Int,
        maxRecoveredDayGap: Int,
        maxExercisesPerExposure: Int,
        maxSetsPerExercise: Int,
        isEnabled: Bool,
        weeklySetTarget: Int? = nil,
        dailySetCap: Int = 4
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
        self.weeklySetTarget = weeklySetTarget
            ?? AdaptiveVolumeControllerService.defaultWeeklyTarget(for: muscle)
        self.dailySetCap = dailySetCap
    }
}

struct AdaptiveComplexComponentDraft: Identifiable, Equatable {
    var id: UUID
    var exerciseId: UUID
    var prescribedSetCount: Int
    var primaryMuscle: MuscleGroup
    var secondaryMuscle: MuscleGroup?
    var difficulty: MovementDifficulty
}

struct AdaptiveExerciseComplexDraft: Identifiable, Equatable {
    var id: UUID
    var definitionId: UUID
    var sourceVersion: Int
    var name: String
    var primaryMuscle: MuscleGroup
    var qualifiesForPrimaryFloor: Bool
    var isEnabled: Bool
    var components: [AdaptiveComplexComponentDraft]
}

struct AdaptiveProgramDraft: Equatable {
    var name: String
    var isReviewedForUse: Bool
    var defaultComplexCount: Int
    var maxExerciseCount: Int
    var maxExercisesPerMuscle: Int
    var maxWorkingSetCount: Int
    var globalMaxMovements: Int
    var maxDifficultyCost: Int
    var muscleRules: [AdaptiveMuscleRuleDraft]
    var complexes: [AdaptiveExerciseComplexDraft]

    static var blank: AdaptiveProgramDraft {
        AdaptiveProgramDraft(
            name: "New Adaptive Profile",
            isReviewedForUse: false,
            defaultComplexCount: 5,
            maxExerciseCount: 7,
            maxExercisesPerMuscle: 2,
            maxWorkingSetCount: 20,
            globalMaxMovements: 4,
            maxDifficultyCost: 60,
            muscleRules: MuscleGroup.allCases.map { muscle in
                let rank = MuscleGroup.initialAdaptiveRankOrder.firstIndex(of: muscle).map { $0 + 1 }
                return AdaptiveMuscleRuleDraft(
                    id: UUID(),
                    muscle: muscle,
                    priorityRank: rank ?? 0,
                    rollingSetFloor: rank == nil ? 0 : 1,
                    rollingWindowDays: 7,
                    maxRecoveredDayGap: 10,
                    maxExercisesPerExposure: 4,
                    maxSetsPerExercise: 4,
                    isEnabled: rank != nil,
                    weeklySetTarget: AdaptiveVolumeControllerService.defaultWeeklyTarget(for: muscle),
                    dailySetCap: 4
                )
            },
            complexes: []
        )
    }

    init(
        name: String,
        isReviewedForUse: Bool,
        defaultComplexCount: Int? = nil,
        maxExerciseCount: Int = 7,
        maxExercisesPerMuscle: Int = 2,
        maxWorkingSetCount: Int = 20,
        globalMaxMovements: Int,
        maxDifficultyCost: Int,
        muscleRules: [AdaptiveMuscleRuleDraft],
        complexes: [AdaptiveExerciseComplexDraft]
    ) {
        self.name = name
        self.isReviewedForUse = isReviewedForUse
        self.defaultComplexCount = defaultComplexCount ?? globalMaxMovements
        self.maxExerciseCount = maxExerciseCount
        self.maxExercisesPerMuscle = maxExercisesPerMuscle
        self.maxWorkingSetCount = maxWorkingSetCount
        self.globalMaxMovements = globalMaxMovements
        self.maxDifficultyCost = maxDifficultyCost
        self.muscleRules = muscleRules
        self.complexes = complexes
    }

    init(existing: AdaptiveProgram) {
        name = existing.name
        isReviewedForUse = existing.isReviewedForUse
        defaultComplexCount = 5
        maxExerciseCount = 7
        maxExercisesPerMuscle = 2
        maxWorkingSetCount = 20
        globalMaxMovements = existing.globalMaxMovements
        maxDifficultyCost = existing.maxDifficultyCost
        muscleRules = existing.muscleRules
            .sorted { $0.priorityRank < $1.priorityRank }
            .map {
                AdaptiveMuscleRuleDraft(
                    id: $0.id,
                    muscle: $0.muscle,
                    priorityRank: $0.priorityRank,
                    rollingSetFloor: $0.rollingSetFloor > 0 ? 1 : 0,
                    rollingWindowDays: $0.rollingWindowDays,
                    maxRecoveredDayGap: $0.maxRecoveredDayGap,
                    maxExercisesPerExposure: $0.maxExercisesPerExposure,
                    maxSetsPerExercise: $0.maxSetsPerExercise,
                    isEnabled: $0.isEnabled,
                    weeklySetTarget: AdaptiveVolumeControllerService.defaultWeeklyTarget(for: $0.muscle),
                    dailySetCap: 4
                )
            }
        complexes = existing.complexes
            .sorted { $0.position < $1.position }
            .map { complex in
                AdaptiveExerciseComplexDraft(
                    id: complex.id,
                    definitionId: complex.definitionId,
                    sourceVersion: complex.version,
                    name: complex.name,
                    primaryMuscle: complex.primaryMuscle,
                    qualifiesForPrimaryFloor: complex.qualifiesForPrimaryFloor,
                    isEnabled: complex.isEnabled,
                    components: complex.components
                        .sorted { $0.position < $1.position }
                        .map {
                            AdaptiveComplexComponentDraft(
                                id: $0.id,
                                exerciseId: $0.exerciseId,
                                prescribedSetCount: $0.prescribedSetCount,
                                primaryMuscle: $0.primaryMuscle,
                                secondaryMuscle: $0.secondaryMuscle,
                                difficulty: $0.difficulty
                            )
                        }
                )
            }
    }
}

enum AdaptiveProgramService {
    static func defaultComplexCount(
        for program: AdaptiveProgram,
        preferences: [AdaptiveWorkoutSizePreference]
    ) -> Int {
        preferences.first { $0.adaptiveProgramId == program.id }?.defaultComplexCount
            ?? max(1, min(program.globalMaxMovements, 12))
    }

    @discardableResult
    static func ensureWorkoutSizePreferences(modelContext: ModelContext) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        let existing = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSizePreference>())
        let existingProgramIds = Set(existing.map(\.adaptiveProgramId))
        var inserted = 0
        for program in programs where !existingProgramIds.contains(program.id) {
            modelContext.insert(
                AdaptiveWorkoutSizePreference(
                    adaptiveProgramId: program.id,
                    defaultComplexCount: max(1, min(program.globalMaxMovements, 12))
                )
            )
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    @discardableResult
    static func ensurePlanDesignStates(modelContext: ModelContext) throws -> Int {
        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>()).filter {
            $0.status != .completed
        }
        let states = try modelContext.fetch(FetchDescriptor<AdaptivePlanDesignState>())
        let statePlanIds = Set(states.map(\.generatedPlanId))
        let checks = try modelContext.fetch(FetchDescriptor<DailyReadinessCheck>())
        var inserted = 0
        for plan in plans where !statePlanIds.contains(plan.id) {
            let revision = checks.first { $0.id == plan.readinessCheckId }?.revision ?? 1
            modelContext.insert(
                AdaptiveWorkoutService.makeDesignState(
                    plan: plan,
                    targetComplexCount: max(1, plan.complexes.count),
                    readinessRevision: revision
                )
            )
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    static func activeProgram(from programs: [AdaptiveProgram]) -> AdaptiveProgram? {
        programs
            .filter(\.isActiveVersion)
            .sorted {
                if $0.version != $1.version { return $0.version > $1.version }
                return $0.createdAt > $1.createdAt
            }
            .first
    }

    @discardableResult
    static func normalizeBinaryExposureRequirements(modelContext: ModelContext) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        var changed = 0
        for rule in programs.flatMap(\.muscleRules) where rule.rollingSetFloor > 1 {
            rule.rollingSetFloor = 1
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    @discardableResult
    static func normalizeLegacyDemoLabels(modelContext: ModelContext) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        var changed = 0

        for program in programs {
            if program.name == "Adaptive Demo — Review Required" {
                program.name = "Adaptive Program"
                changed += 1
            }
            for complex in program.complexes where complex.name == "\(complex.primaryMuscle.displayName) Demo" {
                complex.name = complex.primaryMuscle.displayName
                changed += 1
            }
        }
        for complex in plans.flatMap(\.complexes)
            where complex.name == "\(complex.primaryMuscle.displayName) Demo" {
            complex.name = complex.primaryMuscle.displayName
            changed += 1
        }

        if changed > 0 { try modelContext.save() }
        return changed
    }

    @discardableResult
    static func normalizeOpenPlanExerciseCategories(modelContext: ModelContext) throws -> Int {
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        var changed = 0
        for plan in plans where plan.status != .completed {
            for snapshot in plan.complexes.flatMap(\.exercises) {
                guard let exercise = exercisesById[snapshot.exerciseId] else { continue }
                let difficulty = AdaptiveExerciseRoleService.difficulty(for: exercise)
                if snapshot.difficulty != difficulty {
                    snapshot.difficulty = difficulty
                    changed += 1
                }
            }
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Applies a targeted equipment-eligibility correction without replacing
    /// the active profile. Keeping the profile identity stable preserves links
    /// from today's completed plan and all historical snapshots.
    @discardableResult
    static func disableMuscleProgramming(
        _ muscle: MuscleGroup,
        modelContext: ModelContext
    ) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        guard let program = activeProgram(from: programs) else { return 0 }
        var changed = 0

        if let rule = program.muscleRules.first(where: { $0.muscle == muscle }) {
            if rule.isEnabled {
                rule.isEnabled = false
                changed += 1
            }
            if rule.priorityRank != 0 {
                rule.priorityRank = 0
                changed += 1
            }
            if rule.rollingSetFloor != 0 {
                rule.rollingSetFloor = 0
                changed += 1
            }
        }

        for complex in program.complexes where complex.isEnabled {
            let includesMuscle = complex.primaryMuscle == muscle
                || complex.components.contains { $0.primaryMuscle == muscle }
            if includesMuscle {
                complex.isEnabled = false
                changed += 1
            }
        }

        let enabledRules = program.muscleRules
            .filter(\.isEnabled)
            .sorted {
                if $0.priorityRank != $1.priorityRank {
                    return $0.priorityRank < $1.priorityRank
                }
                return $0.muscle.rawValue < $1.muscle.rawValue
            }
        for (offset, rule) in enabledRules.enumerated() where rule.priorityRank != offset + 1 {
            rule.priorityRank = offset + 1
            changed += 1
        }

        if changed > 0 { try modelContext.save() }
        return changed
    }

    static func demoDraft(exercises: [Exercise]) -> AdaptiveProgramDraft {
        var draft = AdaptiveProgramDraft.blank
        draft.name = "Adaptive Starter — Review Required"
        draft.muscleRules = draft.muscleRules.map { rule in
            var copy = rule
            copy.rollingSetFloor = copy.isEnabled ? 1 : 0
            return copy
        }
        draft.complexes = draft.muscleRules.filter(\.isEnabled).compactMap { rule in
            let muscle = rule.muscle
            let available = exercises
                .filter({ $0.isActive && $0.primaryMuscle == muscle })
                .sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            guard let exercise = available.first else {
                return nil
            }
            let selectedExercises: [Exercise]
            if muscle == .back,
               let verticalPull = available.first(where: {
                   BackMovementPatternService.pattern(for: $0) == .verticalPull
               }),
               let horizontalPull = available.first(where: {
                   BackMovementPatternService.pattern(for: $0) == .horizontalPull
               }) {
                selectedExercises = [verticalPull, horizontalPull]
            } else {
                selectedExercises = [exercise]
            }
            return AdaptiveExerciseComplexDraft(
                id: UUID(),
                definitionId: UUID(),
                sourceVersion: 0,
                name: muscle.displayName,
                primaryMuscle: muscle,
                qualifiesForPrimaryFloor: true,
                isEnabled: true,
                components: selectedExercises.map {
                    AdaptiveComplexComponentDraft(
                        id: UUID(),
                        exerciseId: $0.id,
                        prescribedSetCount: 2,
                        primaryMuscle: $0.primaryMuscle,
                        secondaryMuscle: nil,
                        difficulty: AdaptiveExerciseRoleService.difficulty(for: $0)
                    )
                }
            )
        }
        return draft
    }

    static func validate(_ draft: AdaptiveProgramDraft, exercises: [Exercise]) throws {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AdaptiveProgramValidationError.emptyProgramName
        }
        guard (1...20).contains(draft.globalMaxMovements) else {
            throw AdaptiveProgramValidationError.invalidGlobalMovementCap(draft.globalMaxMovements)
        }
        guard (1...12).contains(draft.defaultComplexCount) else {
            throw AdaptiveProgramValidationError.invalidDefaultComplexCount(draft.defaultComplexCount)
        }
        let workoutLimits = [
            ("Maximum muscle groups", draft.defaultComplexCount, 1...12),
            ("Maximum exercises", draft.maxExerciseCount, 1...30),
            ("Maximum exercises per muscle", draft.maxExercisesPerMuscle, 1...5),
            ("Maximum working sets", draft.maxWorkingSetCount, 1...100)
        ]
        for (field, value, range) in workoutLimits where !range.contains(value) {
            throw AdaptiveProgramValidationError.invalidWorkoutLimit(field: field, value: value)
        }
        guard (1...60).contains(draft.maxDifficultyCost) else {
            throw AdaptiveProgramValidationError.invalidDifficultyBudget(draft.maxDifficultyCost)
        }

        for muscle in MuscleGroup.allCases {
            let matches = draft.muscleRules.filter { $0.muscle == muscle }
            if matches.isEmpty { throw AdaptiveProgramValidationError.missingMuscleRule(muscle) }
            if matches.count > 1 { throw AdaptiveProgramValidationError.duplicateMuscleRule(muscle) }
        }

        let enabledRules = draft.muscleRules.filter(\.isEnabled)
        var ranks = Set<Int>()
        for rule in draft.muscleRules {
            try validate(rule: rule)
        }
        for rule in enabledRules {
            guard (1...enabledRules.count).contains(rule.priorityRank) else {
                throw AdaptiveProgramValidationError.invalidPriority(muscle: rule.muscle, rank: rule.priorityRank)
            }
            guard ranks.insert(rule.priorityRank).inserted else {
                throw AdaptiveProgramValidationError.duplicatePriority(rule.priorityRank)
            }
        }

        let enabledComplexes = draft.complexes.filter(\.isEnabled)
        guard !enabledComplexes.isEmpty else {
            throw AdaptiveProgramValidationError.noEnabledComplexes
        }
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let rulesByMuscle = Dictionary(uniqueKeysWithValues: enabledRules.map { ($0.muscle, $0) })

        for (position, complex) in enabledComplexes.enumerated() {
            try validate(
                complex: complex,
                position: position,
                draft: draft,
                exercisesById: exercisesById,
                rulesByMuscle: rulesByMuscle
            )
        }

        for rule in enabledRules {
            let hasQualifyingComplex = enabledComplexes.contains {
                $0.primaryMuscle == rule.muscle && $0.qualifiesForPrimaryFloor
            }
            if !hasQualifyingComplex {
                throw AdaptiveProgramValidationError.noFloorQualifyingComplex(rule.muscle)
            }
        }
    }

    @discardableResult
    static func saveVersion(
        draft: AdaptiveProgramDraft,
        replacing current: AdaptiveProgram?,
        allPrograms: [AdaptiveProgram],
        exercises: [Exercise],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> AdaptiveProgram {
        try validate(draft, exercises: exercises)
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        let programVersion = (current?.version ?? 0) + 1
        let program = AdaptiveProgram(
            lineageId: current?.lineageId ?? UUID(),
            version: programVersion,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            isActiveVersion: true,
            isReviewedForUse: draft.isReviewedForUse,
            globalMaxMovements: draft.globalMaxMovements,
            maxDifficultyCost: draft.maxDifficultyCost,
            muscleRules: draft.muscleRules.map { rule in
                AdaptiveMuscleRule(
                    muscle: rule.muscle,
                    priorityRank: rule.priorityRank,
                    rollingSetFloor: rule.rollingSetFloor > 0 ? 1 : 0,
                    rollingWindowDays: rule.rollingWindowDays,
                    maxRecoveredDayGap: rule.maxRecoveredDayGap,
                    maxExercisesPerExposure: rule.maxExercisesPerExposure,
                    maxSetsPerExercise: rule.maxSetsPerExercise,
                    isEnabled: rule.isEnabled
                )
            },
            complexes: draft.complexes.enumerated().map { position, complex in
                AdaptiveExerciseComplex(
                    definitionId: complex.definitionId,
                    version: complex.sourceVersion + 1,
                    name: complex.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    position: position,
                    primaryMuscle: complex.primaryMuscle,
                    qualifiesForPrimaryFloor: complex.qualifiesForPrimaryFloor,
                    isEnabled: complex.isEnabled,
                    components: complex.components.enumerated().map { componentPosition, component in
                        AdaptiveComplexComponent(
                            position: componentPosition,
                            exerciseId: component.exerciseId,
                            prescribedSetCount: component.prescribedSetCount,
                            primaryMuscle: component.primaryMuscle,
                            secondaryMuscle: component.secondaryMuscle,
                            difficulty: exercisesById[component.exerciseId].map {
                                AdaptiveExerciseRoleService.difficulty(for: $0)
                            } ?? component.difficulty
                        )
                    }
                )
            }
        )

        for existing in allPrograms where existing.isActiveVersion {
            existing.isActiveVersion = false
        }
        modelContext.insert(program)
        modelContext.insert(
            AdaptiveWorkoutSizePreference(
                adaptiveProgramId: program.id,
                defaultComplexCount: draft.defaultComplexCount,
                updatedAt: now
            )
        )
        for rule in draft.muscleRules {
            modelContext.insert(
                AdaptiveMuscleVolumeTarget(
                    adaptiveProgramId: program.id,
                    lineageId: program.lineageId,
                    muscle: rule.muscle,
                    weeklySetTarget: rule.isEnabled ? rule.weeklySetTarget : 0,
                    dailySetCap: rule.dailySetCap,
                    effectiveAt: now
                )
            )
        }
        modelContext.insert(
            AdaptiveWorkoutCapacityPreference(
                adaptiveProgramId: program.id,
                maxMuscleGroupCount: draft.defaultComplexCount,
                maxExerciseCount: draft.maxExerciseCount,
                maxExercisesPerMuscle: draft.maxExercisesPerMuscle,
                maxWorkingSetCount: draft.maxWorkingSetCount,
                maxSetsPerExercise: 4,
                updatedAt: now
            )
        )
        _ = try AdaptiveVolumeControllerService.ensureStoredConfiguration(
            modelContext: modelContext,
            now: now,
            saveChanges: false
        )

        do {
            try modelContext.save()
            return program
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func validate(rule: AdaptiveMuscleRuleDraft) throws {
        let fields: [(String, Int, ClosedRange<Int>)] = [
            ("rolling exposure requirement", rule.rollingSetFloor, 0...1),
            ("rolling window", rule.rollingWindowDays, 1...60),
            ("maximum recovered-day gap", rule.maxRecoveredDayGap, 1...60),
            ("sets per exercise cap", rule.maxSetsPerExercise, 1...10),
            ("weekly set target", rule.weeklySetTarget, 0...100),
            ("daily set cap", rule.dailySetCap, 1...20)
        ]
        for (field, value, range) in fields where !range.contains(value) {
            throw AdaptiveProgramValidationError.invalidMuscleLimit(
                muscle: rule.muscle,
                field: field,
                value: value
            )
        }
    }

    private static func validate(
        complex: AdaptiveExerciseComplexDraft,
        position: Int,
        draft: AdaptiveProgramDraft,
        exercisesById: [UUID: Exercise],
        rulesByMuscle: [MuscleGroup: AdaptiveMuscleRuleDraft]
    ) throws {
        let name = complex.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw AdaptiveProgramValidationError.emptyComplexName(position: position) }
        if complex.components.isEmpty { throw AdaptiveProgramValidationError.emptyComplex(name: name) }
        if complex.components.count > draft.globalMaxMovements {
            throw AdaptiveProgramValidationError.complexExceedsMovementCap(
                name: name,
                count: complex.components.count,
                cap: draft.globalMaxMovements
            )
        }

        var seenExerciseIds = Set<UUID>()
        var attributesComplexPrimary = false
        for component in complex.components {
            guard let exercise = exercisesById[component.exerciseId] else {
                throw AdaptiveProgramValidationError.exerciseNotFound(component.exerciseId)
            }
            guard exercise.isActive else {
                throw AdaptiveProgramValidationError.inactiveExercise(name: exercise.name)
            }
            guard exercise.primaryMuscle == component.primaryMuscle else {
                throw AdaptiveProgramValidationError.componentMuscleMismatch(
                    exercise: exercise.name,
                    expected: component.primaryMuscle,
                    actual: exercise.primaryMuscle
                )
            }
            guard seenExerciseIds.insert(component.exerciseId).inserted else {
                throw AdaptiveProgramValidationError.duplicateExerciseOccurrence(
                    complex: name,
                    exercise: exercise.name
                )
            }
            if component.secondaryMuscle == component.primaryMuscle {
                throw AdaptiveProgramValidationError.invalidSecondaryMuscle(exercise: exercise.name)
            }
            guard rulesByMuscle[component.primaryMuscle] != nil else {
                throw AdaptiveProgramValidationError.missingMuscleRule(component.primaryMuscle)
            }
            if component.prescribedSetCount < 1 || component.prescribedSetCount > 4 {
                throw AdaptiveProgramValidationError.invalidComponentSets(
                    exercise: exercise.name,
                    count: component.prescribedSetCount,
                    cap: 4
                )
            }
            if component.primaryMuscle == complex.primaryMuscle || component.secondaryMuscle == complex.primaryMuscle {
                attributesComplexPrimary = true
            }
        }
        if !attributesComplexPrimary {
            throw AdaptiveProgramValidationError.complexDoesNotAttributePrimary(
                name: name,
                muscle: complex.primaryMuscle
            )
        }
    }
}

enum AdaptiveExerciseSelectionPreferenceService {
    @discardableResult
    static func ensureRequestedDefaults(modelContext: ModelContext) throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<AdaptiveExerciseSelectionPreference>())
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let existingMuscles = Set(existing.map(\.muscle))
        var inserted = 0

        for muscle in MuscleGroup.allCases where !existingMuscles.contains(muscle) {
            let mode: AdaptiveExerciseSelectionMode
            let pinnedExerciseId: UUID?
            let activeForMuscle = exercises
                .filter { $0.isActive && $0.primaryMuscle == muscle }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let generallyAvailable = activeForMuscle
                .filter { $0.equipment != .machine }
                .map(\.id)
            let broadUpperBodyPool = activeForMuscle
                .filter {
                    switch muscle {
                    case .triceps, .biceps, .sideDelts, .forearms:
                        return $0.type == .isolation
                    default:
                        return true
                    }
                }
                .map(\.id)
            switch muscle {
            case .chest, .back, .triceps, .biceps, .sideDelts, .forearms:
                mode = .rotateRecent
                pinnedExerciseId = nil
            case .quads:
                let beltSquat = exercises.first {
                    $0.isActive && $0.primaryMuscle == .quads && $0.name == "Belt Squat"
                }
                mode = beltSquat == nil ? .repeatLast : .pinned
                pinnedExerciseId = beltSquat?.id
            case .hamstrings:
                let stiffLegDeadlift = exercises.first {
                    $0.isActive
                        && $0.primaryMuscle == .hamstrings
                        && $0.name == "Stiff-Leg Deadlift"
                }
                mode = stiffLegDeadlift == nil ? .repeatLast : .pinned
                pinnedExerciseId = stiffLegDeadlift?.id
            default:
                mode = .repeatLast
                pinnedExerciseId = nil
            }
            var eligibleExerciseIds: [UUID]
            switch muscle {
            case .chest, .back, .triceps, .biceps, .sideDelts, .forearms:
                eligibleExerciseIds = broadUpperBodyPool
            default:
                eligibleExerciseIds = pinnedExerciseId.map { [$0] } ?? generallyAvailable
            }
            if muscle == .hamstrings,
               let reverseHyper = exercises.first(where: {
                   $0.isActive && $0.primaryMuscle == .hamstrings && $0.name == "Reverse Hyper"
               }),
               !eligibleExerciseIds.contains(reverseHyper.id) {
                eligibleExerciseIds.append(reverseHyper.id)
            }
            modelContext.insert(
                AdaptiveExerciseSelectionPreference(
                    muscle: muscle,
                    mode: mode,
                    pinnedExerciseId: pinnedExerciseId,
                    eligibleExerciseIds: eligibleExerciseIds
                )
            )
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    static func resolved(
        muscle: MuscleGroup,
        preferences: [AdaptiveExerciseSelectionPreference]
    ) -> AdaptiveExerciseSelectionPreference? {
        preferences.first { $0.muscle == muscle }
    }
}
