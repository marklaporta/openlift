import Foundation
import SwiftData

struct MuscleReadinessInput: Equatable {
    var soreness: SorenessLevel
    var connectiveTissuePain: ConnectiveTissuePainLevel
    var eagerness: EagernessLevel

    var isHardBlocked: Bool {
        !soreness.allowsAutomaticTraining || connectiveTissuePain == .stop
    }
}

enum TrainingEvidenceKind: String, Equatable {
    case rotation
    case adaptiveComparable
    case adaptiveOverride
    case adHoc
}

struct TrainingLoadEvidence: Equatable {
    var sessionId: UUID
    var setEntryId: UUID
    var exerciseId: UUID
    var completedAt: Date
    var muscles: [MuscleGroup]
    var weight: Double
    var reps: Int
    var isSessionCompleted: Bool
    var isLocked: Bool
    var kind: TrainingEvidenceKind
    var complexDefinitionId: UUID?
    var componentPosition: Int?
}

struct MuscleLoadSummary: Equatable {
    var lockedSetCount: Int = 0
    var lastProductiveExposureAt: Date?
    var lastDirectProductiveExposureAt: Date?
}

struct TrainingLoadLedger: Equatable {
    var byMuscle: [MuscleGroup: MuscleLoadSummary]

    subscript(_ muscle: MuscleGroup) -> MuscleLoadSummary {
        byMuscle[muscle] ?? MuscleLoadSummary()
    }
}

enum TrainingLoadLedgerService {
    static func build(
        evidence: [TrainingLoadEvidence],
        asOf: Date,
        rollingWindowDays: [MuscleGroup: Int],
        calendar: Calendar = .current
    ) -> TrainingLoadLedger {
        var summaries = Dictionary(
            uniqueKeysWithValues: MuscleGroup.allCases.map { ($0, MuscleLoadSummary()) }
        )

        for item in evidence where
            item.isSessionCompleted && item.isLocked && item.reps > 0 && item.completedAt <= asOf {
            for muscle in Set(item.muscles) {
                var summary = summaries[muscle] ?? MuscleLoadSummary()
                if summary.lastProductiveExposureAt == nil || item.completedAt > summary.lastProductiveExposureAt! {
                    summary.lastProductiveExposureAt = item.completedAt
                }
                if item.muscles.first == muscle,
                   summary.lastDirectProductiveExposureAt == nil
                    || item.completedAt > summary.lastDirectProductiveExposureAt! {
                    summary.lastDirectProductiveExposureAt = item.completedAt
                }
                let window = rollingWindowDays[muscle] ?? 7
                let threshold = calendar.date(byAdding: .day, value: -window, to: asOf) ?? .distantPast
                if item.completedAt >= threshold {
                    summary.lockedSetCount += 1
                }
                summaries[muscle] = summary
            }
        }
        return TrainingLoadLedger(byMuscle: summaries)
    }

    static func storedEvidence(
        sessions: [Session],
        setEntries: [SetEntry],
        exercises: [Exercise],
        adaptivePlans: [GeneratedWorkoutPlan],
        occurrenceLinks: [AdaptiveSetOccurrenceLink],
        overrides: [AdaptiveOverrideEvent]
    ) -> [TrainingLoadEvidence] {
        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let plansById = Dictionary(uniqueKeysWithValues: adaptivePlans.map { ($0.id, $0) })
        let linksBySetEntry = Dictionary(uniqueKeysWithValues: occurrenceLinks.map { ($0.setEntryId, $0) })
        let substitutedOccurrences = Set(
            overrides
                .filter { $0.kind == .substituteExercise }
                .compactMap(\.occurrenceId)
        )

        var snapshotsByOccurrence: [UUID: (plan: GeneratedWorkoutPlan, complex: PlannedComplexSnapshot, exercise: PlannedExerciseSnapshot)] = [:]
        for plan in adaptivePlans {
            for complex in plan.complexes {
                for exercise in complex.exercises {
                    snapshotsByOccurrence[exercise.occurrenceId] = (plan, complex, exercise)
                }
            }
        }

        return setEntries.compactMap { entry in
            guard let session = sessionsById[entry.sessionId],
                  let exercise = exercisesById[entry.exerciseId] else { return nil }
            let completed = session.status == .completed && session.finishedAt != nil
            let completedAt = session.finishedAt ?? session.createdAt

            if let link = linksBySetEntry[entry.id],
               let snapshot = snapshotsByOccurrence[link.occurrenceId],
               plansById[link.generatedPlanId]?.id == snapshot.plan.id {
                let substituted = substitutedOccurrences.contains(link.occurrenceId)
                let muscles = [snapshot.exercise.primaryMuscle, snapshot.exercise.secondaryMuscle]
                    .compactMap { $0 }
                return TrainingLoadEvidence(
                    sessionId: session.id,
                    setEntryId: entry.id,
                    exerciseId: entry.exerciseId,
                    completedAt: completedAt,
                    muscles: muscles,
                    weight: entry.weight,
                    reps: entry.reps,
                    isSessionCompleted: completed,
                    isLocked: entry.isLocked,
                    kind: substituted ? .adaptiveOverride : .adaptiveComparable,
                    complexDefinitionId: substituted ? nil : snapshot.complex.sourceDefinitionId,
                    componentPosition: substituted ? nil : snapshot.exercise.position
                )
            }

            let isAdHoc = session.dayLabelSnapshot == "Off-Schedule"
                || session.cycleNameSnapshot == "Off-Schedule"
            return TrainingLoadEvidence(
                sessionId: session.id,
                setEntryId: entry.id,
                exerciseId: entry.exerciseId,
                completedAt: completedAt,
                muscles: [exercise.primaryMuscle],
                weight: entry.weight,
                reps: entry.reps,
                isSessionCompleted: completed,
                isLocked: entry.isLocked,
                kind: isAdHoc ? .adHoc : .rotation,
                complexDefinitionId: nil,
                componentPosition: nil
            )
        }
    }

    static func storedAdaptiveEvidence(
        sessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        plans: [GeneratedWorkoutPlan],
        overrides: [AdaptiveOverrideEvent],
        exercises: [Exercise]
    ) -> [TrainingLoadEvidence] {
        let completedSessions = Dictionary(
            uniqueKeysWithValues: sessions
                .filter { $0.status == .completed && $0.finishedAt != nil }
                .map { ($0.id, $0) }
        )
        let plansById = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let substitutedOccurrences = Set(
            overrides
                .filter { $0.kind == .substituteExercise }
                .compactMap(\.occurrenceId)
        )
        var snapshotsByOccurrence: [UUID: (complex: PlannedComplexSnapshot, exercise: PlannedExerciseSnapshot)] = [:]
        for plan in plans {
            for complex in plan.complexes {
                for exercise in complex.exercises {
                    snapshotsByOccurrence[exercise.occurrenceId] = (complex, exercise)
                }
            }
        }

        return setEntries.compactMap { entry in
            guard let session = completedSessions[entry.adaptiveSessionId],
                  let snapshot = snapshotsByOccurrence[entry.occurrenceId],
                  plansById[session.generatedPlanId] != nil else { return nil }
            let substituted = substitutedOccurrences.contains(entry.occurrenceId)
            let muscles: [MuscleGroup]
            if substituted, let actualExercise = exercisesById[entry.exerciseId] {
                muscles = [actualExercise.primaryMuscle]
            } else {
                muscles = [snapshot.exercise.primaryMuscle, snapshot.exercise.secondaryMuscle].compactMap { $0 }
            }
            return TrainingLoadEvidence(
                sessionId: session.id,
                setEntryId: entry.id,
                exerciseId: entry.exerciseId,
                completedAt: session.finishedAt!,
                muscles: muscles,
                weight: entry.weight,
                reps: entry.reps,
                isSessionCompleted: true,
                isLocked: entry.isLocked,
                kind: substituted ? .adaptiveOverride : .adaptiveComparable,
                complexDefinitionId: substituted ? nil : snapshot.complex.sourceDefinitionId,
                componentPosition: substituted ? nil : snapshot.exercise.position
            )
        }
    }
}

struct AdaptiveWorkoutCapacity: Equatable {
    var maxMuscleGroupCount: Int
    var maxExerciseCount: Int
    var maxExercisesPerMuscle: Int
    var maxWorkingSetCount: Int
    var maxSetsPerExercise: Int

    static let initial = AdaptiveWorkoutCapacity(
        maxMuscleGroupCount: 5,
        maxExerciseCount: 7,
        maxExercisesPerMuscle: 2,
        maxWorkingSetCount: 15,
        maxSetsPerExercise: 4
    )
    static let legacy = AdaptiveWorkoutCapacity(
        maxMuscleGroupCount: 12,
        maxExerciseCount: 100,
        maxExercisesPerMuscle: 20,
        maxWorkingSetCount: 1_000,
        maxSetsPerExercise: 10
    )

    init(
        maxMuscleGroupCount: Int,
        maxExerciseCount: Int,
        maxExercisesPerMuscle: Int,
        maxWorkingSetCount: Int,
        maxSetsPerExercise: Int
    ) {
        self.maxMuscleGroupCount = maxMuscleGroupCount
        self.maxExerciseCount = maxExerciseCount
        self.maxExercisesPerMuscle = maxExercisesPerMuscle
        self.maxWorkingSetCount = maxWorkingSetCount
        self.maxSetsPerExercise = maxSetsPerExercise
    }

    init(_ preference: AdaptiveWorkoutCapacityPreference) {
        self.init(
            maxMuscleGroupCount: preference.maxMuscleGroupCount,
            maxExerciseCount: preference.maxExerciseCount,
            maxExercisesPerMuscle: preference.maxExercisesPerMuscle,
            maxWorkingSetCount: preference.maxWorkingSetCount,
            maxSetsPerExercise: preference.maxSetsPerExercise
        )
    }
}

struct AdaptiveExposureRule: Equatable {
    var muscle: MuscleGroup
    var isAutomaticPlanningEnabled: Bool
    var normalSetCount: Int
    var cadenceKind: AdaptiveCadenceKind
    var minimumCalendarDays: Int
    var cadencePattern: [Int]
    var exerciseSplitKind: AdaptiveExerciseSplitKind
    var firstSplitSetCount: Int
    var secondSplitSetCount: Int
}

struct AdaptiveMuscleExposureStatus: Equatable {
    var muscle: MuscleGroup
    var rule: AdaptiveExposureRule
    var lastDirectExposureAt: Date?
    var nextEligibleAt: Date?
    var daysOverdue: Int
    var soreness: SorenessLevel
    var isEligible: Bool
}

enum AdaptiveExposureControllerService {
    static let automaticPriority: [MuscleGroup] = [
        .chest, .back, .quads, .hamstrings, .triceps, .biceps, .sideDelts
    ]

    static func defaultRule(for muscle: MuscleGroup) -> AdaptiveExposureRule {
        switch muscle {
        case .back:
            return rule(
                muscle, sets: 6, days: 2, split: .backVerticalHorizontal,
                first: 3, second: 3
            )
        case .chest:
            return rule(
                muscle, sets: 4, days: 2, split: .chestCompoundIsolation,
                first: 2, second: 2
            )
        case .quads, .hamstrings:
            return rule(muscle, sets: 3, days: 3)
        case .triceps, .biceps:
            return rule(muscle, sets: 3, days: 2)
        case .sideDelts:
            var value = rule(muscle, sets: 3, days: 2)
            value.cadenceKind = .lateralDelts2221
            value.cadencePattern = [2, 2, 2, 1]
            return value
        case .forearms, .glutes, .calves, .abs, .traps:
            var value = rule(muscle, sets: 3, days: 2)
            value.isAutomaticPlanningEnabled = false
            return value
        }
    }

