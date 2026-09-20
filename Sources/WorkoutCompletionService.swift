import Foundation
import SwiftData

/// Local completion only. A completed session with pending export is the durable
/// delivery job; exports never participate in this save or advance a rotation.
@MainActor
enum WorkoutCompletionService {
    static func completeCluster(
        _ selection: FixedCycleClusterProgramService.Selection,
        session: Session,
        modelContext: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard session.status == .draft else { return }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let setEntries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        let resistanceProfiles = try modelContext.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        let clusterOccurrences = try modelContext.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let clusterRotationStates = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
        let clusterExercisePreferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        let clusterExerciseOverrides = try modelContext.fetch(FetchDescriptor<ClusterExerciseOccurrenceOverride>())
        let priorStates = clusterRotationStates.filter {
            $0.cycleInstanceId == selection.cycleInstanceId
                && $0.templateId == selection.templateId
                && $0.programVersionID == selection.programVersionID
                && $0.clusterID == selection.cluster.rawValue
        }.map { ($0, $0.positionIndex, $0.updatedAt, $0.lastCompletedOccurrenceID, $0.isDerived) }
        do {
            guard FixedCycleClusterProgramService.occurrence(
                sessionID: session.id,
                cluster: selection.cluster,
                occurrences: clusterOccurrences
            ) == nil else { return }
            let occurrence = try FixedCycleClusterProgramService.makeOccurrence(
                session: session,
                selection: selection,
                exercises: exercises,
                entries: setEntries,
                resistanceProfiles: resistanceProfiles,
                preferences: clusterExercisePreferences,
                overrides: clusterExerciseOverrides
            )
            let clusterExerciseIDs = Set(FixedCycleClusterProgramService.resolvedSlots(
                selection: selection,
                sessionId: session.id,
                preferences: clusterExercisePreferences,
                overrides: clusterExerciseOverrides
            ).map(\.exerciseId))
            for entry in setEntries where
                entry.sessionId == session.id
                    && clusterExerciseIDs.contains(entry.exerciseId)
                    && (!entry.isLocked || entry.reps <= 0) {
                modelContext.delete(entry)
            }
            modelContext.insert(occurrence)
            _ = try FixedCycleClusterProgramService.advanceCompletedCluster(
                selection: selection,
                occurrence: occurrence,
                states: clusterRotationStates
            )
            try save(modelContext)
        } catch {
            modelContext.processPendingChanges()
            modelContext.rollback()
            // SwiftData rollback restores storage/deletions, but registered model
            // instances can retain changed scalar values. Restore the visible state.
            for (state, position, updatedAt, occurrenceID, derived) in priorStates {
                state.positionIndex = position
                state.updatedAt = updatedAt
                state.lastCompletedOccurrenceID = occurrenceID
                state.isDerived = derived
            }
            throw error
        }
    }

