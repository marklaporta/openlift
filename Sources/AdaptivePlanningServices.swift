import Foundation
import SwiftData

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
        maxWorkingSetCount: 20,
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
    static let plannerVersion = 7

    static func generate(
        program: AdaptiveProgram,
        exercises: [Exercise],
        readiness: [MuscleGroup: MuscleReadinessInput],
        ledger: TrainingLoadLedger,
        targetComplexCount: Int? = nil,
        volumeStatuses: [MuscleGroup: AdaptiveMuscleVolumeStatus]? = nil,
        capacity: AdaptiveWorkoutCapacity = .legacy,
        doseRecommendations: [UUID: [Int: DoseRecommendation]] = [:],
        exerciseSelections: [AdaptiveExerciseSelectionKey: AdaptiveExerciseSelectionRecommendation] = [:],
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
                            prescribedSetCount: doseRecommendations[complex.definitionId]?[component.position]?
                                .prescribedSetCount ?? component.prescribedSetCount
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
                    reasonCodes: selectionReasonCodes,
                    components: planned
                )
            }
        let candidates = rawCandidates.map { candidate in
            guard let status = volumeStatuses?[candidate.primaryMuscle],
                  status.weeklySetTarget > 0 else { return candidate }
            return applyingVolumeDose(
                to: candidate,
                desiredSets: min(
                    status.dailySetCap,
                    max(
                        candidate.components.filter {
                            $0.primaryMuscle == candidate.primaryMuscle
                        }.count,
                        Int(ceil(status.setsBehind))
                    )
                ),
                maxSetsPerExercise: capacity.maxSetsPerExercise
            )
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
            let directSetsByMuscle = Dictionary(grouping: combinedComponents, by: \.primaryMuscle)
                .mapValues { $0.reduce(0) { $0 + $1.prescribedSetCount } }
            for (muscle, sets) in directSetsByMuscle {
                let dailyCap = volumeStatuses?[muscle]?.dailySetCap ?? Int.max
                if sets > dailyCap { return "daily_muscle_set_cap" }
            }
            for component in candidate.components {
                guard let primaryRule = rules[component.primaryMuscle] else {
                    return "primary_muscle_disabled"
                }
                let exerciseCap = volumeStatuses == nil
                    ? primaryRule.maxSetsPerExercise
                    : capacity.maxSetsPerExercise
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
                if volumeStatuses == nil {
                    for muscle in attributedMuscles(of: component) {
                        setDose[muscle, default: 0] += component.prescribedSetCount
                    }
                } else {
                    setDose[component.primaryMuscle, default: 0] += component.prescribedSetCount
                }
            }
        }

        var dueReasonByMuscle: [MuscleGroup: String] = [:]
        for rule in enabledRules {
            if let status = volumeStatuses?[rule.muscle] {
                if status.weeklySetTarget > 0 && status.setsBehind > 0.001 {
                    dueReasonByMuscle[rule.muscle] = "\(rule.muscle.rawValue)_volume_due"
                }
            } else {
                let load = ledger[rule.muscle]
                let exposureDue = rule.rollingSetFloor > 0 && load.lockedSetCount == 0
                let gapDue: Bool
                if let last = load.lastProductiveExposureAt,
                   let dueDate = calendar.date(
                    byAdding: .day,
                    value: rule.maxRecoveredDayGap,
                    to: last
                   ) {
                    gapDue = dueDate <= now
                } else {
                    gapDue = true
                }
                if exposureDue {
                    dueReasonByMuscle[rule.muscle] = "\(rule.muscle.rawValue)_exposure_due"
                } else if gapDue {
                    dueReasonByMuscle[rule.muscle] = "\(rule.muscle.rawValue)_gap_due"
                }
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
                    && (volumeStatuses == nil || dueReasonByMuscle[$0.primaryMuscle] != nil)
                    && fitFailure(for: $0) == nil
            }
            guard let candidate = remaining.sorted(by: { left, right in
                let leftPair = createsHardLowerBodyPair(selected: selected, adding: left)
                let rightPair = createsHardLowerBodyPair(selected: selected, adding: right)
                if leftPair != rightPair { return !leftPair }
                let leftDue = dueReasonByMuscle[left.primaryMuscle] != nil
                let rightDue = dueReasonByMuscle[right.primaryMuscle] != nil
                if leftDue != rightDue { return leftDue }
                let leftDebt = volumeStatuses?[left.primaryMuscle]?.normalizedDebt ?? 0
                let rightDebt = volumeStatuses?[right.primaryMuscle]?.normalizedDebt ?? 0
                if leftDebt != rightDebt { return leftDebt > rightDebt }
                let leftEagerness = eagernessRank(readiness[left.primaryMuscle]?.eagerness)
                let rightEagerness = eagernessRank(readiness[right.primaryMuscle]?.eagerness)
                if leftEagerness != rightEagerness { return leftEagerness < rightEagerness }
                let leftRank = rules[left.primaryMuscle]?.priorityRank ?? Int.max
                let rightRank = rules[right.primaryMuscle]?.priorityRank ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                let leftLast = ledger[left.primaryMuscle].lastProductiveExposureAt ?? .distantPast
                let rightLast = ledger[right.primaryMuscle].lastProductiveExposureAt ?? .distantPast
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
        volumeStatuses: [MuscleGroup: AdaptiveMuscleVolumeStatus]? = nil,
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
            targetComplexCount: targetComplexCount,
            volumeStatuses: volumeStatuses,
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

        return latestRows(
            exerciseId: exercise.exerciseId,
            excludingPlanId: plan.id,
            adaptiveSessions: adaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            rotationSessions: rotationSessions,
            rotationSetEntries: rotationSetEntries,
            overrides: overrides
        )
    }

    static func latestRows(
        exerciseId: UUID,
        excludingPlanId: UUID? = nil,
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        rotationSessions: [Session],
        rotationSetEntries: [SetEntry],
        overrides: [AdaptiveOverrideEvent]
    ) -> [ComparableSetRow] {
        let substituted = Set(overrides.filter { $0.kind == .substituteExercise }.compactMap(\.occurrenceId))
        let completedAdaptive = adaptiveSessions
            .filter {
                $0.status == .completed
                    && $0.finishedAt != nil
                    && $0.generatedPlanId != excludingPlanId
            }
        var fallback: [(Date, [ComparableSetRow])] = []
        for session in completedAdaptive {
            let rows = adaptiveSetEntries
                .filter {
                    $0.adaptiveSessionId == session.id
                        && $0.exerciseId == exerciseId
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
                        && $0.exerciseId == exerciseId
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