    static func configurations(
        for program: AdaptiveProgram,
        allConfigurations: [AdaptiveMuscleExposureConfiguration]
    ) -> [MuscleGroup: AdaptiveExposureRule] {
        let stored = Dictionary(
            uniqueKeysWithValues: allConfigurations
                .filter { $0.adaptiveProgramId == program.id }
                .map { ($0.muscle, rule(from: $0)) }
        )
        return Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            (muscle, stored[muscle] ?? defaultRule(for: muscle))
        })
    }

    /// Adds V8 controller rows only when the active program has no open plan.
    /// Existing profile graphs and completed history are never rewritten.
    @discardableResult
    static func migrateActiveProgramIfNeeded(
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        guard let program = AdaptiveProgramService.activeProgram(from: programs) else { return 0 }
        let existing = try modelContext.fetch(
            FetchDescriptor<AdaptiveMuscleExposureConfiguration>()
        ).filter { $0.adaptiveProgramId == program.id }
        guard existing.count < MuscleGroup.allCases.count else { return 0 }

        let openPlans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        guard !openPlans.contains(where: {
            $0.adaptiveProgramId == program.id && $0.status != .completed
        }) else {
            return 0
        }

        let rulesByMuscle = Dictionary(
            uniqueKeysWithValues: program.muscleRules.map { ($0.muscle, $0) }
        )
        let existingMuscles = Set(existing.map(\.muscle))
        var inserted = 0
        for muscle in MuscleGroup.allCases where !existingMuscles.contains(muscle) {
            var value = defaultRule(for: muscle)
            value.isAutomaticPlanningEnabled =
                automaticPriority.contains(muscle) && rulesByMuscle[muscle]?.isEnabled == true
            modelContext.insert(
                makeConfiguration(rule: value, program: program, effectiveAt: now)
            )
            inserted += 1
        }

        let capacities = try modelContext.fetch(
            FetchDescriptor<AdaptiveWorkoutCapacityPreference>()
        )
        if let capacity = capacities.first(where: { $0.adaptiveProgramId == program.id }) {
            capacity.maxWorkingSetCount = min(capacity.maxWorkingSetCount, 15)
            capacity.updatedAt = now
        } else {
            modelContext.insert(
                AdaptiveWorkoutCapacityPreference(
                    adaptiveProgramId: program.id,
                    maxWorkingSetCount: 15,
                    updatedAt: now
                )
            )
            inserted += 1
        }

        // Reverse Hypers remain available for manual recovery work, but are
        // removed from every automatic exercise-selection pool.
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let reverseHyperIds = Set(exercises.filter(isReverseHyper).map(\.id))
        if !reverseHyperIds.isEmpty {
            let preferences = try modelContext.fetch(
                FetchDescriptor<AdaptiveExerciseSelectionPreference>()
            )
            for preference in preferences {
                preference.eligibleExerciseIds.removeAll { reverseHyperIds.contains($0) }
                if preference.pinnedExerciseId.map(reverseHyperIds.contains) == true {
                    preference.pinnedExerciseId = nil
                    preference.mode = .repeatLast
                }
            }
        }

        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    static func insertConfigurations(
        for program: AdaptiveProgram,
        rules: [AdaptiveExposureRule],
        modelContext: ModelContext,
        effectiveAt: Date
    ) {
        for rule in rules {
            modelContext.insert(
                makeConfiguration(rule: rule, program: program, effectiveAt: effectiveAt)
            )
        }
    }

    static func statuses(
        rules: [MuscleGroup: AdaptiveExposureRule],
        readiness: [MuscleGroup: MuscleReadinessInput],
        evidence: [TrainingLoadEvidence],
        exercises: [Exercise],
        asOf: Date,
        calendar: Calendar = .current
    ) -> [MuscleGroup: AdaptiveMuscleExposureStatus] {
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            let rule = rules[muscle] ?? defaultRule(for: muscle)
            let exposureDays = directExposureDays(
                evidence: evidence,
                muscle: muscle,
                exercisesById: exercisesById,
                asOf: asOf,
                calendar: calendar
            )
            let last = exposureDays.last
            let interval = cadenceInterval(rule: rule, completedExposureCount: exposureDays.count)
            let next = last.flatMap {
                calendar.date(byAdding: .day, value: interval, to: $0)
            }
            let today = calendar.startOfDay(for: asOf)
            let due = next.map(calendar.startOfDay(for:))
            let overdue = due.map {
                max(0, calendar.dateComponents([.day], from: $0, to: today).day ?? 0)
            } ?? Int.max
            let soreness = readiness[muscle]?.soreness ?? .high
            let readinessAllows = soreness.allowsAutomaticTraining
                && readiness[muscle]?.connectiveTissuePain != .stop
            let isDue = due.map { $0 <= today } ?? true
            return (
                muscle,
                AdaptiveMuscleExposureStatus(
                    muscle: muscle,
                    rule: rule,
                    lastDirectExposureAt: last,
                    nextEligibleAt: due,
                    daysOverdue: overdue,
                    soreness: soreness,
                    isEligible: automaticPriority.contains(muscle)
                        && rule.isAutomaticPlanningEnabled
                        && readinessAllows
                        && isDue
                )
            )
        })
    }

    static func rankedEligible(
        _ statuses: [MuscleGroup: AdaptiveMuscleExposureStatus]
    ) -> [AdaptiveMuscleExposureStatus] {
        statuses.values.filter(\.isEligible).sorted { left, right in
            if left.daysOverdue != right.daysOverdue {
                return left.daysOverdue > right.daysOverdue
            }
            let leftPriority = automaticPriority.firstIndex(of: left.muscle) ?? Int.max
            let rightPriority = automaticPriority.firstIndex(of: right.muscle) ?? Int.max
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftSoreness = left.soreness == .none ? 0 : 1
            let rightSoreness = right.soreness == .none ? 0 : 1
            if leftSoreness != rightSoreness { return leftSoreness < rightSoreness }
            let leftLast = left.lastDirectExposureAt ?? .distantPast
            let rightLast = right.lastDirectExposureAt ?? .distantPast
            if leftLast != rightLast { return leftLast < rightLast }
            return left.muscle.rawValue < right.muscle.rawValue
        }
    }

    static func isReverseHyper(_ exercise: Exercise) -> Bool {
        exercise.name.lowercased().contains("reverse hyper")
    }

    private static func directExposureDays(
        evidence: [TrainingLoadEvidence],
        muscle: MuscleGroup,
        exercisesById: [UUID: Exercise],
        asOf: Date,
        calendar: Calendar
    ) -> [Date] {
        let dates = evidence.compactMap { item -> Date? in
            guard item.isSessionCompleted,
                  item.isLocked,
                  item.reps > 0,
                  item.completedAt <= asOf,
                  item.muscles.first == muscle,
                  let exercise = exercisesById[item.exerciseId],
                  !isReverseHyper(exercise) else {
                return nil
            }
            return calendar.startOfDay(for: item.completedAt)
        }
        return Array(Set(dates)).sorted()
    }

    private static func cadenceInterval(
        rule: AdaptiveExposureRule,
        completedExposureCount: Int
    ) -> Int {
        guard rule.cadenceKind == .lateralDelts2221,
              !rule.cadencePattern.isEmpty,
              completedExposureCount > 0 else {
            return max(1, rule.minimumCalendarDays)
        }
        return max(1, rule.cadencePattern[(completedExposureCount - 1) % rule.cadencePattern.count])
    }

    private static func rule(
        _ muscle: MuscleGroup,
        sets: Int,
        days: Int,
        split: AdaptiveExerciseSplitKind = .none,
        first: Int = 0,
        second: Int = 0
    ) -> AdaptiveExposureRule {
        AdaptiveExposureRule(
            muscle: muscle,
            isAutomaticPlanningEnabled: automaticPriority.contains(muscle),
            normalSetCount: sets,
            cadenceKind: .fixedCalendarDays,
            minimumCalendarDays: days,
            cadencePattern: [],
            exerciseSplitKind: split,
            firstSplitSetCount: first,
            secondSplitSetCount: second
        )
    }

    private static func rule(
        from configuration: AdaptiveMuscleExposureConfiguration
    ) -> AdaptiveExposureRule {
        AdaptiveExposureRule(
            muscle: configuration.muscle,
            isAutomaticPlanningEnabled: configuration.isAutomaticPlanningEnabled,
            normalSetCount: configuration.normalSetCount,
            cadenceKind: configuration.cadenceKind,
            minimumCalendarDays: configuration.minimumCalendarDays,
            cadencePattern: configuration.cadencePattern,
            exerciseSplitKind: configuration.exerciseSplitKind,
            firstSplitSetCount: configuration.firstSplitSetCount,
            secondSplitSetCount: configuration.secondSplitSetCount
        )
    }

    private static func makeConfiguration(
        rule: AdaptiveExposureRule,
        program: AdaptiveProgram,
        effectiveAt: Date
    ) -> AdaptiveMuscleExposureConfiguration {
        AdaptiveMuscleExposureConfiguration(
            adaptiveProgramId: program.id,
            lineageId: program.lineageId,
            muscle: rule.muscle,
            isAutomaticPlanningEnabled: rule.isAutomaticPlanningEnabled,
            normalSetCount: rule.normalSetCount,
            cadenceKind: rule.cadenceKind,
            minimumCalendarDays: rule.minimumCalendarDays,
            cadencePattern: rule.cadencePattern,
            exerciseSplitKind: rule.exerciseSplitKind,
            firstSplitSetCount: rule.firstSplitSetCount,
            secondSplitSetCount: rule.secondSplitSetCount,
            effectiveAt: effectiveAt
        )
    }
}

struct AdaptiveMuscleVolumeStatus: Equatable {
    var muscle: MuscleGroup
    var weeklySetTarget: Int
    var dailySetCap: Int
    /// Positive values are accumulated credit; negative values are debt.
    var balance: Double

    var setsBehind: Double { max(0, -balance) }
    var normalizedDebt: Double {
        guard weeklySetTarget > 0 else { return 0 }
        return setsBehind / Double(weeklySetTarget)
    }
}

enum AdaptiveVolumeControllerService {
    static func defaultWeeklyTarget(for muscle: MuscleGroup) -> Int {
        switch muscle {
        case .back: return 21
        case .sideDelts: return 12
        case .chest: return 14
        case .quads: return 11
        case .biceps, .triceps: return 8
        case .hamstrings, .forearms, .calves: return 6
        case .glutes, .abs, .traps: return 0
        }
    }

    static func legacyWeeklyTarget(for muscle: MuscleGroup) -> Int {
        switch muscle {
        case .back, .sideDelts: return 12
        case .chest, .biceps, .triceps: return 9
        case .quads, .forearms, .calves: return 6
        case .hamstrings: return 4
        case .glutes, .abs, .traps: return 0
        }
    }

    static func capacity(
        for program: AdaptiveProgram,
        preferences: [AdaptiveWorkoutCapacityPreference]
    ) -> AdaptiveWorkoutCapacity {
        preferences.first { $0.adaptiveProgramId == program.id }
            .map(AdaptiveWorkoutCapacity.init) ?? .initial
    }

    static func targets(
        for program: AdaptiveProgram,
        allTargets: [AdaptiveMuscleVolumeTarget]
    ) -> [MuscleGroup: AdaptiveMuscleVolumeTarget] {
        Dictionary(
            uniqueKeysWithValues: allTargets
                .filter { $0.adaptiveProgramId == program.id }
                .map { ($0.muscle, $0) }
        )
    }

    /// Creates only missing V7 rows. The first anchor for an active lineage is
    /// seeded from all completed direct work in the previous seven days,
    /// regardless of whether it came from Adaptive, Fixed Cycle, or Log.
    @discardableResult
    static func ensureStoredConfiguration(
        modelContext: ModelContext,
        now: Date = .now,
        saveChanges: Bool = true
    ) throws -> Int {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        guard let activeProgram = AdaptiveProgramService.activeProgram(from: programs) else { return 0 }
        var allTargets = try modelContext.fetch(FetchDescriptor<AdaptiveMuscleVolumeTarget>())
        var capacities = try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutCapacityPreference>())
        var anchors = try modelContext.fetch(FetchDescriptor<AdaptiveMuscleVolumeAnchor>())
        var inserted = 0

        for muscle in MuscleGroup.allCases where !allTargets.contains(where: {
            $0.adaptiveProgramId == activeProgram.id && $0.muscle == muscle
        }) {
            let target = AdaptiveMuscleVolumeTarget(
                adaptiveProgramId: activeProgram.id,
                lineageId: activeProgram.lineageId,
                muscle: muscle,
                weeklySetTarget: defaultWeeklyTarget(for: muscle),
                dailySetCap: 4,
                effectiveAt: now
            )
            modelContext.insert(target)
            allTargets.append(target)
            inserted += 1
        }