    static func finishFixed(
        session: Session,
        cycle: ActiveCycleInstance,
        template: CycleTemplate,
        modelContext: ModelContext,
        now: Date = .now,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard session.status == .draft else { return }
        let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
        let setEntries = try modelContext.fetch(FetchDescriptor<SetEntry>())
        let clusterOccurrences = try modelContext.fetch(FetchDescriptor<ClusterOccurrenceRecord>())
        let clusterRotationStates = try modelContext.fetch(FetchDescriptor<ClusterRotationState>())
        let clusterExercisePreferences = try modelContext.fetch(FetchDescriptor<ClusterExercisePreference>())
        let clusterExerciseOverrides = try modelContext.fetch(FetchDescriptor<ClusterExerciseOccurrenceOverride>())
        let slotOverrides = try modelContext.fetch(FetchDescriptor<SessionSlotOverride>())
        let fixedReadiness = try modelContext.fetch(FetchDescriptor<FixedCycleReadinessObservation>())
        let fixedOverrides = try modelContext.fetch(FetchDescriptor<FixedCycleOccurrenceOverride>())
        let priorStatus = session.status
        let priorFinishedAt = session.finishedAt
        let priorExportStatus = session.exportStatus
        let priorCycleName = session.cycleNameSnapshot
        let priorDayLabel = session.dayLabelSnapshot
        let priorDayIndex = cycle.currentDayIndex
        let persistedFixedSnapshots = try modelContext.fetch(FetchDescriptor<FixedCycleExerciseSnapshot>())
        let priorSnapshots = persistedFixedSnapshots.filter { $0.sessionId == session.id }.map { ($0, $0.statusRawValue, $0.skipReason) }
        do {
            let isClustered = FixedCycleClusterProgramService.isProgramTemplate(template)
            guard FixedCycleWorkoutService.canIntentionallyComplete(
                sessionId: session.id,
                entries: setEntries,
                isClusteredProgram: isClustered,
                hasCompletedCluster: clusterOccurrences.contains(where: { $0.sessionId == session.id })
            ) else {
                throw FixedCycleWorkoutError.qualifyingSetRequired
            }
            let currentClusterSelections: [FixedCycleClusterProgramService.Selection]
            if isClustered {
                currentClusterSelections = try FixedCycleClusterProgramService.selections(
                    template: template,
                    cycleInstanceId: cycle.id,
                    states: clusterRotationStates
                )
                try FixedCycleWorkoutService.validateClusteredFinish(
                    sessionId: session.id,
                    entries: setEntries,
                    selections: currentClusterSelections,
                    occurrences: clusterOccurrences,
                    preferences: clusterExercisePreferences,
                    clusterOverrides: clusterExerciseOverrides
                )
            } else {
                currentClusterSelections = []
            }
            let dayIndex = session.cycleDayIndex

            // Keep only confirmed logged sets in completed sessions/history/export.
            let sessionEntries = setEntries.filter { $0.sessionId == session.id }
            let retainedSessionEntries: [SetEntry]
            if isClustered {
                let completedClusterIDs = Set(clusterOccurrences.compactMap { occurrence in
                    occurrence.sessionId == session.id ? occurrence.clusterID : nil
                })
                let uncompletedExerciseIDs = Set(
                    currentClusterSelections
                    .filter { !completedClusterIDs.contains($0.cluster.rawValue) }
                    .flatMap {
                        FixedCycleClusterProgramService.resolvedSlots(
                            selection: $0,
                            sessionId: session.id,
                            preferences: clusterExercisePreferences,
                            overrides: clusterExerciseOverrides
                        ).map(\.exerciseId)
                    }
                )
                retainedSessionEntries = FixedCycleWorkoutService.retainedCompletedClusterEntries(
                    sessionId: session.id,
                    entries: sessionEntries,
                    occurrences: clusterOccurrences,
                    uncompletedClusterExerciseIds: uncompletedExerciseIDs
                )
            } else {
                retainedSessionEntries = sessionEntries.filter {
                    $0.reps > 0 && $0.isLocked
                }
            }
            let retainedEntryIDs = Set(retainedSessionEntries.map(\.id))
            for entry in sessionEntries where !retainedEntryIDs.contains(entry.id) {
                modelContext.delete(entry)
            }
            for override in slotOverrides where override.sessionId == session.id {
                modelContext.delete(override)
            }

            session.status = .completed
            session.finishedAt = now
            session.exportStatus = .pending
            if !isClustered {
                session.cycleNameSnapshot = template.name
            }
            let orderedDays = CycleOrdering.sortedDays(template.days)
            if isClustered {
                let completedNames = FixedCycleClusterProgramService.Cluster.allCases.compactMap { cluster in
                    clusterOccurrences.contains {
                        $0.sessionId == session.id && $0.clusterID == cluster.rawValue
                    } ? cluster.displayName : nil
                }
                session.dayLabelSnapshot = completedNames.joined(separator: " + ")
            } else if dayIndex >= 0, dayIndex < orderedDays.count {
                session.dayLabelSnapshot = orderedDays[dayIndex].label
            }
            let fixedMetadata: SessionExportService.FixedCycleMetadata?
            if isClustered,
               let frozenOccurrence = clusterOccurrences
                .filter({ $0.sessionId == session.id })
                .sorted(by: { $0.clusterID < $1.clusterID })
                .first {
                fixedMetadata = SessionExportService.fixedCycleMetadata(
                    session: session,
                    template: template,
                    day: CycleDay(
                        label: frozenOccurrence.dayLabel,
                        slots: [],
                        position: frozenOccurrence.templateDayPosition
                    ),
                    exercises: exercises,
                    setEntries: retainedSessionEntries,
                    readiness: fixedReadiness,
                    overrides: fixedOverrides,
                    snapshots: persistedFixedSnapshots,
                    clusterOccurrences: clusterOccurrences,
                    clusterRotationStates: clusterRotationStates,
                    clusterExercisePreferences: clusterExercisePreferences,
                    clusterExerciseOverrides: clusterExerciseOverrides
                )
            } else if dayIndex >= 0 && dayIndex < orderedDays.count {
                fixedMetadata = SessionExportService.fixedCycleMetadata(
                    session: session,
                    template: template,
                    day: orderedDays[dayIndex],
                    exercises: exercises,
                    setEntries: retainedSessionEntries,
                    readiness: fixedReadiness,
                    overrides: fixedOverrides,
                    snapshots: persistedFixedSnapshots,
                    clusterOccurrences: [],
                    clusterRotationStates: clusterRotationStates,
                    clusterExercisePreferences: clusterExercisePreferences,
                    clusterExerciseOverrides: clusterExerciseOverrides
                )
            } else {
                fixedMetadata = nil
            }
            for item in fixedMetadata?.ordered_exercises ?? [] {
                guard let exerciseId = UUID(uuidString: item.exercise_id),
                      let muscle = MuscleGroup(rawValue: item.muscle) else {
                    continue
                }
                if let existing = persistedFixedSnapshots.first(where: {
                    $0.sessionId == session.id
                        && $0.position == item.position
                        && $0.exerciseId == exerciseId
                }) {
                    existing.statusRawValue = item.status
                    existing.skipReason = item.skip_reason
                } else {
                    modelContext.insert(
                        FixedCycleExerciseSnapshot(
                            sessionId: session.id,
                            position: item.position,
                            exerciseId: exerciseId,
                            exerciseName: item.exercise_name,
                            muscle: muscle,
                            statusRawValue: item.status,
                            skipReason: item.skip_reason
                        )
                    )
                }
            }

            if !isClustered {
                cycle.currentDayIndex = (dayIndex + 1) % max(template.days.count, 1)
            }
            try cycle.validate(template: template)
            try save(modelContext)
        } catch {
            modelContext.processPendingChanges()
            modelContext.rollback()
            session.status = priorStatus
            session.finishedAt = priorFinishedAt
            session.exportStatus = priorExportStatus
            session.cycleNameSnapshot = priorCycleName
            session.dayLabelSnapshot = priorDayLabel
            cycle.currentDayIndex = priorDayIndex
            for (snapshot, status, reason) in priorSnapshots {
                snapshot.statusRawValue = status
                snapshot.skipReason = reason
            }
            throw error
        }
    }
}
