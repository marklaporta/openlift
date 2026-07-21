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
    case noLockedSets
    case planCompleted

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
        case .noLockedSets:
            return "Lock at least one completed set before finishing the workout."
        case .planCompleted:
            return "A completed workout cannot be reordered."
        }
    }
}

enum AdaptiveMovementDirection {
    case earlier
    case later
}

enum AdaptiveWorkoutPhase: String, Equatable {
    case readiness
    case design
    case execute
    case completed
}

struct AdaptiveSetPrefill: Equatable {
    var weight: Double
    var reps: Int
}

enum AdaptiveWorkoutService {
    static let recoveredReadiness = MuscleReadinessInput(
        soreness: .none,
        connectiveTissuePain: .none,
        eagerness: .eager
    )

    static func defaultReadinessInputs(for program: AdaptiveProgram) -> [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: program.muscleRules.filter(\.isEnabled).map {
            ($0.muscle, recoveredReadiness)
        })
    }

    static func phase(for plan: GeneratedWorkoutPlan?) -> AdaptiveWorkoutPhase {
        guard let plan else { return .readiness }
        switch plan.status {
        case .proposed: return .design
        case .frozen, .inProgress: return .execute
        case .completed: return .completed
        }
    }

    static func canonicalSignature(for plan: GeneratedWorkoutPlan) -> String {
        plan.complexes.sorted { $0.position < $1.position }.map { complex in
            let exercises = complex.exercises.sorted { $0.position < $1.position }.map {
                "\($0.exerciseId.uuidString):\($0.prescribedSetCount)"
            }.joined(separator: ",")
            return "\(complex.primaryMuscle.rawValue):\(complex.sourceDefinitionId.uuidString):\(exercises)"
        }.joined(separator: "|")
    }

    static func makeDesignState(
        plan: GeneratedWorkoutPlan,
        targetComplexCount: Int,
        readinessRevision: Int
    ) -> AdaptivePlanDesignState {
        AdaptivePlanDesignState(
            generatedPlanId: plan.id,
            targetComplexCount: max(1, targetComplexCount),
            readinessRevision: readinessRevision,
            canonicalSignature: canonicalSignature(for: plan)
        )
    }

    /// Reuses the visible proposal when the canonical recommendation is
    /// equivalent, preserving any manual Design edits. A material change
    /// replaces the complete proposal snapshot; there is no partial repair path.
    @MainActor
    @discardableResult
    static func reconcileReadinessRevision(
        existingPlan: GeneratedWorkoutPlan,
        existingState: AdaptivePlanDesignState,
        candidatePlan: GeneratedWorkoutPlan,
        readinessCheck: DailyReadinessCheck,
        overrides: [AdaptiveOverrideEvent] = [],
        modelContext: ModelContext
    ) throws -> Bool {
        guard existingPlan.status == .proposed else {
            throw AdaptiveWorkoutServiceError.planAlreadyStarted
        }
        let candidateSignature = canonicalSignature(for: candidatePlan)
        if candidateSignature == existingState.canonicalSignature {
            existingPlan.readinessCheckId = readinessCheck.id
            existingState.readinessRevision = readinessCheck.revision
            existingState.updatedAt = .now
            try modelContext.save()
            return true
        }

        let target = existingState.targetComplexCount
        deleteAuditRecords(
            generatedPlanId: existingPlan.id,
            overrides: overrides,
            modelContext: modelContext
        )
        modelContext.delete(existingState)
        modelContext.delete(existingPlan)
        modelContext.insert(candidatePlan)
        modelContext.insert(
            AdaptivePlanDesignState(
                generatedPlanId: candidatePlan.id,
                targetComplexCount: target,
                readinessRevision: readinessCheck.revision,
                canonicalSignature: candidateSignature
            )
        )
        try modelContext.save()
        return false
    }

    @discardableResult
    static func movePlannedMovement(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        direction: AdaptiveMovementDirection,
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Bool {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        let orderedComplexes = plan.complexes.sorted { $0.position < $1.position }
        guard let complexIndex = orderedComplexes.firstIndex(where: {
            $0.exercises.contains { $0.occurrenceId == occurrenceId }
        }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        let complex = orderedComplexes[complexIndex]
        let orderedExercises = complex.exercises.sorted { $0.position < $1.position }
        guard let exerciseIndex = orderedExercises.firstIndex(where: { $0.occurrenceId == occurrenceId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }

        switch direction {
        case .earlier where exerciseIndex > 0:
            swapPositions(orderedExercises[exerciseIndex], orderedExercises[exerciseIndex - 1])
        case .later where exerciseIndex < orderedExercises.count - 1:
            swapPositions(orderedExercises[exerciseIndex], orderedExercises[exerciseIndex + 1])
        case .earlier where complexIndex > 0:
            swapPositions(complex, orderedComplexes[complexIndex - 1])
        case .later where complexIndex < orderedComplexes.count - 1:
            swapPositions(complex, orderedComplexes[complexIndex + 1])
        default:
            return false
        }

        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                occurrenceId: occurrenceId,
                kind: .reorderExercise,
                muscle: orderedExercises[exerciseIndex].primaryMuscle,
                reasonCode: plan.status == .proposed
                    ? "user_reordered_before_freeze"
                    : "user_reordered_frozen_workout",
                createdAt: now
            )
        )
        try modelContext.save()
        return true
    }

    private static func swapPositions(_ first: PlannedExerciseSnapshot, _ second: PlannedExerciseSnapshot) {
        let position = first.position
        first.position = second.position
        second.position = position
    }

    private static func swapPositions(_ first: PlannedComplexSnapshot, _ second: PlannedComplexSnapshot) {
        let position = first.position
        first.position = second.position
        second.position = position
    }

    @discardableResult
    static func moveComplex(
        plan: GeneratedWorkoutPlan,
        complexId: UUID,
        direction: AdaptiveMovementDirection,
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> Bool {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        let ordered = plan.complexes.sorted { $0.position < $1.position }
        guard let index = ordered.firstIndex(where: { $0.id == complexId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        let destination: Int
        switch direction {
        case .earlier: destination = index - 1
        case .later: destination = index + 1
        }
        guard ordered.indices.contains(destination) else { return false }
        swapPositions(ordered[index], ordered[destination])
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complexId,
                kind: .reorderComplex,
                muscle: ordered[index].primaryMuscle,
                reasonCode: "user_reordered_active_complex",
                createdAt: now
            )
        )
        try modelContext.save()
        return true
    }

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
        let replacementDifficulty = AdaptiveExerciseRoleService.difficulty(for: exercise)

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
        let effectiveDifficulty = AdaptiveExerciseRoleService.difficulty(for: exercise)

        let snapshot = PlannedExerciseSnapshot(
            position: 0,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: exercise.primaryMuscle,
            difficulty: effectiveDifficulty,
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

    @discardableResult
    static func appendComplex(
        plan: GeneratedWorkoutPlan,
        definition: AdaptiveExerciseComplex?,
        manualExercise: Exercise? = nil,
        manualPrescribedSetCount: Int = 2,
        exercises: [Exercise],
        adaptiveSessions: [AdaptiveWorkoutSession],
        prefill: [UUID: [Int: AdaptiveSetPrefill]] = [:],
        prefillByExerciseId: [UUID: [Int: AdaptiveSetPrefill]] = [:],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> PlannedComplexSnapshot {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        let session: AdaptiveWorkoutSession?
        if plan.status == .proposed {
            session = nil
        } else {
            guard let existing = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
                throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
            }
            session = existing
        }
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let plannedExercises: [PlannedExerciseSnapshot]
        let sourceDefinitionId: UUID
        let sourceVersion: Int
        let name: String
        let muscle: MuscleGroup

        if let definition {
            sourceDefinitionId = definition.definitionId
            sourceVersion = definition.version
            name = definition.name
            muscle = definition.primaryMuscle
            plannedExercises = definition.components.sorted { $0.position < $1.position }.compactMap { component in
                guard let exercise = exercisesById[component.exerciseId], exercise.isActive else { return nil }
                return PlannedExerciseSnapshot(
                    position: component.position,
                    exerciseId: exercise.id,
                    exerciseName: exercise.name,
                    primaryMuscle: exercise.primaryMuscle,
                    secondaryMuscle: component.secondaryMuscle,
                    difficulty: AdaptiveExerciseRoleService.difficulty(for: exercise),
                    prescribedSetCount: max(1, component.prescribedSetCount)
                )
            }
        } else if let exercise = manualExercise {
            sourceDefinitionId = UUID()
            sourceVersion = 0
            name = exercise.primaryMuscle.displayName
            muscle = exercise.primaryMuscle
            plannedExercises = [
                PlannedExerciseSnapshot(
                    position: 0,
                    exerciseId: exercise.id,
                    exerciseName: exercise.name,
                    primaryMuscle: exercise.primaryMuscle,
                    difficulty: AdaptiveExerciseRoleService.difficulty(for: exercise),
                    prescribedSetCount: max(1, manualPrescribedSetCount)
                )
            ]
        } else {
            throw AdaptiveWorkoutServiceError.emptyProposedPlan
        }
        guard !plannedExercises.isEmpty else { throw AdaptiveWorkoutServiceError.emptyProposedPlan }

        let snapshot = PlannedComplexSnapshot(
            sourceDefinitionId: sourceDefinitionId,
            sourceVersion: sourceVersion,
            position: (plan.complexes.map(\.position).max() ?? -1) + 1,
            name: name,
            primaryMuscle: muscle,
            reasonCodes: ["user_added_complex"],
            exercises: plannedExercises
        )
        plan.complexes.append(snapshot)

        if let session {
            for exercise in plannedExercises {
                for setIndex in 1...exercise.prescribedSetCount {
                    let prior = prefill[exercise.occurrenceId]?[setIndex]
                        ?? prefillByExerciseId[exercise.exerciseId]?[setIndex]
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
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: snapshot.id,
                kind: .addComplex,
                muscle: muscle,
                reasonCode: "user_added_complex",
                createdAt: now
            )
        )
        try modelContext.save()
        return snapshot
    }

    @discardableResult
    static func addMovementToComplex(
        plan: GeneratedWorkoutPlan,
        complexId: UUID,
        exercise: Exercise,
        difficulty: MovementDifficulty,
        prescribedSetCount: Int,
        adaptiveSessions: [AdaptiveWorkoutSession],
        prefill: [Int: AdaptiveSetPrefill] = [:],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> PlannedExerciseSnapshot {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        guard let complex = plan.complexes.first(where: { $0.id == complexId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        let effectiveDifficulty = AdaptiveExerciseRoleService.difficulty(for: exercise)

        let session: AdaptiveWorkoutSession?
        if plan.status == .proposed {
            session = nil
        } else {
            guard let existing = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
                throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
            }
            session = existing
        }

        let setCount = max(1, prescribedSetCount)
        let snapshot = PlannedExerciseSnapshot(
            position: (complex.exercises.map(\.position).max() ?? -1) + 1,
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: exercise.primaryMuscle,
            difficulty: effectiveDifficulty,
            prescribedSetCount: setCount
        )
        complex.exercises.append(snapshot)
        if let session {
            for setIndex in 1...setCount {
                let previous = prefill[setIndex]
                modelContext.insert(
                    AdaptiveSetEntry(
                        adaptiveSessionId: session.id,
                        occurrenceId: snapshot.occurrenceId,
                        exerciseId: exercise.id,
                        setIndex: setIndex,
                        weight: previous?.weight ?? 0,
                        reps: previous?.reps ?? 0
                    )
                )
            }
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                occurrenceId: snapshot.occurrenceId,
                kind: .addExercise,
                muscle: exercise.primaryMuscle,
                replacementExerciseId: exercise.id,
                reasonCode: plan.status == .proposed
                    ? "user_added_to_complex_before_freeze"
                    : "user_added_to_frozen_complex",
                createdAt: now
            )
        )
        try modelContext.save()
        return snapshot
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

    static func removeMovement(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        guard let complex = plan.complexes.first(where: {
            $0.exercises.contains { $0.occurrenceId == occurrenceId }
        }), let snapshot = complex.exercises.first(where: { $0.occurrenceId == occurrenceId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        if let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) {
            for entry in setEntries where
                entry.adaptiveSessionId == session.id && entry.occurrenceId == occurrenceId {
                modelContext.delete(entry)
            }
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                occurrenceId: occurrenceId,
                kind: .removeExercise,
                muscle: snapshot.primaryMuscle,
                originalExerciseId: snapshot.exerciseId,
                reasonCode: "user_removed_active_exercise",
                createdAt: now
            )
        )
        if complex.exercises.count == 1 {
            plan.complexes.removeAll { $0.id == complex.id }
            modelContext.delete(complex)
        } else {
            complex.exercises.removeAll { $0.occurrenceId == occurrenceId }
            modelContext.delete(snapshot)
            normalizeExercisePositions(in: complex)
        }
        normalizeComplexPositions(in: plan)
        try modelContext.save()
    }

    static func removeComplex(
        plan: GeneratedWorkoutPlan,
        complexId: UUID,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        feedback: [ComplexFeedback],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        guard let complex = plan.complexes.first(where: { $0.id == complexId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        let occurrenceIds = Set(complex.exercises.map(\.occurrenceId))
        if let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) {
            for entry in setEntries where
                entry.adaptiveSessionId == session.id && occurrenceIds.contains(entry.occurrenceId) {
                modelContext.delete(entry)
            }
        }
        for item in feedback where item.generatedPlanId == plan.id && item.plannedComplexId == complex.id {
            modelContext.delete(item)
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complex.id,
                kind: .removeComplex,
                muscle: complex.primaryMuscle,
                reasonCode: "user_removed_active_complex",
                createdAt: now
            )
        )
        plan.complexes.removeAll { $0.id == complex.id }
        modelContext.delete(complex)
        normalizeComplexPositions(in: plan)
        try modelContext.save()
    }

    private static func normalizeExercisePositions(in complex: PlannedComplexSnapshot) {
        for (position, exercise) in complex.exercises.sorted(by: { $0.position < $1.position }).enumerated() {
            exercise.position = position
        }
    }

    private static func normalizeComplexPositions(in plan: GeneratedWorkoutPlan) {
        for (position, complex) in plan.complexes.sorted(by: { $0.position < $1.position }).enumerated() {
            complex.position = position
        }
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
        exerciseSelections: [MuscleGroup: AdaptiveExerciseSelectionRecommendation] = [:],
        now: Date = .now
    ) throws -> GeneratedWorkoutPlan {
        guard case .proposal(let proposal) = result else {
            guard case .infeasible(let conflict) = result else { fatalError("Unknown planner result") }
            throw AdaptiveWorkoutServiceError.plannerConflict(conflict)
        }
        var appliedSelectionMuscles = Set<MuscleGroup>()
        let complexSnapshots = proposal.complexes.enumerated().map { index, complex in
            var reasonCodes = complex.reasonCodes
            let exerciseSnapshots = complex.components.enumerated().map { componentIndex, component in
                let selection = appliedSelectionMuscles.contains(component.primaryMuscle)
                    ? nil
                    : exerciseSelections[component.primaryMuscle]
                let selectedExercise = selection?.exercise
                if let selection {
                    appliedSelectionMuscles.insert(component.primaryMuscle)
                    reasonCodes.append("\(component.primaryMuscle.rawValue)_\(selection.reasonCodeSuffix)")
                }
                let changedExercise = selectedExercise?.id != nil && selectedExercise?.id != component.exerciseId
                return PlannedExerciseSnapshot(
                    position: componentIndex,
                    exerciseId: selectedExercise?.id ?? component.exerciseId,
                    exerciseName: selectedExercise?.name ?? component.exerciseName,
                    primaryMuscle: component.primaryMuscle,
                    secondaryMuscle: changedExercise ? nil : component.secondaryMuscle,
                    difficulty: selectedExercise.map {
                        AdaptiveExerciseRoleService.difficulty(for: $0)
                    } ?? component.difficulty,
                    prescribedSetCount: component.prescribedSetCount
                )
            }
            return PlannedComplexSnapshot(
                sourceDefinitionId: complex.definitionId,
                sourceVersion: complex.version,
                position: index,
                name: complex.name,
                primaryMuscle: complex.primaryMuscle,
                reasonCodes: reasonCodes,
                exercises: exerciseSnapshots
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
        overrides: [AdaptiveOverrideEvent] = [],
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
        deleteAuditRecords(
            generatedPlanId: plan.id,
            overrides: overrides,
            modelContext: modelContext
        )
        modelContext.delete(plan)
        try modelContext.save()
    }

    static func deleteAuditRecords(
        generatedPlanId: UUID,
        overrides: [AdaptiveOverrideEvent],
        modelContext: ModelContext
    ) {
        for event in overrides where event.generatedPlanId == generatedPlanId {
            modelContext.delete(event)
        }
    }

    static func markInProgress(plan: GeneratedWorkoutPlan, modelContext: ModelContext) throws {
        if plan.status == .frozen {
            plan.status = .inProgress
            try modelContext.save()
        }
    }

    @discardableResult
    static func addSet(
        snapshot: PlannedExerciseSnapshot,
        session: AdaptiveWorkoutSession,
        existingEntries: [AdaptiveSetEntry],
        modelContext: ModelContext
    ) throws -> AdaptiveSetEntry {
        let entry = AdaptiveSetEntry(
            adaptiveSessionId: session.id,
            occurrenceId: snapshot.occurrenceId,
            exerciseId: existingEntries.first?.exerciseId ?? snapshot.exerciseId,
            setIndex: (existingEntries.map(\.setIndex).max() ?? 0) + 1
        )
        modelContext.insert(entry)
        snapshot.prescribedSetCount = existingEntries.count + 1
        try modelContext.save()
        return entry
    }

    /// Locked rows are intentionally removable while a workout is active. An
    /// exercise may temporarily have zero rows; its inline add control restores
    /// a new editable row without changing other work.
    @discardableResult
    static func removeLastSet(
        snapshot: PlannedExerciseSnapshot,
        existingEntries: [AdaptiveSetEntry],
        modelContext: ModelContext
    ) throws -> Bool {
        guard let last = existingEntries.max(by: { $0.setIndex < $1.setIndex }) else { return false }
        modelContext.delete(last)
        snapshot.prescribedSetCount = max(0, existingEntries.count - 1)
        try modelContext.save()
        return true
    }

    static func substitute(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        fromExerciseId: UUID,
        to exercise: Exercise,
        difficulty: MovementDifficulty,
        adaptiveSessions: [AdaptiveWorkoutSession],
        setEntries: [AdaptiveSetEntry],
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard let session = adaptiveSessions.first(where: { $0.generatedPlanId == plan.id }) else {
            throw AdaptiveWorkoutServiceError.adaptiveSessionNotFound
        }
        let effectiveDifficulty = AdaptiveExerciseRoleService.difficulty(for: exercise)
        guard let snapshot = plan.complexes.flatMap(\.exercises).first(where: {
            $0.occurrenceId == occurrenceId
        }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        for entry in setEntries where
            entry.adaptiveSessionId == session.id && entry.occurrenceId == occurrenceId {
            entry.exerciseId = exercise.id
        }
        snapshot.exerciseId = exercise.id
        snapshot.exerciseName = exercise.name
        snapshot.primaryMuscle = exercise.primaryMuscle
        snapshot.secondaryMuscle = nil
        snapshot.difficulty = effectiveDifficulty
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                occurrenceId: occurrenceId,
                kind: .substituteExercise,
                originalExerciseId: fromExerciseId,
                replacementExerciseId: exercise.id,
                reasonCode: "user_corrected_active_exercise",
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

    static func recordUnskipExercise(
        plan: GeneratedWorkoutPlan,
        occurrenceId: UUID,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        guard plan.complexes.flatMap(\.exercises).contains(where: {
            $0.occurrenceId == occurrenceId
        }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                occurrenceId: occurrenceId,
                kind: .unskipExercise,
                reasonCode: "user_unskip",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func recordUnskipComplex(
        plan: GeneratedWorkoutPlan,
        complexId: UUID,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard plan.status != .completed else { throw AdaptiveWorkoutServiceError.planCompleted }
        guard plan.complexes.contains(where: { $0.id == complexId }) else {
            throw AdaptiveWorkoutServiceError.plannedExerciseNotFound
        }
        modelContext.insert(
            AdaptiveOverrideEvent(
                generatedPlanId: plan.id,
                plannedComplexId: complexId,
                kind: .unskipComplex,
                reasonCode: "user_unskip",
                createdAt: now
            )
        )
        try modelContext.save()
    }

    static func isComplexSkipped(
        planId: UUID,
        complexId: UUID,
        overrides: [AdaptiveOverrideEvent]
    ) -> Bool {
        overrides
            .filter {
                $0.generatedPlanId == planId
                    && $0.plannedComplexId == complexId
                    && ($0.kind == .skipComplex || $0.kind == .unskipComplex)
            }
            .max {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }?
            .kind == .skipComplex
    }

    static func isExerciseSkipped(
        planId: UUID,
        occurrenceId: UUID,
        overrides: [AdaptiveOverrideEvent]
    ) -> Bool {
        overrides
            .filter {
                $0.generatedPlanId == planId
                    && $0.occurrenceId == occurrenceId
                    && ($0.kind == .skipExercise || $0.kind == .unskipExercise)
            }
            .max {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }?
            .kind == .skipExercise
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
