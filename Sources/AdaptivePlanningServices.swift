import Foundation

struct MuscleReadinessInput: Equatable {
    var soreness: SorenessLevel
    var connectiveTissuePain: ConnectiveTissuePainLevel
    var eagerness: EagernessLevel

    var isHardBlocked: Bool {
        soreness == .high || connectiveTissuePain == .stop
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
    static let plannerVersion = 2

    static func generate(
        program: AdaptiveProgram,
        exercises: [Exercise],
        readiness: [MuscleGroup: MuscleReadinessInput],
        ledger: TrainingLoadLedger,
        doseRecommendations: [UUID: [Int: DoseRecommendation]] = [:],
        now: Date,
        calendar: Calendar = .current
    ) -> AdaptivePlannerResult {
        let enabledRules = program.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }
        let rules = Dictionary(uniqueKeysWithValues: enabledRules.map { ($0.muscle, $0) })
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        for rule in enabledRules where readiness[rule.muscle] == nil {
            return .infeasible(
                AdaptivePlanConflict(muscle: rule.muscle, requiredAdditionalSets: 0, code: "missing_readiness")
            )
        }

        var rejections: [AdaptivePlannerRejection] = []
        let candidates = program.complexes
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
                for component in components {
                    guard let exercise = exercisesById[component.exerciseId], exercise.isActive else {
                        rejections.append(.init(complexDefinitionId: complex.definitionId, code: "inactive_exercise"))
                        return nil
                    }
                    if doseRecommendations[complex.definitionId]?[component.position]?.isPainBlocked == true {
                        rejections.append(.init(complexDefinitionId: complex.definitionId, code: "pain_block"))
                        return nil
                    }
                    attributedMuscles.insert(component.primaryMuscle)
                    if let secondary = component.secondaryMuscle { attributedMuscles.insert(secondary) }
                    planned.append(
                        AdaptivePlannedComponent(
                            exerciseId: exercise.id,
                            exerciseName: exercise.name,
                            position: component.position,
                            primaryMuscle: component.primaryMuscle,
                            secondaryMuscle: component.secondaryMuscle,
                            difficulty: component.difficulty,
                            prescribedSetCount: doseRecommendations[complex.definitionId]?[component.position]?
                                .prescribedSetCount ?? component.prescribedSetCount
                        )
                    )
                }
                if attributedMuscles.contains(where: { readiness[$0]?.isHardBlocked == true }) {
                    rejections.append(.init(complexDefinitionId: complex.definitionId, code: "held_for_recovery"))
                    return nil
                }
                if attributedMuscles.contains(where: {
                    isWithinDOMSObservationWindow(
                        muscle: $0,
                        lastDirectExposureAt: ledger[$0].lastDirectProductiveExposureAt,
                        now: now,
                        calendar: calendar
                    )
                }) {
                    rejections.append(
                        .init(complexDefinitionId: complex.definitionId, code: "doms_observation_window")
                    )
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
                    reasonCodes: [],
                    components: planned
                )
            }

        var selected: [AdaptivePlannedComplex] = []
        var selectedDefinitions = Set<UUID>()
        var movements = 0
        var difficulty = 0
        var exerciseCounts: [MuscleGroup: Int] = [:]
        var setDose: [MuscleGroup: Int] = [:]

        func fitFailure(for candidate: AdaptivePlannedComplex) -> String? {
            if movements + candidate.components.count > program.globalMaxMovements { return "daily_movement_cap" }
            let combinedComponents = selected.flatMap(\.components) + candidate.components
            let hasHardQuads = combinedComponents.contains {
                $0.difficulty == .hard && ($0.primaryMuscle == .quads || $0.secondaryMuscle == .quads)
            }
            let hasHardHamstrings = combinedComponents.contains {
                $0.difficulty == .hard && ($0.primaryMuscle == .hamstrings || $0.secondaryMuscle == .hamstrings)
            }
            if hasHardQuads && hasHardHamstrings { return "hard_quad_hamstring_pair" }

            var addedExerciseCounts: [MuscleGroup: Int] = [:]
            for component in candidate.components {
                guard let primaryRule = rules[component.primaryMuscle],
                      component.prescribedSetCount <= primaryRule.maxSetsPerExercise else {
                    return "sets_per_exercise_cap"
                }
                for muscle in attributedMuscles(of: component) {
                    addedExerciseCounts[muscle, default: 0] += 1
                }
            }
            for (muscle, added) in addedExerciseCounts {
                guard let rule = rules[muscle] else { continue }
                if exerciseCounts[muscle, default: 0] + added > rule.maxExercisesPerExposure {
                    return "muscle_exercise_cap"
                }
            }
            return nil
        }

        func select(_ candidate: AdaptivePlannedComplex, reason: String) {
            var selectedCandidate = candidate
            selectedCandidate.reasonCodes.append(reason)
            selected.append(selectedCandidate)
            selectedDefinitions.insert(candidate.definitionId)
            movements += candidate.components.count
            difficulty += candidate.components.reduce(0) { $0 + $1.difficulty.cost }
            for component in candidate.components {
                for muscle in attributedMuscles(of: component) {
                    exerciseCounts[muscle, default: 0] += 1
                    setDose[muscle, default: 0] += component.prescribedSetCount
                }
            }
        }