        if !capacities.contains(where: { $0.adaptiveProgramId == activeProgram.id }) {
            let capacity = AdaptiveWorkoutCapacityPreference(adaptiveProgramId: activeProgram.id)
            modelContext.insert(capacity)
            capacities.append(capacity)
            inserted += 1

            // V6 had only this single workout-size default. Adopt the new
            // explicitly requested five-muscle starting capacity once when the
            // V7 configuration is first created.
            let sizePreferences = try modelContext.fetch(
                FetchDescriptor<AdaptiveWorkoutSizePreference>()
            )
            if let size = sizePreferences.first(where: {
                $0.adaptiveProgramId == activeProgram.id
            }) {
                size.defaultComplexCount = min(
                    AdaptiveWorkoutCapacity.initial.maxMuscleGroupCount,
                    max(1, activeProgram.muscleRules.filter(\.isEnabled).count)
                )
                size.updatedAt = now
            }
        }

        let missingAnchorMuscles = MuscleGroup.allCases.filter { muscle in
            !anchors.contains {
                $0.lineageId == activeProgram.lineageId && $0.muscle == muscle
            }
        }
        if !missingAnchorMuscles.isEmpty {
            let evidence = try storedEvidence(modelContext: modelContext)
            let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
            let activeTargets = targets(for: activeProgram, allTargets: allTargets)
            for muscle in missingAnchorMuscles {
                let target = activeTargets[muscle]?.weeklySetTarget
                    ?? defaultWeeklyTarget(for: muscle)
                let recentDirectEvidence = directEvidence(evidence, for: muscle)
                    .filter { $0.completedAt >= sevenDaysAgo && $0.completedAt <= now }
                let recentDirectSets = recentDirectEvidence.count
                let bound = Double(max(0, target))
                let seed = min(bound, max(-bound, Double(recentDirectSets - target)))
                let anchor = AdaptiveMuscleVolumeAnchor(
                    lineageId: activeProgram.lineageId,
                    muscle: muscle,
                    activatedAt: now,
                    initialBalance: seed,
                    seededDirectSetEntryIds: recentDirectEvidence.map(\.setEntryId)
                )
                modelContext.insert(anchor)
                anchors.append(anchor)
                inserted += 1
            }
        }

        if inserted > 0 && saveChanges { try modelContext.save() }
        return inserted
    }

    /// Advances only a complete, untouched original V7 default target vector.
    /// The old program and target rows remain immutable history; the replacement
    /// program gets a new effective-dated target vector. Any customized target
    /// prevents the migration.
    @discardableResult
    static func migrateLegacyDefaultTargetVector(
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Bool {
        let programs = try modelContext.fetch(FetchDescriptor<AdaptiveProgram>())
        guard let activeProgram = AdaptiveProgramService.activeProgram(from: programs) else {
            return false
        }
        let allTargets = try modelContext.fetch(FetchDescriptor<AdaptiveMuscleVolumeTarget>())
        let currentTargets = targets(for: activeProgram, allTargets: allTargets)
        guard currentTargets.count == MuscleGroup.allCases.count,
              MuscleGroup.allCases.allSatisfy({
                  currentTargets[$0]?.weeklySetTarget == legacyWeeklyTarget(for: $0)
              }) else {
            return false
        }
        let openPlans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        guard !openPlans.contains(where: {
            $0.adaptiveProgramId == activeProgram.id && $0.status != .completed
        }) else {
            return false
        }

        let replacement = AdaptiveProgram(
            lineageId: activeProgram.lineageId,
            version: activeProgram.version + 1,
            name: activeProgram.name,
            createdAt: now,
            isActiveVersion: true,
            isReviewedForUse: activeProgram.isReviewedForUse,
            globalMaxMovements: activeProgram.globalMaxMovements,
            maxDifficultyCost: activeProgram.maxDifficultyCost,
            muscleRules: activeProgram.muscleRules.map {
                AdaptiveMuscleRule(
                    muscle: $0.muscle,
                    priorityRank: $0.priorityRank,
                    rollingSetFloor: $0.rollingSetFloor,
                    rollingWindowDays: $0.rollingWindowDays,
                    maxRecoveredDayGap: $0.maxRecoveredDayGap,
                    maxExercisesPerExposure: $0.maxExercisesPerExposure,
                    maxSetsPerExercise: $0.maxSetsPerExercise,
                    isEnabled: $0.isEnabled
                )
            },
            complexes: activeProgram.complexes.map { complex in
                AdaptiveExerciseComplex(
                    definitionId: complex.definitionId,
                    version: complex.version + 1,
                    name: complex.name,
                    position: complex.position,
                    primaryMuscle: complex.primaryMuscle,
                    qualifiesForPrimaryFloor: complex.qualifiesForPrimaryFloor,
                    isEnabled: complex.isEnabled,
                    components: complex.components.map {
                        AdaptiveComplexComponent(
                            position: $0.position,
                            exerciseId: $0.exerciseId,
                            prescribedSetCount: $0.prescribedSetCount,
                            primaryMuscle: $0.primaryMuscle,
                            secondaryMuscle: $0.secondaryMuscle,
                            difficulty: $0.difficulty
                        )
                    }
                )
            }
        )
        for program in programs where program.isActiveVersion {
            program.isActiveVersion = false
        }
        modelContext.insert(replacement)

        let sizePreferences = try modelContext.fetch(
            FetchDescriptor<AdaptiveWorkoutSizePreference>()
        )
        let oldSize = sizePreferences.first {
            $0.adaptiveProgramId == activeProgram.id
        }
        modelContext.insert(
            AdaptiveWorkoutSizePreference(
                adaptiveProgramId: replacement.id,
                defaultComplexCount: oldSize?.defaultComplexCount
                    ?? max(1, min(activeProgram.globalMaxMovements, 12)),
                updatedAt: now
            )
        )

        let capacities = try modelContext.fetch(
            FetchDescriptor<AdaptiveWorkoutCapacityPreference>()
        )
        let oldCapacity = capacities.first {
            $0.adaptiveProgramId == activeProgram.id
        }
        modelContext.insert(
            AdaptiveWorkoutCapacityPreference(
                adaptiveProgramId: replacement.id,
                maxMuscleGroupCount: oldCapacity?.maxMuscleGroupCount ?? 5,
                maxExerciseCount: oldCapacity?.maxExerciseCount ?? 7,
                maxExercisesPerMuscle: oldCapacity?.maxExercisesPerMuscle ?? 2,
                maxWorkingSetCount: oldCapacity?.maxWorkingSetCount ?? 20,
                maxSetsPerExercise: oldCapacity?.maxSetsPerExercise ?? 4,
                updatedAt: now
            )
        )

        for muscle in MuscleGroup.allCases {
            modelContext.insert(
                AdaptiveMuscleVolumeTarget(
                    adaptiveProgramId: replacement.id,
                    lineageId: replacement.lineageId,
                    muscle: muscle,
                    weeklySetTarget: defaultWeeklyTarget(for: muscle),
                    dailySetCap: currentTargets[muscle]?.dailySetCap ?? 4,
                    effectiveAt: now
                )
            )
        }
        try modelContext.save()
        return true
    }

    static func statuses(
        program: AdaptiveProgram,
        allTargets: [AdaptiveMuscleVolumeTarget],
        anchors: [AdaptiveMuscleVolumeAnchor],
        evidence: [TrainingLoadEvidence],
        asOf: Date
    ) -> [MuscleGroup: AdaptiveMuscleVolumeStatus] {
        let currentTargets = targets(for: program, allTargets: allTargets)
        return Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            let current = currentTargets[muscle]
            let fallbackTarget = defaultWeeklyTarget(for: muscle)
            let weeklyTarget = max(0, current?.weeklySetTarget ?? fallbackTarget)
            let dailyCap = max(1, current?.dailySetCap ?? 4)
            guard let anchor = anchors.first(where: {
                $0.lineageId == program.lineageId && $0.muscle == muscle
            }), anchor.activatedAt <= asOf else {
                return (
                    muscle,
                    AdaptiveMuscleVolumeStatus(
                        muscle: muscle,
                        weeklySetTarget: weeklyTarget,
                        dailySetCap: dailyCap,
                        balance: 0
                    )
                )
            }

            let targetChanges = allTargets
                .filter {
                    $0.lineageId == program.lineageId
                        && $0.muscle == muscle
                        && $0.effectiveAt <= asOf
                }
                .sorted {
                    if $0.effectiveAt != $1.effectiveAt { return $0.effectiveAt < $1.effectiveAt }
                    return $0.adaptiveProgramId.uuidString < $1.adaptiveProgramId.uuidString
                }
            var activeTarget = targetChanges.last(where: { $0.effectiveAt <= anchor.activatedAt })?
                .weeklySetTarget ?? weeklyTarget
            var balance = clipped(anchor.initialBalance, weeklyTarget: activeTarget)
            var cursor = anchor.activatedAt

            enum Event {
                case target(AdaptiveMuscleVolumeTarget)
                case completedSet(Date)

                var date: Date {
                    switch self {
                    case .target(let target): return target.effectiveAt
                    case .completedSet(let date): return date
                    }
                }

                var order: Int {
                    switch self {
                    case .target: return 0
                    case .completedSet: return 1
                    }
                }
            }

            var events: [Event] = targetChanges
                .filter { $0.effectiveAt > anchor.activatedAt }
                .map(Event.target)
            let seededIds = Set(anchor.seededDirectSetEntryIds)
            let seedWindowStart = anchor.activatedAt.addingTimeInterval(-7 * 86_400)
            events += directEvidence(evidence, for: muscle)
                .filter {
                    $0.completedAt >= seedWindowStart
                        && $0.completedAt <= anchor.activatedAt
                        && !seededIds.contains($0.setEntryId)
                }
                .map { _ in .completedSet(anchor.activatedAt) }
            events += directEvidence(evidence, for: muscle)
                .filter { $0.completedAt > anchor.activatedAt && $0.completedAt <= asOf }
                .map { .completedSet($0.completedAt) }
            events.sort {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.order < $1.order
            }

            for event in events {
                balance = accrue(
                    balance: balance,
                    weeklyTarget: activeTarget,
                    from: cursor,
                    to: event.date
                )
                cursor = event.date
                switch event {
                case .target(let target):
                    activeTarget = max(0, target.weeklySetTarget)
                    balance = clipped(balance, weeklyTarget: activeTarget)
                case .completedSet:
                    balance = clipped(balance + 1, weeklyTarget: activeTarget)
                }
            }
            balance = accrue(
                balance: balance,
                weeklyTarget: activeTarget,
                from: cursor,
                to: asOf
            )

            return (
                muscle,
                AdaptiveMuscleVolumeStatus(
                    muscle: muscle,
                    weeklySetTarget: weeklyTarget,
                    dailySetCap: dailyCap,
                    balance: clipped(balance, weeklyTarget: weeklyTarget)
                )
            )
        })
    }

    static func storedEvidence(modelContext: ModelContext) throws -> [TrainingLoadEvidence] {
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let plans = try modelContext.fetch(FetchDescriptor<GeneratedWorkoutPlan>())
        let overrides = try modelContext.fetch(FetchDescriptor<AdaptiveOverrideEvent>())
        return TrainingLoadLedgerService.storedEvidence(
            sessions: try modelContext.fetch(FetchDescriptor<Session>()),
            setEntries: try modelContext.fetch(FetchDescriptor<SetEntry>()),
            exercises: exercises,
            adaptivePlans: plans,
            occurrenceLinks: try modelContext.fetch(FetchDescriptor<AdaptiveSetOccurrenceLink>()),
            overrides: overrides
        ) + TrainingLoadLedgerService.storedAdaptiveEvidence(
            sessions: try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>()),
            setEntries: try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>()),
            plans: plans,
            overrides: overrides,
            exercises: exercises
        )
    }

    private static func directEvidence(
        _ evidence: [TrainingLoadEvidence],
        for muscle: MuscleGroup
    ) -> [TrainingLoadEvidence] {
        evidence.filter {
            $0.isSessionCompleted
                && $0.isLocked
                && $0.reps > 0
                && $0.muscles.first == muscle
        }
    }

    private static func accrue(
        balance: Double,
        weeklyTarget: Int,
        from start: Date,
        to end: Date
    ) -> Double {
        guard end > start, weeklyTarget > 0 else {
            return clipped(balance, weeklyTarget: weeklyTarget)
        }
        let days = end.timeIntervalSince(start) / 86_400
        return clipped(
            balance - days * Double(weeklyTarget) / 7,
            weeklyTarget: weeklyTarget
        )
    }

    private static func clipped(_ balance: Double, weeklyTarget: Int) -> Double {
        let bound = Double(max(0, weeklyTarget))
        return min(bound, max(-bound, balance))
    }
}

