import Foundation
import SwiftData

enum AdaptiveWorkoutServiceError: LocalizedError, Equatable {
    case incompleteReadiness(MuscleGroup)
    case profileNotReviewed
    case plannerConflict(AdaptivePlanConflict)
    case planNotProposed
    case planAlreadyStarted
    case adaptiveSessionNotFound
    case plannedExerciseNotFound
    case emptyProposedPlan
    case hardQuadHamstringPair
    case noLockedSets

    var errorDescription: String? {
        switch self {
        case .incompleteReadiness(let muscle):
            return "Complete all readiness answers for \(muscle.displayName)."
        case .profileNotReviewed:
            return "Review and approve the active Adaptive profile in Cycle before using it for a real workout."
        case .plannerConflict(let conflict):
            return "Cannot build a safe plan for \(conflict.muscle.displayName): \(conflict.code)."
        case .planNotProposed:
            return "Only a proposed plan can be frozen."
        case .planAlreadyStarted:
            return "The plan cannot be regenerated after its first set is locked."
        case .adaptiveSessionNotFound:
            return "The Adaptive workout session could not be found."
        case .plannedExerciseNotFound:
            return "The planned exercise could not be found."
        case .emptyProposedPlan:
            return "Add at least one movement before using this workout."
        case .hardQuadHamstringPair:
            return "A hard quad movement and a hard hamstring movement cannot be scheduled in the same workout."
        case .noLockedSets:
            return "Lock at least one completed set before finishing the workout."
        }
    }
}

struct AdaptiveSetPrefill: Equatable {
    var weight: Double
    var reps: Int
}