        for rule in enabledRules {
            let load = ledger[rule.muscle]
            let floorDeficit = max(0, rule.rollingSetFloor - load.lockedSetCount)
            let gapDue: Bool
            if let last = load.lastProductiveExposureAt,
               let dueDate = calendar.date(byAdding: .day, value: rule.maxRecoveredDayGap, to: last) {
                gapDue = dueDate <= now
            } else {
                gapDue = true
            }
            guard floorDeficit > 0 || gapDue else { continue }

            let target = max(floorDeficit, gapDue ? 1 : 0)
            while setDose[rule.muscle, default: 0] < target {
                let eligibleQualifying = candidates
                    .filter {
                        $0.primaryMuscle == rule.muscle
                    }
                    .filter { candidate in
                        program.complexes.first(where: { $0.definitionId == candidate.definitionId })?
                            .qualifiesForPrimaryFloor == true
                    }
                let options = eligibleQualifying
                    .filter { !selectedDefinitions.contains($0.definitionId) }
                    .sorted(by: floorFitOrder)
                guard let fitting = options.first(where: { fitFailure(for: $0) == nil }) else {
                    let failures = options.compactMap(fitFailure(for:))
                    // A rolling floor is a multi-day target, not a requirement
                    // to erase the entire deficit in one workout. Once every
                    // distinct qualifying complex that fits today has been
                    // used, retain the remaining deficit for future recovered
                    // exposures. This is especially important at cold start,
                    // when every enabled muscle may have a zero-set baseline.
                    //
                    // A due muscle with no usable dose at all because every
                    // candidate exceeds its per-exercise set cap remains a
                    // genuine configuration conflict.
                    if setDose[rule.muscle, default: 0] == 0,
                       !options.isEmpty,
                       failures.allSatisfy({ $0 == "sets_per_exercise_cap" }) {
                        return .infeasible(
                            AdaptivePlanConflict(
                                muscle: rule.muscle,
                                requiredAdditionalSets: target - setDose[rule.muscle, default: 0],
                                code: "sets_per_exercise_cap"
                            )
                        )
                    }
                    break
                }
                select(fitting, reason: floorDeficit > 0 ? "\(rule.muscle.rawValue)_floor_due" : "\(rule.muscle.rawValue)_gap_due")
            }
        }

        let remaining = candidates
            .filter { !selectedDefinitions.contains($0.definitionId) }
            .sorted { left, right in
                let leftRank = rules[left.primaryMuscle]?.priorityRank ?? Int.max
                let rightRank = rules[right.primaryMuscle]?.priorityRank ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                let leftLast = ledger[left.primaryMuscle].lastProductiveExposureAt ?? .distantPast
                let rightLast = ledger[right.primaryMuscle].lastProductiveExposureAt ?? .distantPast
                if leftLast != rightLast { return leftLast < rightLast }
                return stableComplexOrder(left, right)
            }
        for candidate in remaining {
            if let failure = fitFailure(for: candidate) {
                rejections.append(.init(complexDefinitionId: candidate.definitionId, code: failure))
            } else {
                select(candidate, reason: "\(candidate.primaryMuscle.rawValue)_priority")
            }
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
                let recovered = readinessByMuscle[component.primaryMuscle].map {
                    $0.soreness != .high
                        && $0.connectiveTissuePain == .none
                        && $0.eagerness != .reluctant
                } ?? false
                let recommendation = DoseRecommendationService.recommend(
                    currentSetCount: component.prescribedSetCount,
                    maximumSetCount: ruleByMuscle[component.primaryMuscle]?.maxSetsPerExercise
                        ?? component.prescribedSetCount,
                    recentFeedback: datedFeedback.map(\.1),
                    latestPerformance: latestPerformance,
                    recoveredOnTime: recovered
                )
                result[definition.definitionId, default: [:]][component.position] = recommendation
            }
        }
        return result
    }
}