struct AdaptivePlannerRejection: Equatable {
    var complexDefinitionId: UUID
    var code: String
}

struct AdaptivePlannedComponent: Equatable {
    var exerciseId: UUID
    var exerciseName: String
    var position: Int
    var primaryMuscle: MuscleGroup
    var secondaryMuscle: MuscleGroup?
    var difficulty: MovementDifficulty
    var prescribedSetCount: Int
}

struct AdaptivePlannedComplex: Equatable {
    var definitionId: UUID
    var version: Int
    var name: String
    var sourcePosition: Int
    var primaryMuscle: MuscleGroup
    var reasonCodes: [String]
    var components: [AdaptivePlannedComponent]
}

struct AdaptivePlanProposal: Equatable {
    var complexes: [AdaptivePlannedComplex]
    var totalMovements: Int
    var totalDifficultyCost: Int
    var muscleSetDose: [MuscleGroup: Int]
    var rejections: [AdaptivePlannerRejection]
}

struct AdaptivePlanConflict: Equatable {
    var muscle: MuscleGroup
    var requiredAdditionalSets: Int
    var code: String
}

enum AdaptivePlannerResult: Equatable {
    case proposal(AdaptivePlanProposal)
    case infeasible(AdaptivePlanConflict)
}

enum AdaptiveExerciseRoleService {
    static func difficulty(for exercise: Exercise) -> MovementDifficulty {
        exercise.type == .compound ? .hard : .easy
    }
}

enum BackMovementPattern: String, CaseIterable {
    case verticalPull
    case horizontalPull
}

enum BackMovementPatternService {
    static func pattern(for exercise: Exercise) -> BackMovementPattern? {
        guard exercise.primaryMuscle == .back else { return nil }
        let name = exercise.name
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
        if name.contains("row") {
            return .horizontalPull
        }
        if name.contains("pulldown")
            || name.contains("pull down")
            || name.contains("pull up")
            || name.contains("pullup")
            || name.contains("chin up")
            || name.contains("chinup") {
            return .verticalPull
        }
        return nil
    }
}

struct AdaptivePlanDecisionTrace: Equatable {
    var plannerVersion: Int
    var outcomeCode: String
    var selectedComplexDefinitionIds: [UUID]
    var selectedReasonCodes: [String]
    var rejectedCodesByComplex: [String]
    var conflictCode: String?
    var conflictMuscle: MuscleGroup?
}

enum AdaptivePlanService {
    static let plannerVersion = 10

    static func generate(
        program: AdaptiveProgram,
        exercises: [Exercise],
        readiness: [MuscleGroup: MuscleReadinessInput],
        ledger: TrainingLoadLedger,
        exposureStatuses: [MuscleGroup: AdaptiveMuscleExposureStatus] = [:],
        targetComplexCount: Int? = nil,
        capacity: AdaptiveWorkoutCapacity = .legacy,
        doseRecommendations: [UUID: [Int: DoseRecommendation]] = [:],
        exerciseSelections: [AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation] = [:],
        now: Date,
        calendar: Calendar = .current
    ) -> AdaptivePlannerResult {
        let controllerStatuses = exposureStatuses.isEmpty
            ? fallbackExposureStatuses(
                readiness: readiness,
                ledger: ledger,
                now: now,
                calendar: calendar
            )
            : exposureStatuses
        let enabledRules = program.muscleRules
            .filter {
                $0.isEnabled
                    && controllerStatuses[$0.muscle]?.rule.isAutomaticPlanningEnabled == true
                    && AdaptiveExposureControllerService.automaticPriority.contains($0.muscle)
            }
            .sorted {
                let left = AdaptiveExposureControllerService.automaticPriority.firstIndex(
                    of: $0.muscle
                ) ?? Int.max
                let right = AdaptiveExposureControllerService.automaticPriority.firstIndex(
                    of: $1.muscle
                ) ?? Int.max
                return left < right
            }
        let rules = Dictionary(uniqueKeysWithValues: enabledRules.map { ($0.muscle, $0) })
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        for rule in enabledRules where readiness[rule.muscle] == nil {
            return .infeasible(
                AdaptivePlanConflict(muscle: rule.muscle, requiredAdditionalSets: 0, code: "missing_readiness")
            )
        }

        var rejections: [AdaptivePlannerRejection] = []
        let rawCandidates = program.complexes
            .filter(\.isEnabled)
            .sorted(by: stableComplexOrder)
            .compactMap { complex -> AdaptivePlannedComplex? in
                let components = complex.components.sorted { $0.position < $1.position }
                guard !components.isEmpty else {
                    rejections.append(.init(complexDefinitionId: complex.definitionId, code: "empty_complex"))
                    return nil
                }
                var planned: [AdaptivePlannedComponent] = []
                var attributedMuscles = Set<MuscleGroup>()
                var appliedSelectionKeys = Set<AdaptiveExerciseSelectionKey>()
                var selectionReasonCodes: [String] = []
                let componentTypes = Dictionary(uniqueKeysWithValues: components.compactMap { component in
                    exercisesById[component.exerciseId].map { (component.position, $0.type) }
                })
                for component in components {
                    guard let exercise = exercisesById[component.exerciseId], exercise.isActive else {
                        rejections.append(.init(complexDefinitionId: complex.definitionId, code: "inactive_exercise"))
                        return nil
                    }
                    if AdaptiveExposureControllerService.isReverseHyper(exercise) {
                        rejections.append(
                            .init(
                                complexDefinitionId: complex.definitionId,
                                code: "manual_recovery_exercise"
                            )
                        )
                        return nil
                    }
                    if doseRecommendations[complex.definitionId]?[component.position]?.isPainBlocked == true {
                        rejections.append(.init(complexDefinitionId: complex.definitionId, code: "pain_block"))
                        return nil
                    }
                    let componentKey = AdaptiveExerciseSelectionKey(
                        muscle: component.primaryMuscle,
                        type: componentTypes[component.position] ?? exercise.type,
                        backPattern: BackMovementPatternService.pattern(for: exercise)
                    )
                    let coreFallbackKey = AdaptiveExerciseSelectionKey(
                        muscle: component.primaryMuscle,
                        type: .compound
                    )
                    let selectedKey: AdaptiveExerciseSelectionKey? = {
                        if exerciseSelections[componentKey] != nil { return componentKey }
                        let isSinglePrimaryComponent = components.filter {
                            $0.primaryMuscle == component.primaryMuscle
                        }.count == 1
                        if isSinglePrimaryComponent,
                           Self.prefersCompoundContinuity(component.primaryMuscle),
                           exerciseSelections[coreFallbackKey] != nil {
                            return coreFallbackKey
                        }
                        return nil
                    }()
                    let availableSelection = selectedKey.flatMap { key in
                        appliedSelectionKeys.contains(key) ? nil : exerciseSelections[key]
                    }
                    let selection = availableSelection?.canReplaceConfigured == false
                        ? nil
                        : availableSelection
                    let selectedExercise = selection?.exercise ?? exercise
                    if AdaptiveExposureControllerService.isReverseHyper(selectedExercise) {
                        rejections.append(
                            .init(
                                complexDefinitionId: complex.definitionId,
                                code: "manual_recovery_exercise"
                            )
                        )
                        return nil
                    }
                    if let selection, let selectedKey {
                        appliedSelectionKeys.insert(selectedKey)
                        selectionReasonCodes.append(
                            "\(component.primaryMuscle.rawValue)_\(selectedKey.type.rawValue)_\(selection.reasonCodeSuffix)"
                        )
                    }
                    let changedExercise = selectedExercise.id != component.exerciseId
                    attributedMuscles.insert(component.primaryMuscle)
                    if !changedExercise, let secondary = component.secondaryMuscle {
                        attributedMuscles.insert(secondary)
                    }
                    planned.append(
                        AdaptivePlannedComponent(
                            exerciseId: selectedExercise.id,
                            exerciseName: selectedExercise.name,
                            position: component.position,
                            primaryMuscle: component.primaryMuscle,
                            secondaryMuscle: changedExercise ? nil : component.secondaryMuscle,
                            difficulty: AdaptiveExerciseRoleService.difficulty(for: selectedExercise),
                            prescribedSetCount: component.prescribedSetCount
                        )
                    )
                }
                if complex.primaryMuscle == .back,
                   planned.count < program.globalMaxMovements {
                    let backCompounds = planned.compactMap { component -> (AdaptivePlannedComponent, BackMovementPattern)? in
                        guard exercisesById[component.exerciseId]?.type == .compound,
                              let exercise = exercisesById[component.exerciseId],
                              let pattern = BackMovementPatternService.pattern(for: exercise) else {
                            return nil
                        }
                        return (component, pattern)
                    }
                    if backCompounds.count == 1,
                       let missingPattern = BackMovementPattern.allCases.first(where: {
                           $0 != backCompounds[0].1
                       }),
                       let complementary = exerciseSelections[
                           AdaptiveExerciseSelectionKey(
                               muscle: .back,
                               type: .compound,
                               backPattern: missingPattern
                           )
                       ],
                       !planned.contains(where: { $0.exerciseId == complementary.exercise.id }) {
                        planned.append(
                            AdaptivePlannedComponent(
                                exerciseId: complementary.exercise.id,
                                exerciseName: complementary.exercise.name,
                                position: (planned.map(\.position).max() ?? -1) + 1,
                                primaryMuscle: .back,
                                secondaryMuscle: nil,
                                difficulty: AdaptiveExerciseRoleService.difficulty(
                                    for: complementary.exercise
                                ),
                                prescribedSetCount: backCompounds[0].0.prescribedSetCount
                            )
                        )
                        attributedMuscles.insert(.back)
                        selectionReasonCodes.append(
                            "back_\(missingPattern.rawValue)_coverage"
                        )
                    }
                }
                if attributedMuscles.contains(where: { readiness[$0]?.isHardBlocked == true }) {
                    rejections.append(.init(complexDefinitionId: complex.definitionId, code: "held_for_recovery"))
                    return nil
                }
                guard rules[complex.primaryMuscle] != nil else {
                    rejections.append(.init(complexDefinitionId: complex.definitionId, code: "primary_muscle_disabled"))
                    return nil
                }
                return AdaptivePlannedComplex(
                    definitionId: complex.definitionId,
                    version: complex.version,
                    name: complex.name,
                    sourcePosition: complex.position,
                    primaryMuscle: complex.primaryMuscle,
                    reasonCodes: selectionReasonCodes,
                    components: planned
                )
            }
        let candidates = rawCandidates.compactMap { candidate -> AdaptivePlannedComplex? in
            let exposureRule = controllerStatuses[candidate.primaryMuscle]?.rule
                ?? AdaptiveExposureControllerService.defaultRule(
                    for: candidate.primaryMuscle
                )
            let desiredSets = exposureRule.normalSetCount
            let distributed = applyingExerciseVariation(
                to: candidate,
                desiredSets: desiredSets,
                exercisesById: exercisesById,
                exerciseSelections: exerciseSelections
            )
            var dosed = applyingVolumeDose(
                to: distributed,
                desiredSets: desiredSets,
                maxSetsPerExercise: candidate.primaryMuscle == .back
                    || candidate.primaryMuscle == .chest
                    ? min(3, capacity.maxSetsPerExercise)
                    : capacity.maxSetsPerExercise
            )
            dosed = applyingConfiguredSplit(
                to: dosed,
                rule: exposureRule,
                exercisesById: exercisesById
            )
            guard configuredSplitIsSatisfied(
                by: dosed,
                rule: exposureRule,
                exercisesById: exercisesById
            ) else {
                rejections.append(
                    .init(
                        complexDefinitionId: candidate.definitionId,
                        code: "required_exercise_split_unavailable"
                    )
                )
                return nil
            }
            if candidate.primaryMuscle == .chest || candidate.primaryMuscle == .back {
                for index in dosed.components.indices
                    where dosed.components[index].primaryMuscle == dosed.primaryMuscle {
                    dosed.components[index].prescribedSetCount = min(
                        3,
                        dosed.components[index].prescribedSetCount
                    )
                }
            }
            return dosed
        }

        let exposureTarget = min(
            capacity.maxMuscleGroupCount,
            max(1, targetComplexCount ?? program.globalMaxMovements)
        )
        var selected: [AdaptivePlannedComplex] = []
        var selectedDefinitions = Set<UUID>()
        var selectedMuscles = Set<MuscleGroup>()
        var movements = 0
        var difficulty = 0
        var workingSets = 0
        var setDose: [MuscleGroup: Int] = [:]

        func fitFailure(for candidate: AdaptivePlannedComplex) -> String? {
            if selected.count >= exposureTarget { return "daily_exposure_target" }
            if selectedMuscles.contains(candidate.primaryMuscle) { return "muscle_already_selected" }
            if createsBannedSynergistPair(
                selectedMuscles: selectedMuscles,
                adding: candidate.primaryMuscle
            ) {
                return "synergist_pair_ban"
            }
            if movements + candidate.components.count > capacity.maxExerciseCount {
                return "exercise_count_cap"
            }
            let candidateSetCount = candidate.components.reduce(0) {
                $0 + $1.prescribedSetCount
            }
            if workingSets + candidateSetCount > capacity.maxWorkingSetCount {
                return "working_set_cap"
            }
            let combinedComponents = selected.flatMap(\.components) + candidate.components
            if hasRedundantSameMuscleCompounds(
                combinedComponents,
                exercisesById: exercisesById
            ) {
                return "multiple_compounds_same_muscle"
            }

            let exercisesPerMuscle = Dictionary(
                grouping: combinedComponents,
                by: \.primaryMuscle
            )
            if exercisesPerMuscle.values.contains(where: {
                $0.count > capacity.maxExercisesPerMuscle
            }) {
                return "exercises_per_muscle_cap"
            }
            for component in candidate.components {
                guard let primaryRule = rules[component.primaryMuscle] else {
                    return "primary_muscle_disabled"
                }
                let exerciseCap = candidate.primaryMuscle == .chest
                    || candidate.primaryMuscle == .back
                    ? min(3, capacity.maxSetsPerExercise)
                    : min(primaryRule.maxSetsPerExercise, capacity.maxSetsPerExercise)
                guard component.prescribedSetCount <= exerciseCap else {
                    return "sets_per_exercise_cap"
                }
            }
            return nil
        }

        func select(_ candidate: AdaptivePlannedComplex, reason: String) {
            var selectedCandidate = candidate
            selectedCandidate.reasonCodes.append(reason)
            selected.append(selectedCandidate)
            selectedDefinitions.insert(candidate.definitionId)
            selectedMuscles.insert(candidate.primaryMuscle)
            movements += candidate.components.count
            difficulty += candidate.components.reduce(0) { $0 + $1.difficulty.cost }
            workingSets += candidate.components.reduce(0) { $0 + $1.prescribedSetCount }
            for component in candidate.components {
                setDose[component.primaryMuscle, default: 0] += component.prescribedSetCount
            }
        }

        var dueReasonByMuscle: [MuscleGroup: String] = [:]
        for rule in enabledRules {
            if controllerStatuses[rule.muscle]?.isEligible == true {
                dueReasonByMuscle[rule.muscle] = "\(rule.muscle.rawValue)_cadence_due"
            }
        }

        // Preserve the pre-v5 configuration safeguard: a due exposure whose
        // only qualifying definitions violate the per-exercise set cap is a
        // real profile conflict, not an undersized but otherwise valid plan.
        for muscle in dueReasonByMuscle.keys {
            let qualifying = candidates.filter { candidate in
                candidate.primaryMuscle == muscle
                    && program.complexes.first(where: {
                        $0.definitionId == candidate.definitionId
                    })?.qualifiesForPrimaryFloor == true
            }
            guard !qualifying.isEmpty else { continue }
            let failures = qualifying.compactMap(fitFailure(for:))
            if failures.count == qualifying.count,
               failures.allSatisfy({ $0 == "sets_per_exercise_cap" }) {
                return .infeasible(
                    AdaptivePlanConflict(
                        muscle: muscle,
                        requiredAdditionalSets: 1,
                        code: "sets_per_exercise_cap"
                    )
                )
            }
        }

        // Pick one complex per muscle-group exposure. Quad/hamstring pairing is
        // a strong automatic-planning preference: it sorts behind every
        // otherwise usable alternative, but never becomes an infeasibility.
        while selected.count < exposureTarget {
            let remaining = candidates.filter {
                !selectedDefinitions.contains($0.definitionId)
                    && !selectedMuscles.contains($0.primaryMuscle)
                    && dueReasonByMuscle[$0.primaryMuscle] != nil
                    && fitFailure(for: $0) == nil
            }
            guard let candidate = remaining.sorted(by: { left, right in
                let leftPair = createsHardLowerBodyPair(selected: selected, adding: left)
                let rightPair = createsHardLowerBodyPair(selected: selected, adding: right)
                if leftPair != rightPair { return !leftPair }
                let leftOverdue = controllerStatuses[left.primaryMuscle]?.daysOverdue ?? -1
                let rightOverdue = controllerStatuses[right.primaryMuscle]?.daysOverdue ?? -1
                if leftOverdue != rightOverdue { return leftOverdue > rightOverdue }
                let leftPriority = AdaptiveExposureControllerService.automaticPriority.firstIndex(
                    of: left.primaryMuscle
                ) ?? Int.max
                let rightPriority = AdaptiveExposureControllerService.automaticPriority.firstIndex(
                    of: right.primaryMuscle
                ) ?? Int.max
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                let leftSoreness = sorenessRank(readiness[left.primaryMuscle]?.soreness)
                let rightSoreness = sorenessRank(readiness[right.primaryMuscle]?.soreness)
                if leftSoreness != rightSoreness { return leftSoreness < rightSoreness }
                let leftLast = controllerStatuses[left.primaryMuscle]?.lastDirectExposureAt
                    ?? .distantPast
                let rightLast = controllerStatuses[right.primaryMuscle]?.lastDirectExposureAt
                    ?? .distantPast
                if leftLast != rightLast { return leftLast < rightLast }
                return floorFitOrder(left, right)
            }).first else { break }
            select(
                candidate,
                reason: dueReasonByMuscle[candidate.primaryMuscle]
                    ?? "\(candidate.primaryMuscle.rawValue)_priority"
            )
        }

        for candidate in candidates where !selectedDefinitions.contains(candidate.definitionId) {
            rejections.append(
                .init(
                    complexDefinitionId: candidate.definitionId,
                    code: fitFailure(for: candidate) ?? "lower_priority_complex"
                )
            )
        }

        return .proposal(
            AdaptivePlanProposal(
                complexes: selected,
                totalMovements: movements,
                totalDifficultyCost: difficulty,
                muscleSetDose: setDose,
                rejections: rejections.sorted {
                    if $0.complexDefinitionId != $1.complexDefinitionId {
                        return $0.complexDefinitionId.uuidString < $1.complexDefinitionId.uuidString
                    }
                    return $0.code < $1.code
                }
            )
        )
    }