enum AdaptiveWorkoutService {
    static func substituteProposedExercise(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        to exercise: Exercise,
        difficulty: MovementDifficulty? = nil,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status == .proposed else { throw AdaptiveWorkoutServiceError.planAlreadyStarted }
        guard let snapshot = plan.complexes
            .flatMap(\.exercises)
            .first(where: { $0.occurrenceId == occurrenceId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        let replacementDifficulty = difficulty ?? snapshot.difficulty
        guard !wouldCreateHardLowerBodyPair(
            plan: plan,
            replacingOccurrenceId: occurrenceId,
            withMuscle: exercise.primaryMuscle,
            difficulty: replacementDifficulty
        ) else {
            throw AdaptiveWorkoutServiceError.hardQuadHamstringPair
        }

        let originalExerciseId = snapshot.exerciseId
        snapshot.exerciseId = exercise.id
        snapshot.exerciseName = exercise.name
        snapshot.primaryMuscle = exercise.primaryMuscle
        snapshot.secondaryMuscle = nil
        snapshot.difficulty = replacementDifficulty
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                occurrenceId: occurrenceId,
                kind: .substituteExercise,
                originalExerciseId: originalExerciseId,
                replacementExerciseId: exercise.id,
                reasonCode: "user_substitution_before_freeze",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func addProposedMovement(
        plan: GeneratedWorkoutPlan,
        exercise: Exercise,
        difficulty: MovementDifficulty,
        prescribedSetCount: Int,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status == .proposed else { throw AdaptiveWorkoutServiceError.planAlreadyStarted }
        guard !wouldCreateHardLowerBodyPair(
            plan: plan,
            withMuscle: exercise.primaryMuscle,
            difficulty: difficulty
        ) else {
            throw AdaptiveWorkoutServiceError.hardQuadHamstringPair
        }

        let snapshot = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: exercise.primaryMuscle,
            difficulty: difficulty,
            prescribedSetCount: max(1, prescribedSetCount)
        )
        let complex = PlannedComplexSnapshot(
            sourceDefinitionId: UUID(),
            sourceVersion: 0,
            position: (plan.complexes.map(\.position).max() ?? -1) + 1,
            name: exercise.name,
            primaryMuscle: exercise.primaryMuscle,
            reasonCodes: ["user_added"],
            exercises: [snapshot]
        )
        plan.complexes.append(complex)
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                occurrenceId: snapshot.occurrenceId,
                kind: .addExercise,
                muscle: exercise.primaryMuscle,
                replacementExerciseId: exercise.id,
                reasonCode: "user_added_before_freeze",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func removeProposedMovement(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status == .proposed else { throw AdaptiveWorkoutServiceError.planAlreadyStarted }
        guard let complex = plan.complexes.first(where: {
            $0.exercises.contains { $0.occurrenceId == occurrenceId }
        }), let snapshot = complex.exercises.first(where: { $0.occurrenceId == occurrenceId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }

        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                occurrenceId: occurrenceId,
                kind: .removeExercise,
                muscle: snapshot.primaryMuscle,
                originalExerciseId: snapshot.exerciseId,
                reasonCode: "user_removed_before_freeze",
                createdAt: now
            )
        )
        if complex.exercises.count == 1 {
            plan.complexes.removeAll { $0.id == complex.id }
            modelContext.delete(complex)
        } else {
            complex.exercises.removeAll { $0.occurrenceId == occurrenceId }
            modelContext.delete(snapshot)
            for (position, exercise) in complex.exercises.sorted(by: { $0.position < $1.position }).enumerated() {
                exercise.position = position
            }
        }
        for (position, item) in plan.complexes.sorted(by: { $0.position < $1.position }).enumerated() {
            item.position = position
        }
        try modelContext.save()
    }

    static func wouldCreateHardLowerBodyPair(
        plan: GeneratedWorkoutPlan,
        replacingOccurrenceId: UUID? = nil,
        withMuscle muscle: MuscleGroup,
        difficulty: MovementDifficulty
    ) -> Bool {
        let snapshots = plan.complexes.flatMap(\.exercises).filter {
            $0.occurrenceId != replacingOccurrenceId
        }
        let hasHardQuads = (muscle == .quads && difficulty == .hard) || snapshots.contains {
            $0.difficulty == .hard && ($0.primaryMuscle == .quads || $0.secondaryMuscle == .quads)
        }
        let hasHardHamstrings = (muscle == .hamstrings && difficulty == .hard) || snapshots.contains {
            $0.difficulty == .hard && ($0.primaryMuscle == .hamstrings || $0.secondaryMuscle == .hamstrings)
        }
        return hasHardQuads && hasHardHamstrings
    }

    static func recordFeedback(
        plan: GeneratedWorkoutPlan,
        complex: PlannedComplexSnapshot,
        rating: ComplexFeedbackRating,
        existingFeedback: [ComplexFeedback],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        for feedback in existingFeedback where
            feedback.generatedPlanId == plan.id && feedback.plannedComplexId == complex.id {
            modelContext.delete(feedback)
        }
        modelContext.insert(
            ComplexFeedback(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                rating: rating,
                createdAt: now
            )
        )
        if rating == .painProblem {
            modelContext.insert(
                AdaptiveOverrideEvent(
                    generatedPlanId: plan.id,
                    plannedComplexId: complex.id,
                    kind: .painBlock,
                    muscle: complex.primaryMuscle,
                    reasonCode: "user_reported_pain_problem",
                    createdAt: now
                )
            )
        }
        try modelContext.save()
    }

    static func localDateKey(
        for date: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func currentPlan(
        plans: [GeneratedWorkoutPlan],
        localDateKey: String,
        programId: UUID
    ) -> GeneratedWorkoutPlan? {
        plans
            .filter { $0.localDateKey == localDateKey && $0.adaptiveProgramId == programId }
            .sorted {
                let leftRank = statusRank($0.status)
                let rightRank = statusRank($1.status)
                if leftRank != rightRank { return leftRank < rightRank }
                return $0.createdAt > $1.createdAt
            }
            .first
    }

    static func makeReadinessCheck(
        program: AdaptiveProgram,
        inputs: [MuscleGroup: MuscleReadinessInput],
        localDateKey: String,
        timeZoneIdentifier: String,
        revision: Int,
        now: Date = .now
    ) throws -> DailyReadinessCheck {
        let enabledMuscles = program.muscleRules
            .filter(\.isEnabled)
            .sorted { $0.priorityRank < $1.priorityRank }
            .map(\.muscle)
        for muscle in enabledMuscles where inputs[muscle] == nil {
            throw AdaptiveWorkoutServiceError.incompleteReadiness(muscle)
        }
        let responses = enabledMuscles.map { muscle in
            let input = inputs[muscle]!
            return AdaptiveReadinessResponse(
                muscle: muscle,
                soreness: input.soreness,
                connectiveTissuePain: input.connectiveTissuePain,
                eagerness: input.eagerness
            )
        }
        return DailyReadinessCheck(
            localDateKey: localDateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            revision: revision,
            createdAt: now,
            adaptiveProgramId: program.id,
            adaptiveProgramVersion: program.version,
            responses: responses
        )
    }

    static func readinessInputs(from check: DailyReadinessCheck) -> [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: check.responses.map {
            (
                $0.muscle,
                MuscleReadinessInput(
                    soreness: $0.soreness,
                    connectiveTissuePain: $0.connectiveTissuePain,
                    eagerness: $0.eagerness
                )
            )
        })
    }

    static func makeProposedPlan(
        result: AdaptivePlannerResult,
        program: AdaptiveProgram,
        readinessCheck: DailyReadinessCheck,
        localDateKey: String,
        timeZoneIdentifier: String,
        now: Date = .now
    ) throws -> GeneratedWorkoutPlan {
        guard case .proposal(let proposal) = result else {
            guard case .infeasible(let conflict) = result else { fatalError("Unknown planner result") }
            throw AdaptiveWorkoutServiceError.plannerConflict(conflict)
        }
        let complexSnapshots = proposal.complexes.enumerated().map { index, complex in
            PlannedComplexSnapshot(
                sourceDefinitionId: complex.definitionId,
                sourceVersion: complex.version,
                position: index,
                name: complex.name,
                primaryMuscle: complex.primaryMuscle,
                reasonCodes: complex.reasonCodes,
                exercises: complex.components.enumerated().map { componentIndex, component in
                    PlannedExerciseSnapshot(
                        position: componentIndex,
                        exerciseId: component.exerciseId,
                        exerciseName: component.exerciseName,
                        primaryMuscle: component.primaryMuscle,
                        secondaryMuscle: component.secondaryMuscle,
                        difficulty: component.difficulty,
                        prescribedSetCount: component.prescribedSetCount
                    )
                }
            )
        }
        return GeneratedWorkoutPlan(
            localDateKey: localDateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            createdAt: now,
            status: .proposed,
            adaptiveProgramId: program.id,
            adaptiveProgramVersion: program.version,
            readinessCheckId: readinessCheck.id,
            plannerVersion: AdaptivePlanService.plannerVersion,
            reasonCodes: proposal.complexes.flatMap(\.reasonCodes),
            complexes: complexSnapshots
        )
    }

    @discardableResult
    static func freeze(
        plan: GeneratedWorkoutPlan,
        modelContext: ModelContext,
        prefill: [UUID: [Int: AdaptiveSetPrefill]] = [:],
        now: Date = .now
    ) throws -> AdaptiveWorkoutSession {
        guard plan.status == .proposed else { throw AdaptiveWorkoutServiceError.planNotProposed }
        guard plan.complexes.contains(where: { !$0.exercises.isEmpty }) else {
            throw AdaptiveWorkoutServiceError.emptyProposedPlan
        }
        let session = AdaptiveWorkoutSession(generatedPlanId: plan.id, createdAt: now)
        modelContext.insert(session)
        for complex in plan.complexes.sorted(by: { $0.position < $1.position }) {
            for exercise in complex.exercises.sorted(by: { $0.position < $1.position }) {
                for setIndex in 1...exercise.prescribedSetCount {
                    let prior = prefill[exercise.occurrenceId]?[setIndex]
                    modelContext.insert(
                        AdaptiveSetEntry(
                            adaptiveSessionId: session.id,
                            occurrenceId: exercise.occurrenceId,
                            exerciseId: exercise.exerciseId,
                            setIndex: setIndex,
                            weight: prior?.weight ?? 0,
                            reps: prior?.reps ?? 0
                        )
                    )
                }
            }
        }
        plan.status = .frozen
        plan.frozenAt = now
        plan.sessionId = session.id
        do {
            try modelContext.save()
            return session
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    static func canRegenerate(
        plan: GeneratedWorkoutPlan,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry]
    ) -> Bool {
        if plan.status == .proposed { return true }
        guard plan.status == .frozen,
              let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
            return false
        }
        return !setEntries.contains { $0.adaptiveSessionId == session.id && $0.isLocked }
    }

    static func discardForRegeneration(
        plan: GeneratedWorkoutPlan,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        modelContext: ModelContext
    ) throws {
        guard canRegenerate(plan: plan, adaptiveSessions: adaptiveSessions, setEntries: setEntries) else {
            throw AdaptiveWorkoutServiceError.planAlreadyStarted
        }
        if let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) {
            for entry in setEntries where entry.adaptiveSessionId == session.id {
                modelContext.delete(entry)
            }
            modelContext.delete(session)
        }
        modelContext.delete(plan)
        try modelContext.save()
    }

    static func markInProgress(plan: GeneratedWorkoutPlan, modelContext: ModelContext) throws {
        if plan.status == .frozen {
            plan.status = .inProgress
            try modelContext.save()
        }
    }

    static func substitute(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        fromExerciseId: UUID,
        toExerciseId: UUID,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
            throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
        }
        for entry in setEntries where
            entry.adaptiveSessionId == session.id && entry.occurrenceId == occurrenceId {
            entry.exerciseId = toExerciseId
            entry.weight = 0
            entry.reps = 0
            entry.isLocked = false
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                occurrenceId: occurrenceId,
                kind: .substituteExercise,
                originalExerciseId: fromExerciseId,
                replacementExerciseId: toExerciseId,
                reasonCode: "user_substitution",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func recordSkip(
        plan: GeneratedWorkoutPlan,
        complexId: UUID?,
        occurrenceId: UUID?,
        kind: AdaptiveOverrideKind,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complexId,
                occurrenceId: occurrenceId,
                kind: kind,
                reasonCode: "user_skip",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func complete(
        plan: GeneratedWorkoutPlan,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
            throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
        }
        let sessionEntries = setEntries.filter { $0.adaptiveSessionId == session.id }
        guard sessionEntries.contains(where: { $0.isLocked && $0.reps > 0 }) else {
            throw AdaptiveWorkoutServiceError.noLockedSets
        }
        for entry in sessionEntries where !entry.isLocked || entry.reps <= 0 {
            modelContext.delete(entry)
        }
        session.status = .completed
        session.finishedAt = now
        plan.status = .completed
        try modelContext.save()
    }

    private static func statusRank(_ status: AdaptivePlanStatus) -> Int {
        switch status {
        case .inProgress: return 0
        case .frozen: return 1
        case .proposed: return 2
        case .completed: return 3
        }
    }
}