enum AdaptivePrefillService {
    static func rows(
        plan: GeneratedWorkoutPlan,
        complex: PlannedComplexSnapshot,
        exercise: PlannedExerciseSnapshot,
        adaptivePlans: [GeneratedWorkoutPlan],
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry],
        overrides: [AdaptiveOverrideEvent]
    ) -> [ComparableSetRow] {
        let substituted = Set(overrides.filter { $0.kind == .substituteExercise }.compactMap(\.occurrenceId))
        let completedAdaptive = adaptiveSessions
            .filter { $0.status == .completed && $0.finishedAt != nil && $0.generatedPlanId != plan.id }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }

        for session in completedAdaptive {
            guard let priorPlan = adaptivePlans.first(where: { $0.id == session.generatedPlanId }),
                  let priorComplex = priorPlan.complexes.first(where: {
                      $0.sourceDefinitionId == complex.sourceDefinitionId
                  }),
                  let priorExercise = priorComplex.exercises.first(where: {
                      $0.position == exercise.position && $0.exerciseId == exercise.exerciseId
                  }),
                  !substituted.contains(priorExercise.occurrenceId) else { continue }
            let result = adaptiveRows(
                sessionId: session.id,
                occurrenceId: priorExercise.occurrenceId,
                expectedExerciseId: exercise.exerciseId,
                entries: adaptiveSetEntries
            )
            if !result.isEmpty { return result }
        }

        var fallback: [(Date, [ComparableSetRow])] = []
        for session in completedAdaptive {
            let rows = adaptiveSetEntries
                .filter {
                    $0.adaptiveSessionId == session.id
                        && $0.exerciseId == exercise.exerciseId
                        && $0.isLocked
                        && $0.reps > 0
                        && !substituted.contains($0.occurrenceId)
                }
                .sorted { $0.setIndex < $1.setIndex }
                .map { ComparableSetRow(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps, isLocked: true) }
            if !rows.isEmpty { fallback.append((session.finishedAt ?? session.createdAt, rows)) }
        }
        for session in rotationSessions where session.status == .completed && session.finishedAt != nil {
            let rows = rotationSetEntries
                .filter {
                    $0.sessionId == session.id
                        && $0.exerciseId == exercise.exerciseId
                        && $0.isLocked
                        && $0.reps > 0
                }
                .sorted { $0.setIndex < $1.setIndex }
                .map { ComparableSetRow(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps, isLocked: true) }
            if !rows.isEmpty { fallback.append((session.finishedAt ?? session.createdAt, rows)) }
        }
        return fallback.max(by: { $0.0 < $1.0 })?.1 ?? []
    }

    static func prefill(
        plan: GeneratedWorkoutPlan,
        adaptivePlans: [GeneratedWorkoutPlan],
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry],
        overrides: [AdaptiveOverrideEvent]
    ) -> [UUID: [Int: AdaptiveSetPrefill]] {
        var result: [UUID: [Int: AdaptiveSetPrefill]] = [:]
        for complex in plan.complexes {
            for exercise in complex.exercises {
                let previous = rows(
                    plan: plan,
                    complex: complex,
                    exercise: exercise,
                    adaptivePlans: adaptivePlans,
                    adaptiveSessions: adaptiveSessions,
                    adaptiveSetEntries: adaptiveSetEntries,
                    rotationSessions: rotationSessions,
                    rotationSetEntries: rotationSetEntries,
                    overrides: overrides
                )
                guard !previous.isEmpty else { continue }
                for index in 1...exercise.prescribedSetCount {
                    let row = previous.first(where: { $0.setIndex == index }) ?? previous.last!
                    result[exercise.occurrenceId, default: [:]][index] = AdaptiveSetPrefill(
                        weight: row.weight,
                        reps: row.reps
                    )
                }
            }
        }
        return result
    }

    private static func adaptiveRows(
        sessionId: UUID,
        occurrenceId: UUID,
        expectedExerciseId: UUID,
        entries: [AdaptiveSetEntry]
    ) -> [ComparableSetRow] {
        entries
            .filter {
                $0.adaptiveSessionId == sessionId
                    && $0.occurrenceId == occurrenceId
                    && $0.exerciseId == expectedExerciseId
                    && $0.isLocked
                    && $0.reps > 0
            }
            .sorted { $0.setIndex < $1.setIndex }
            .map { ComparableSetRow(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps, isLocked: true) }
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
        recoveredOnTime: Bool
    ) -> DoseRecommendation {
        guard recentFeedback.last != .painProblem else {
            return DoseRecommendation(
                prescribedSetCount: currentSetCount,
                isPainBlocked: true,
                reasonCode: "pain_block"
            )
        }
        let tooMuchCount = recentFeedback.suffix(2).filter { $0 == .tooMuch }.count
        if recentFeedback.last == .tooMuch || (tooMuchCount > 0 && !recoveredOnTime) {
            return DoseRecommendation(
                prescribedSetCount: max(minimumSetCount, currentSetCount - 1),
                isPainBlocked: false,
                reasonCode: "feedback_decrease_one_set"
            )
        }
        let repeatedTooLittle = recentFeedback.suffix(3).filter { $0 == .tooLittle }.count >= 2
        if repeatedTooLittle,
           recoveredOnTime,
           latestPerformance?.isMatchedOrImproved == true {
            return DoseRecommendation(
                prescribedSetCount: min(maximumSetCount, currentSetCount + 1),
                isPainBlocked: false,
                reasonCode: "repeated_too_little_increase_one_set"
            )
        }
        if latestPerformance == .regressed && !recoveredOnTime {
            return DoseRecommendation(
                prescribedSetCount: max(minimumSetCount, currentSetCount - 1),
                isPainBlocked: false,
                reasonCode: "regression_with_under_recovery"
            )
        }
        return DoseRecommendation(
            prescribedSetCount: currentSetCount,
            isPainBlocked: false,
            reasonCode: "hold_dose"
        )
    }
}