    private static func applyingVolumeDose(
        to candidate: AdaptivePlannedComplex,
        desiredSets: Int,
        maxSetsPerExercise: Int
    ) -> AdaptivePlannedComplex {
        var result = candidate
        let primaryIndices = result.components.indices.filter {
            result.components[$0].primaryMuscle == result.primaryMuscle
        }
        guard !primaryIndices.isEmpty else { return result }
        let boundedDesired = min(
            desiredSets,
            primaryIndices.count * maxSetsPerExercise
        )
        let base = boundedDesired / primaryIndices.count
        let remainder = boundedDesired % primaryIndices.count
        for (offset, index) in primaryIndices.enumerated() {
            result.components[index].prescribedSetCount = min(
                maxSetsPerExercise,
                max(1, base + (offset < remainder ? 1 : 0))
            )
        }
        for index in result.components.indices where !primaryIndices.contains(index) {
            result.components[index].prescribedSetCount = min(
                maxSetsPerExercise,
                result.components[index].prescribedSetCount
            )
        }
        return result
    }

    private static func fallbackExposureStatuses(
        readiness: [MuscleGroup: MuscleReadinessInput],
        ledger: TrainingLoadLedger,
        now: Date,
        calendar: Calendar
    ) -> [MuscleGroup: AdaptiveMuscleExposureStatus] {
        let today = calendar.startOfDay(for: now)
        return Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            let rule = AdaptiveExposureControllerService.defaultRule(for: muscle)
            let last = ledger[muscle].lastDirectProductiveExposureAt.map(
                calendar.startOfDay(for:)
            )
            let next = last.flatMap {
                calendar.date(
                    byAdding: .day,
                    value: rule.minimumCalendarDays,
                    to: $0
                )
            }
            let overdue = next.map {
                max(0, calendar.dateComponents([.day], from: $0, to: today).day ?? 0)
            } ?? Int.max
            let input = readiness[muscle]
            return (
                muscle,
                AdaptiveMuscleExposureStatus(
                    muscle: muscle,
                    rule: rule,
                    lastDirectExposureAt: last,
                    nextEligibleAt: next,
                    daysOverdue: overdue,
                    soreness: input?.soreness ?? .high,
                    isEligible: rule.isAutomaticPlanningEnabled
                        && input?.isHardBlocked == false
                        && (next.map { $0 <= today } ?? true)
                )
            )
        })
    }

    private static func applyingConfiguredSplit(
        to candidate: AdaptivePlannedComplex,
        rule: AdaptiveExposureRule,
        exercisesById: [UUID: Exercise]
    ) -> AdaptivePlannedComplex {
        guard rule.exerciseSplitKind != .none,
              rule.firstSplitSetCount + rule.secondSplitSetCount == rule.normalSetCount else {
            return candidate
        }
        var result = candidate
        let firstIndex: Int?
        let secondIndex: Int?
        switch rule.exerciseSplitKind {
        case .none:
            return candidate
        case .chestCompoundIsolation:
            firstIndex = result.components.firstIndex {
                $0.primaryMuscle == .chest && exercisesById[$0.exerciseId]?.type == .compound
            }
            secondIndex = result.components.firstIndex {
                $0.primaryMuscle == .chest && exercisesById[$0.exerciseId]?.type == .isolation
            }
        case .backVerticalHorizontal:
            firstIndex = result.components.firstIndex {
                guard $0.primaryMuscle == .back,
                      let exercise = exercisesById[$0.exerciseId] else { return false }
                return BackMovementPatternService.pattern(for: exercise) == .verticalPull
            }
            secondIndex = result.components.firstIndex {
                guard $0.primaryMuscle == .back,
                      let exercise = exercisesById[$0.exerciseId] else { return false }
                return BackMovementPatternService.pattern(for: exercise) == .horizontalPull
            }
        }
        guard let firstIndex, let secondIndex else { return candidate }
        result.components[firstIndex].prescribedSetCount = rule.firstSplitSetCount
        result.components[secondIndex].prescribedSetCount = rule.secondSplitSetCount
        return result
    }

    private static func configuredSplitIsSatisfied(
        by candidate: AdaptivePlannedComplex,
        rule: AdaptiveExposureRule,
        exercisesById: [UUID: Exercise]
    ) -> Bool {
        switch rule.exerciseSplitKind {
        case .none:
            return candidate.components
                .filter { $0.primaryMuscle == candidate.primaryMuscle }
                .reduce(0) { $0 + $1.prescribedSetCount } == rule.normalSetCount
        case .chestCompoundIsolation:
            let compounds = candidate.components.filter {
                $0.primaryMuscle == .chest
                    && exercisesById[$0.exerciseId]?.type == .compound
            }
            let isolations = candidate.components.filter {
                $0.primaryMuscle == .chest
                    && exercisesById[$0.exerciseId]?.type == .isolation
            }
            return compounds.count == 1
                && isolations.count == 1
                && compounds[0].prescribedSetCount == rule.firstSplitSetCount
                && isolations[0].prescribedSetCount == rule.secondSplitSetCount
        case .backVerticalHorizontal:
            let vertical = candidate.components.filter {
                guard $0.primaryMuscle == .back,
                      let exercise = exercisesById[$0.exerciseId] else { return false }
                return BackMovementPatternService.pattern(for: exercise) == .verticalPull
            }
            let horizontal = candidate.components.filter {
                guard $0.primaryMuscle == .back,
                      let exercise = exercisesById[$0.exerciseId] else { return false }
                return BackMovementPatternService.pattern(for: exercise) == .horizontalPull
            }
            return vertical.count == 1
                && horizontal.count == 1
                && vertical[0].prescribedSetCount == rule.firstSplitSetCount
                && horizontal[0].prescribedSetCount == rule.secondSplitSetCount
        }
    }

    private static func applyingExerciseVariation(
        to candidate: AdaptivePlannedComplex,
        desiredSets: Int,
        exercisesById: [UUID: Exercise],
        exerciseSelections: [
            AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation
        ]
    ) -> AdaptivePlannedComplex {
        var result = candidate

        func stableExerciseOrder(_ left: Exercise, _ right: Exercise) -> Bool {
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.id.uuidString < right.id.uuidString
        }

        func exerciseType(for component: AdaptivePlannedComponent) -> ExerciseType? {
            exercisesById[component.exerciseId]?.type
                ?? exerciseSelections.values.first {
                    $0.exercise.id == component.exerciseId
                }?.exercise.type
        }

        switch result.primaryMuscle {
        case .chest:
            var primaryComponents = result.components.filter {
                $0.primaryMuscle == .chest
            }
            if !primaryComponents.contains(where: {
                exerciseType(for: $0) == .compound
            }) {
                let selectedCompound = exerciseSelections[
                    AdaptiveExerciseSelectionKey(muscle: .chest, type: .compound)
                ]?.exercise
                let fallbackCompound = exercisesById.values
                    .filter {
                        $0.isActive
                            && $0.primaryMuscle == .chest
                            && $0.type == .compound
                    }
                    .sorted(by: stableExerciseOrder)
                    .first
                if let compound = selectedCompound ?? fallbackCompound,
                   let index = result.components.firstIndex(where: {
                       $0.primaryMuscle == .chest
                   }) {
                    result.components[index].exerciseId = compound.id
                    result.components[index].exerciseName = compound.name
                    result.components[index].secondaryMuscle = nil
                    result.components[index].difficulty =
                        AdaptiveExerciseRoleService.difficulty(for: compound)
                    result.reasonCodes.append("chest_compound_lead")
                    primaryComponents = result.components.filter {
                        $0.primaryMuscle == .chest
                    }
                }
            }
            guard desiredSets > 3 else { return result }
            let hasCompound = primaryComponents.contains {
                exerciseType(for: $0) == .compound
            }
            let hasIsolation = primaryComponents.contains {
                exerciseType(for: $0) == .isolation
            }
            guard hasCompound, !hasIsolation else { return result }
            let selected = exerciseSelections[
                AdaptiveExerciseSelectionKey(muscle: .chest, type: .isolation)
            ]?.exercise
            let fallback = exercisesById.values
                .filter {
                    $0.isActive
                        && $0.primaryMuscle == .chest
                        && $0.type == .isolation
                }
                .sorted(by: stableExerciseOrder)
                .first
            guard let isolation = selected ?? fallback,
                  !result.components.contains(where: { $0.exerciseId == isolation.id }) else {
                return result
            }
            result.components.append(
                AdaptivePlannedComponent(
                    exerciseId: isolation.id,
                    exerciseName: isolation.name,
                    position: (result.components.map(\.position).max() ?? -1) + 1,
                    primaryMuscle: .chest,
                    secondaryMuscle: nil,
                    difficulty: AdaptiveExerciseRoleService.difficulty(for: isolation),
                    prescribedSetCount: 1
                )
            )
            result.reasonCodes.append("chest_isolation_volume_split")

        case .back:
            guard desiredSets > 3 else { return result }
            let primaryComponents = result.components.filter {
                $0.primaryMuscle == .back
            }
            let patterned = primaryComponents.compactMap {
                exercisesById[$0.exerciseId].flatMap(BackMovementPatternService.pattern(for:))
            }
            guard Set(patterned).count == 1,
                  let existingPattern = patterned.first,
                  let missingPattern = BackMovementPattern.allCases.first(where: {
                      $0 != existingPattern
                  }) else {
                return result
            }
            let selected = exerciseSelections[
                AdaptiveExerciseSelectionKey(
                    muscle: .back,
                    type: .compound,
                    backPattern: missingPattern
                )
            ]?.exercise
            let fallback = exercisesById.values
                .filter {
                    $0.isActive
                        && $0.primaryMuscle == .back
                        && $0.type == .compound
                        && BackMovementPatternService.pattern(for: $0) == missingPattern
                }
                .sorted(by: stableExerciseOrder)
                .first
            guard let complementary = selected ?? fallback,
                  !result.components.contains(where: {
                      $0.exerciseId == complementary.id
                  }) else {
                return result
            }
            result.components.append(
                AdaptivePlannedComponent(
                    exerciseId: complementary.id,
                    exerciseName: complementary.name,
                    position: (result.components.map(\.position).max() ?? -1) + 1,
                    primaryMuscle: .back,
                    secondaryMuscle: nil,
                    difficulty: AdaptiveExerciseRoleService.difficulty(for: complementary),
                    prescribedSetCount: 1
                )
            )
            result.reasonCodes.append("back_\(missingPattern.rawValue)_volume_split")

        default:
            break
        }
        return result
    }

    static func trace(for result: AdaptivePlannerResult) -> AdaptivePlanDecisionTrace {
        switch result {
        case .proposal(let proposal):
            return AdaptivePlanDecisionTrace(
                plannerVersion: plannerVersion,
                outcomeCode: "proposal",
                selectedComplexDefinitionIds: proposal.complexes.map(\.definitionId),
                selectedReasonCodes: proposal.complexes.flatMap(\.reasonCodes),
                rejectedCodesByComplex: proposal.rejections.map {
                    "\($0.complexDefinitionId.uuidString):\($0.code)"
                },
                conflictCode: nil,
                conflictMuscle: nil
            )
        case .infeasible(let conflict):
            return AdaptivePlanDecisionTrace(
                plannerVersion: plannerVersion,
                outcomeCode: "infeasible",
                selectedComplexDefinitionIds: [],
                selectedReasonCodes: [],
                rejectedCodesByComplex: [],
                conflictCode: conflict.code,
                conflictMuscle: conflict.muscle
            )
        }
    }

    private static func attributedMuscles(of component: AdaptivePlannedComponent) -> Set<MuscleGroup> {
        var result: Set<MuscleGroup> = [component.primaryMuscle]
        if let secondary = component.secondaryMuscle { result.insert(secondary) }
        return result
    }

    private static func eagernessRank(_ eagerness: EagernessLevel?) -> Int {
        switch eagerness {
        case .eager: return 0
        case .neutral: return 1
        case .reluctant: return 2
        case nil: return 3
        }
    }

    private static func sorenessRank(_ soreness: SorenessLevel?) -> Int {
        switch soreness {
        case .some(.none): return 0
        case .some(.mild): return 1
        case .some(.moderate): return 2
        case .some(.high): return 3
        case nil: return 4
        }
    }

    private static func createsHardLowerBodyPair(
        selected: [AdaptivePlannedComplex],
        adding candidate: AdaptivePlannedComplex
    ) -> Bool {
        let components = selected.flatMap(\.components) + candidate.components
        let hasQuads = components.contains {
            $0.difficulty == .hard && ($0.primaryMuscle == .quads || $0.secondaryMuscle == .quads)
        }
        let hasHamstrings = components.contains {
            $0.difficulty == .hard && ($0.primaryMuscle == .hamstrings || $0.secondaryMuscle == .hamstrings)
        }
        return hasQuads && hasHamstrings
    }

    private static func createsBannedSynergistPair(
        selectedMuscles: Set<MuscleGroup>,
        adding muscle: MuscleGroup
    ) -> Bool {
        (muscle == .chest && selectedMuscles.contains(.triceps))
            || (muscle == .triceps && selectedMuscles.contains(.chest))
            || (muscle == .back && selectedMuscles.contains(.biceps))
            || (muscle == .biceps && selectedMuscles.contains(.back))
    }

    private static func prefersCompoundContinuity(_ muscle: MuscleGroup) -> Bool {
        switch muscle {
        case .chest, .back, .quads, .hamstrings: return true
        default: return false
        }
    }

    private static func hasRedundantSameMuscleCompounds(
        _ components: [AdaptivePlannedComponent],
        exercisesById: [UUID: Exercise]
    ) -> Bool {
        let compoundComponents = components.filter {
            exercisesById[$0.exerciseId]?.type == .compound
        }
        let grouped = Dictionary(grouping: compoundComponents, by: \.primaryMuscle)
        for (muscle, muscleComponents) in grouped where muscleComponents.count > 1 {
            guard muscle == .back, muscleComponents.count == 2 else { return true }
            let patterns = muscleComponents.compactMap {
                exercisesById[$0.exerciseId].flatMap(BackMovementPatternService.pattern(for:))
            }
            if Set(patterns) != Set(BackMovementPattern.allCases) {
                return true
            }
        }
        return false
    }

    private static func stableComplexOrder(_ left: AdaptiveExerciseComplex, _ right: AdaptiveExerciseComplex) -> Bool {
        if left.position != right.position { return left.position < right.position }
        if left.definitionId != right.definitionId { return left.definitionId.uuidString < right.definitionId.uuidString }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private static func stableComplexOrder(_ left: AdaptivePlannedComplex, _ right: AdaptivePlannedComplex) -> Bool {
        if left.sourcePosition != right.sourcePosition { return left.sourcePosition < right.sourcePosition }
        if left.definitionId != right.definitionId { return left.definitionId.uuidString < right.definitionId.uuidString }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    private static func floorFitOrder(_ left: AdaptivePlannedComplex, _ right: AdaptivePlannedComplex) -> Bool {
        if left.components.count != right.components.count { return left.components.count < right.components.count }
        let leftCost = left.components.reduce(0) { $0 + $1.difficulty.cost }
        let rightCost = right.components.reduce(0) { $0 + $1.difficulty.cost }
        if leftCost != rightCost { return leftCost < rightCost }
        return stableComplexOrder(left, right)
    }

    private static func isWithinDOMSObservationWindow(
        muscle: MuscleGroup,
        lastDirectExposureAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        // Side-delt work is intentionally allowed on consecutive days when
        // today's observed readiness is clear. Secondary loading never starts
        // this timer (for example chest -> triceps or back -> biceps).
        guard muscle != .sideDelts,
              let lastDirectExposureAt,
              lastDirectExposureAt <= now else { return false }
        let exposureDay = calendar.startOfDay(for: lastDirectExposureAt)
        let currentDay = calendar.startOfDay(for: now)
        let elapsedDays = calendar.dateComponents([.day], from: exposureDay, to: currentDay).day ?? 0
        // Soreness can understate recovery on the first morning and commonly
        // peaks around the second. Do not let a low first-day answer alone
        // clear the muscle; retest readiness from the second calendar day on.
        return elapsedDays < 2
    }
}

/// A non-persistent look ahead through the same canonical planner used for the
/// real workout. The only forecast assumption is recovered readiness; actual
/// next-day answers remain authoritative.
enum AdaptiveForecastService {
    static func expectedProposal(
        program: AdaptiveProgram,
        exercises: [Exercise],
        ledger: TrainingLoadLedger,
        targetComplexCount: Int,
        exposureRules: [MuscleGroup: AdaptiveExposureRule] = Dictionary(
            uniqueKeysWithValues: MuscleGroup.allCases.map {
                ($0, AdaptiveExposureControllerService.defaultRule(for: $0))
            }
        ),
        evidence: [TrainingLoadEvidence] = [],
        capacity: AdaptiveWorkoutCapacity = .legacy,
        exerciseSelections: [AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation] = [:],
        asOf date: Date,
        calendar: Calendar = .current
    ) -> AdaptivePlanProposal? {
        let readiness = Dictionary(uniqueKeysWithValues: program.muscleRules
            .filter(\.isEnabled)
            .map {
                (
                    $0.muscle,
                    MuscleReadinessInput(
                        soreness: .none,
                        connectiveTissuePain: .none,
                        eagerness: .eager
                    )
                )
            })
        let result = AdaptivePlanService.generate(
            program: program,
            exercises: exercises,
            readiness: readiness,
            ledger: ledger,
            exposureStatuses: AdaptiveExposureControllerService.statuses(
                rules: exposureRules,
                readiness: readiness,
                evidence: evidence,
                exercises: exercises,
                asOf: date,
                calendar: calendar
            ),
            targetComplexCount: targetComplexCount,
            capacity: capacity,
            exerciseSelections: exerciseSelections,
            now: date,
            calendar: calendar
        )
        guard case .proposal(let proposal) = result else { return nil }
        return proposal
    }
}

enum AdaptiveDoseEvidenceService {
    static func recommendations(
        program: AdaptiveProgram,
        plans: [GeneratedWorkoutPlan],
        sessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        feedback: [ComplexFeedback],
        adHocFeedback: [AdHocExerciseFeedback],
        overrides: [AdaptiveOverrideEvent],
        readinessCheck: DailyReadinessCheck
    ) -> [UUID: [Int: DoseRecommendation]] {
        let planById = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        let completedSessions = sessions
            .filter { $0.status == .completed && $0.finishedAt != nil }
            .sorted { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }
        let ruleByMuscle = Dictionary(uniqueKeysWithValues: program.muscleRules.map { ($0.muscle, $0) })
        let readinessByMuscle = Dictionary(uniqueKeysWithValues: readinessCheck.responses.map { ($0.muscle, $0) })
        let substitutions = Set(overrides.filter { $0.kind == .substituteExercise }.compactMap(\.occurrenceId))
        var result: [UUID: [Int: DoseRecommendation]] = [:]

        for definition in program.complexes where definition.isEnabled {
            for component in definition.components {
                var datedFeedback: [(Date, ComplexFeedbackRating)] = []
                for item in feedback {
                    guard let sourcePlan = planById[item.generatedPlanId],
                          let snapshot = sourcePlan.complexes.first(where: { $0.id == item.plannedComplexId }),
                          snapshot.sourceDefinitionId == definition.definitionId else { continue }
                    datedFeedback.append((item.createdAt, item.rating))
                }
                datedFeedback += adHocFeedback
                    .filter { $0.exerciseId == component.exerciseId }
                    .map { ($0.createdAt, $0.rating) }
                datedFeedback.sort { $0.0 < $1.0 }

                if let last = datedFeedback.last,
                   last.1 == .painProblem,
                   readinessCheck.createdAt > last.0,
                   readinessByMuscle[component.primaryMuscle]?.connectiveTissuePain
                    == ConnectiveTissuePainLevel.none {
                    datedFeedback.removeLast()
                }

                var occurrences: [PerformanceOccurrence] = []
                for session in completedSessions {
                    guard let plan = planById[session.generatedPlanId],
                          let complex = plan.complexes.first(where: { $0.sourceDefinitionId == definition.definitionId }),
                          let snapshot = complex.exercises.first(where: { $0.position == component.position }) else { continue }
                    let rows = setEntries.filter {
                        $0.adaptiveSessionId == session.id && $0.occurrenceId == snapshot.occurrenceId
                    }
                    occurrences.append(
                        PerformanceOccurrence(
                            exerciseId: rows.first?.exerciseId ?? snapshot.exerciseId,
                            complexDefinitionId: complex.sourceDefinitionId,
                            componentPosition: snapshot.position,
                            isCompleted: true,
                            isSubstitution: substitutions.contains(snapshot.occurrenceId),
                            sets: rows.map {
                                ComparableSetRow(
                                    setIndex: $0.setIndex,
                                    weight: $0.weight,
                                    reps: $0.reps,
                                    isLocked: $0.isLocked
                                )
                            }
                        )
                    )
                }
                let latestPerformance: RepeatPerformanceLabel?
                if occurrences.count >= 2 {
                    latestPerformance = RepeatPerformanceService.compare(
                        previous: occurrences[occurrences.count - 2],
                        current: occurrences[occurrences.count - 1]
                    ).label
                } else {
                    latestPerformance = nil
                }
                let componentReadiness = readinessByMuscle[component.primaryMuscle]
                let recovered = componentReadiness.map {
                    $0.soreness.allowsAutomaticTraining
                        && $0.connectiveTissuePain == .none
                        && $0.eagerness != .reluctant
                } ?? false
                let recommendation = DoseRecommendationService.recommend(
                    currentSetCount: component.prescribedSetCount,
                    maximumSetCount: ruleByMuscle[component.primaryMuscle]?.maxSetsPerExercise
                        ?? component.prescribedSetCount,
                    recentFeedback: datedFeedback.map(\.1),
                    latestPerformance: latestPerformance,
                    recoveredOnTime: recovered,
                    allowsPositiveProgression: componentReadiness.map {
                        $0.soreness.allowsAutomaticTraining
                            && $0.connectiveTissuePain == .none
                            && $0.eagerness != .reluctant
                    } ?? false
                )
                result[definition.definitionId, default: [:]][component.position] = recommendation
            }
        }
        return result
    }
}

struct AdaptiveExerciseSelectionRecommendation {
    var exercise: Exercise
    var reasonCodeSuffix: String
    var canReplaceConfigured: Bool

    init(
        exercise: Exercise,
        reasonCodeSuffix: String,
        canReplaceConfigured: Bool = true
    ) {
        self.exercise = exercise
        self.reasonCodeSuffix = reasonCodeSuffix
        self.canReplaceConfigured = canReplaceConfigured
    }
}

struct AdaptiveExerciseSelectionKey: Hashable {
    var muscle: MuscleGroup
    var type: ExerciseType
    var backPattern: BackMovementPattern?

    init(
        muscle: MuscleGroup,
        type: ExerciseType,
        backPattern: BackMovementPattern? = nil
    ) {
        self.muscle = muscle
        self.type = type
        self.backPattern = backPattern
    }
}

enum AdaptiveExerciseSelectionService {
    private struct Exposure {
        var completedAt: Date
        var sessionId: UUID
        var exerciseId: UUID
    }

    static func recommendations(
        exercises: [Exercise],
        preferences: [AdaptiveExerciseSelectionPreference],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry],
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry]
    ) -> [AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation] {
        let activeExercises = Dictionary(uniqueKeysWithValues: exercises.filter(\.isActive).map { ($0.id, $0) })
        let completedRotation: [UUID: Date] = Dictionary(
            uniqueKeysWithValues: rotationSessions.compactMap { session -> (UUID, Date)? in
                guard session.status == .completed, let finishedAt = session.finishedAt else { return nil }
                return (session.id, finishedAt)
            }
        )
        let completedAdaptive: [UUID: Date] = Dictionary(
            uniqueKeysWithValues: adaptiveSessions.compactMap { session -> (UUID, Date)? in
                guard session.status == .completed, let finishedAt = session.finishedAt else { return nil }
                return (session.id, finishedAt)
            }
        )

        var exposures: [Exposure] = []
        var seen = Set<String>()
        for entry in rotationSetEntries where entry.isLocked && entry.reps > 0 {
            guard let completedAt = completedRotation[entry.sessionId], activeExercises[entry.exerciseId] != nil else {
                continue
            }
            let key = "rotation:\(entry.sessionId.uuidString):\(entry.exerciseId.uuidString)"
            if seen.insert(key).inserted {
                exposures.append(
                    Exposure(completedAt: completedAt, sessionId: entry.sessionId, exerciseId: entry.exerciseId)
                )
            }
        }
        for entry in adaptiveSetEntries where entry.isLocked && entry.reps > 0 {
            guard let completedAt = completedAdaptive[entry.adaptiveSessionId],
                  activeExercises[entry.exerciseId] != nil else { continue }
            let key = "adaptive:\(entry.adaptiveSessionId.uuidString):\(entry.exerciseId.uuidString)"
            if seen.insert(key).inserted {
                exposures.append(
                    Exposure(
                        completedAt: completedAt,
                        sessionId: entry.adaptiveSessionId,
                        exerciseId: entry.exerciseId
                    )
                )
            }
        }
        exposures.sort {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            if $0.sessionId != $1.sessionId { return $0.sessionId.uuidString < $1.sessionId.uuidString }
            return $0.exerciseId.uuidString < $1.exerciseId.uuidString
        }

        let preferencesByMuscle = Dictionary(uniqueKeysWithValues: preferences.map { ($0.muscle, $0) })
        var recentDistinct: [MuscleGroup: [Exercise]] = [:]
        for exposure in exposures {
            guard let exercise = activeExercises[exposure.exerciseId] else { continue }
            if recentDistinct[exercise.primaryMuscle, default: []].contains(where: { $0.id == exercise.id }) {
                continue
            }
            recentDistinct[exercise.primaryMuscle, default: []].append(exercise)
        }

        var result: [AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation] = [:]
        for muscle in MuscleGroup.allCases {
            let preference = preferencesByMuscle[muscle]
            let eligibleIds = Set(preference?.eligibleExerciseIds ?? [])
            let recentAvailable = preference == nil
                ? (recentDistinct[muscle] ?? [])
                : (recentDistinct[muscle] ?? []).filter { eligibleIds.contains($0.id) }
            for type in ExerciseType.allCases {
                let key = AdaptiveExerciseSelectionKey(muscle: muscle, type: type)
                let recent = recentAvailable.filter { $0.type == type }
                let eligibleAlternatives = exercises
                    .filter {
                        $0.isActive
                            && $0.primaryMuscle == muscle
                            && $0.type == type
                            && (preference == nil || eligibleIds.contains($0.id))
                    }
                    .sorted {
                        let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                        if comparison != .orderedSame { return comparison == .orderedAscending }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                let mode = preference?.mode == .pinned && type == .isolation
                    ? AdaptiveExerciseSelectionMode.rotateRecent
                    : (preference?.mode ?? .repeatLast)
                if let recommendation = recommendation(
                    mode: mode,
                    muscle: muscle,
                    type: type,
                    recent: recent,
                    eligibleAlternatives: eligibleAlternatives,
                    pinnedExerciseId: preference?.pinnedExerciseId,
                    activeExercises: activeExercises
                ) {
                    result[key] = recommendation
                }

                if muscle == .back, type == .compound {
                    for pattern in BackMovementPattern.allCases {
                        let patternKey = AdaptiveExerciseSelectionKey(
                            muscle: muscle,
                            type: type,
                            backPattern: pattern
                        )
                        let patternRecent = recent.filter {
                            BackMovementPatternService.pattern(for: $0) == pattern
                        }
                        let patternAlternatives = eligibleAlternatives.filter {
                            BackMovementPatternService.pattern(for: $0) == pattern
                        }
                        if let recommendation = recommendation(
                            mode: mode,
                            muscle: muscle,
                            type: type,
                            recent: patternRecent,
                            eligibleAlternatives: patternAlternatives,
                            pinnedExerciseId: preference?.pinnedExerciseId,
                            activeExercises: activeExercises
                        ) {
                            result[patternKey] = recommendation
                        } else if mode != .pinned,
                                  let fallback = patternAlternatives.first {
                            result[patternKey] = .init(
                                exercise: fallback,
                                reasonCodeSuffix: "exercise_available",
                                canReplaceConfigured: false
                            )
                        }
                    }
                }
            }
        }
        return result
    }

    private static func recommendation(
        mode: AdaptiveExerciseSelectionMode,
        muscle: MuscleGroup,
        type: ExerciseType,
        recent: [Exercise],
        eligibleAlternatives: [Exercise],
        pinnedExerciseId: UUID?,
        activeExercises: [UUID: Exercise]
    ) -> AdaptiveExerciseSelectionRecommendation? {
        switch mode {
        case .repeatLast:
            return recent.first.map {
                .init(exercise: $0, reasonCodeSuffix: "exercise_repeat")
            }
        case .rotateRecent:
            let exercise = recent.dropFirst().first
                ?? recent.first.flatMap { latest in
                    eligibleAlternatives.first { $0.id != latest.id }
                }
                ?? recent.first
            return exercise.map {
                .init(exercise: $0, reasonCodeSuffix: "exercise_rotation")
            }
        case .pinned:
            if let pinnedExerciseId,
               let exercise = activeExercises[pinnedExerciseId],
               exercise.primaryMuscle == muscle,
               exercise.type == type,
               eligibleAlternatives.contains(where: { $0.id == exercise.id }) {
                return .init(exercise: exercise, reasonCodeSuffix: "exercise_pinned")
            }
            return recent.first.map {
                .init(exercise: $0, reasonCodeSuffix: "exercise_repeat")
            }
        }
    }
}

enum ExerciseEffortSourceKind: String, Equatable {
    case fixedCycle
    case adaptive
    case adHoc
}

enum ExerciseEffortMatchKind: String, Equatable {
    case sameCycleDay
    case globalLatest
}

struct ExerciseEffortLookupResult: Equatable {
    let sessionId: UUID
    let completedAt: Date
    let sourceKind: ExerciseEffortSourceKind
    let matchKind: ExerciseEffortMatchKind
    let cycleName: String?
    let dayLabel: String?
    let rows: [ComparableSetRow]
}

/// The one repeat-last lookup used by Fixed Cycle and Adaptive. It copies
/// literal completed rows; readiness, feedback, recovery timing, and missed
/// days never adjust the result.
enum ExerciseEffortLookupService {
    static func fixedCycleEffort(
        exerciseId: UUID,
        cycleInstanceId: UUID,
        cycleDayIndex: Int,
        excludingSessionId: UUID? = nil,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> ExerciseEffortLookupResult? {
        let sameDay = rotationSessions.compactMap { session -> ExerciseEffortLookupResult? in
            guard session.id != excludingSessionId,
                  session.status == .completed,
                  session.cycleInstanceId == cycleInstanceId,
                  session.cycleDayIndex == cycleDayIndex,
                  session.dayLabelSnapshot != "Off-Schedule" else {
                return nil
            }
            return rotationResult(
                session: session,
                exerciseId: exerciseId,
                matchKind: .sameCycleDay,
                entries: rotationSetEntries
            )
        }
        if let result = newest(sameDay) {
            return result
        }
        return globalEffort(
            exerciseId: exerciseId,
            excludingSessionId: excludingSessionId,
            excludingPlanId: nil,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries
        )
    }

    static func globalEffort(
        exerciseId: UUID,
        excludingSessionId: UUID? = nil,
        excludingPlanId: UUID? = nil,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> ExerciseEffortLookupResult? {
        let adaptive = adaptiveSessions.compactMap { session -> ExerciseEffortLookupResult? in
            guard session.status == .completed,
                  session.id != excludingSessionId,
                  session.generatedPlanId != excludingPlanId else {
                return nil
            }
            let rows = adaptiveSetEntries
                .filter {
                    $0.adaptiveSessionId == session.id
                        && $0.exerciseId == exerciseId
                        && $0.isLocked
                        && $0.reps > 0
                }
                .sorted { $0.setIndex < $1.setIndex }
                .map {
                    ComparableSetRow(
                        setIndex: $0.setIndex,
                        weight: $0.weight,
                        reps: $0.reps,
                        isLocked: true
                    )
                }
            guard !rows.isEmpty else { return nil }
            return ExerciseEffortLookupResult(
                sessionId: session.id,
                completedAt: session.finishedAt ?? session.createdAt,
                sourceKind: .adaptive,
                matchKind: .globalLatest,
                cycleName: nil,
                dayLabel: nil,
                rows: rows
            )
        }

        let rotation = rotationSessions.compactMap { session -> ExerciseEffortLookupResult? in
            guard session.id != excludingSessionId else { return nil }
            return rotationResult(
                session: session,
                exerciseId: exerciseId,
                matchKind: .globalLatest,
                entries: rotationSetEntries
            )
        }
        return newest(adaptive + rotation)
    }

    private static func rotationResult(
        session: Session,
        exerciseId: UUID,
        matchKind: ExerciseEffortMatchKind,
        entries: [SetEntry]
    ) -> ExerciseEffortLookupResult? {
        guard session.status == .completed else { return nil }
        let rows = entries
            .filter {
                $0.sessionId == session.id
                    && $0.exerciseId == exerciseId
                    && $0.isLocked
                    && $0.reps > 0
            }
            .sorted { $0.setIndex < $1.setIndex }
            .map {
                ComparableSetRow(
                    setIndex: $0.setIndex,
                    weight: $0.weight,
                    reps: $0.reps,
                    isLocked: true
                )
            }
        guard !rows.isEmpty else { return nil }
        return ExerciseEffortLookupResult(
            sessionId: session.id,
            completedAt: session.finishedAt ?? session.createdAt,
            sourceKind: session.dayLabelSnapshot == "Off-Schedule" ? .adHoc : .fixedCycle,
            matchKind: matchKind,
            cycleName: session.cycleNameSnapshot,
            dayLabel: session.dayLabelSnapshot,
            rows: rows
        )
    }

    private static func newest(
        _ results: [ExerciseEffortLookupResult]
    ) -> ExerciseEffortLookupResult? {
        results.max {
            if $0.completedAt != $1.completedAt {
                return $0.completedAt < $1.completedAt
            }
            return $0.sessionId.uuidString < $1.sessionId.uuidString
        }
    }

}

enum AdaptivePrefillService {
    /// Makes repeat-last history authoritative for the proposed dose while
    /// leaving the configured/profile count as the editable fallback when no
    /// qualifying completed effort exists.
    static func applyRepeatLastSetCounts(
        to plan: GeneratedWorkoutPlan,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) {
        for complex in plan.complexes {
            for exercise in complex.exercises {
                let previous = latestRows(
                    exerciseId: exercise.exerciseId,
                    excludingPlanId: plan.id,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries
                )
                if !previous.isEmpty {
                    exercise.prescribedSetCount = previous.count
                }
            }
        }
    }

    static func rows(
        plan: GeneratedWorkoutPlan,
        exercise: PlannedExerciseSnapshot,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> [ComparableSetRow] {
        return latestRows(
            exerciseId: exercise.exerciseId,
            excludingPlanId: plan.id,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries
        )
    }

    static func latestRows(
        exerciseId: UUID,
        excludingPlanId: UUID? = nil,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> [ComparableSetRow] {
        ExerciseEffortLookupService.globalEffort(
            exerciseId: exerciseId,
            excludingPlanId: excludingPlanId,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries
        )?.rows ?? []
    }

    static func prefill(
        plan: GeneratedWorkoutPlan,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry]
    ) -> [UUID: [Int: AdaptiveSetPrefill]] {
        var result: [UUID: [Int: AdaptiveSetPrefill]] = [:]
        for complex in plan.complexes {
            for exercise in complex.exercises {
                let previous = rows(
                    plan: plan,
                    exercise: exercise,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries
                )
                guard !previous.isEmpty else { continue }
                // Preserve the literal qualifying effort, including its exact
                // set count. `freeze` makes this count authoritative for the
                // new occurrence instead of extending or truncating it to the
                // planner/profile default.
                for (index, row) in previous.enumerated() {
                    result[exercise.occurrenceId, default: [:]][index + 1] = AdaptiveSetPrefill(
                        weight: row.weight,
                        reps: row.reps
                    )
                }
            }
        }
        return result
    }
}

struct ComparableSetRow: Equatable {
    var setIndex: Int
    var weight: Double
    var reps: Int
    var isLocked: Bool
}

struct PerformanceOccurrence: Equatable {
    var exerciseId: UUID
    var complexDefinitionId: UUID?
    var componentPosition: Int?
    var isCompleted: Bool
    var isSubstitution: Bool
    var sets: [ComparableSetRow]
}

enum RepeatPerformanceLabel: String, Equatable {
    case moreRepsAtSameWeight
    case moreWeightWithComparableCompletedReps
    case additionalCompletedSet
    case matched
    case regressed
    case notComparable

    var displayName: String {
        switch self {
        case .moreRepsAtSameWeight: return "More reps at same weight"
        case .moreWeightWithComparableCompletedReps: return "More weight with comparable completed reps"
        case .additionalCompletedSet: return "Additional completed set"
        case .matched: return "Matched"
        case .regressed: return "Regressed"
        case .notComparable: return "Not comparable"
        }
    }

    var isMatchedOrImproved: Bool {
        switch self {
        case .moreRepsAtSameWeight, .moreWeightWithComparableCompletedReps, .additionalCompletedSet, .matched:
            return true
        case .regressed, .notComparable:
            return false
        }
    }
}

struct RepeatPerformanceResult: Equatable {
    var label: RepeatPerformanceLabel
    var previous: [ComparableSetRow]
    var current: [ComparableSetRow]
}

enum RepeatPerformanceService {
    static func compare(
        previous: PerformanceOccurrence?,
        current: PerformanceOccurrence
    ) -> RepeatPerformanceResult {
        let currentRows = lockedRows(current)
        guard let previous,
              previous.isCompleted,
              current.isCompleted,
              !previous.isSubstitution,
              !current.isSubstitution,
              previous.exerciseId == current.exerciseId,
              previous.complexDefinitionId != nil,
              previous.complexDefinitionId == current.complexDefinitionId,
              previous.componentPosition == current.componentPosition else {
            return RepeatPerformanceResult(label: .notComparable, previous: previous.map(lockedRows) ?? [], current: currentRows)
        }
        let previousRows = lockedRows(previous)
        guard !previousRows.isEmpty, !currentRows.isEmpty else {
            return RepeatPerformanceResult(label: .notComparable, previous: previousRows, current: currentRows)
        }
        if currentRows.count > previousRows.count {
            return .init(label: .additionalCompletedSet, previous: previousRows, current: currentRows)
        }
        let pairedCount = min(previousRows.count, currentRows.count)
        let pairs = (0..<pairedCount).map { (previousRows[$0], currentRows[$0]) }
        if pairs.allSatisfy({ $0.0.weight == $0.1.weight })
            && pairs.reduce(0, { $0 + $1.1.reps }) > pairs.reduce(0, { $0 + $1.0.reps }) {
            return .init(label: .moreRepsAtSameWeight, previous: previousRows, current: currentRows)
        }
        if pairs.contains(where: { $0.1.weight > $0.0.weight })
            && pairs.allSatisfy({ $0.1.reps >= $0.0.reps - 1 }) {
            return .init(label: .moreWeightWithComparableCompletedReps, previous: previousRows, current: currentRows)
        }
        if previousRows == currentRows {
            return .init(label: .matched, previous: previousRows, current: currentRows)
        }
        return .init(label: .regressed, previous: previousRows, current: currentRows)
    }

    private static func lockedRows(_ occurrence: PerformanceOccurrence) -> [ComparableSetRow] {
        occurrence.sets
            .filter { $0.isLocked && $0.reps > 0 }
            .sorted { $0.setIndex < $1.setIndex }
    }
}

struct DoseRecommendation: Equatable {
    var prescribedSetCount: Int
    var isPainBlocked: Bool
    var reasonCode: String
}

enum DoseRecommendationService {
    static func recommend(
        currentSetCount: Int,
        minimumSetCount: Int = 1,
        maximumSetCount: Int,
        recentFeedback: [ComplexFeedbackRating],
        latestPerformance: RepeatPerformanceLabel?,
        recoveredOnTime: Bool,
        allowsPositiveProgression: Bool? = nil
    ) -> DoseRecommendation {
        guard recentFeedback.last != .painProblem else {
            return DoseRecommendation(
                prescribedSetCount: currentSetCount,
                isPainBlocked: true,
                reasonCode: "pain_block"
            )
        }
        // Historical feedback remains available for review and pain may still
        // block Adaptive scheduling, but no feedback/readiness/performance path
        // is allowed to change the repeat-last dose.
        return DoseRecommendation(
            prescribedSetCount: currentSetCount,
            isPainBlocked: false,
            reasonCode: "repeat_last_only"
        )
    }
}
