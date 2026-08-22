import SwiftData
import XCTest
@testable import OpenLift

final class ClusteredProgramTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateId")
        UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateName")
        super.tearDown()
    }

    private func program() throws -> (
        [Exercise], CycleTemplate, ActiveCycleInstance, [FixedCycleClusterPointer]
    ) {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises)
        let cycle = ActiveCycleInstance(templateId: template.id)
        return (
            exercises,
            template,
            cycle,
            FixedCycleClusterProgramService.makeRotationStates(
                cycleInstanceId: cycle.id,
                templateId: template.id
            )
        )
    }

    private func clusteredExport(
        sessionID: UUID = UUID(),
        occurrenceID: UUID = UUID(),
        template: CycleTemplate,
        cycle: ActiveCycleInstance,
        exercise: Exercise,
        cluster: FixedCycleClusterProgramService.Cluster = .cluster1,
        absoluteStep: Int,
        pointerCount: Int,
        date: Date
    ) -> SessionExportService.ExportPayload {
        let effectiveStep = absoluteStep % cluster.rotationLength
        let dayPosition = cluster.templateBasePosition + effectiveStep
        let dayLabel = "\(cluster.displayName) · \(FixedCycleClusterProgramService.variantLabel(effectiveStep))"
        let snapshot = SessionExportService.ClusterExerciseOccurrencePayload(
            position: 0,
            exercise_id: exercise.id.uuidString,
            exercise_name: exercise.name,
            muscle: exercise.primaryMuscle.rawValue,
            prescribed_set_count: 3,
            progression_key: FixedCycleClusterProgramService.progressionKey(
                cluster: cluster,
                effectiveStep: effectiveStep,
                slotPosition: 0
            ),
            resistance_profile: nil,
            completion_status: FixedCycleProgressionStatus.performed.rawValue
        )
        let occurrence = SessionExportService.ClusterOccurrencePayload(
            occurrence_id: occurrenceID.uuidString,
            program_version_id: FixedCycleClusterProgramService.programVersionID,
            cluster_id: cluster.rawValue,
            position_index: absoluteStep,
            template_day_position: dayPosition,
            day_label: dayLabel,
            completed_at: ISO8601DateFormatter().string(from: date),
            exercises: [snapshot]
        )
        let pointer = SessionExportService.FixedCycleClusterPointerPayload(
            program_version_id: FixedCycleClusterProgramService.programVersionID,
            cluster_id: cluster.rawValue,
            position_index: pointerCount,
            updated_at: ISO8601DateFormatter().string(from: date),
            last_completed_occurrence_id: occurrenceID.uuidString,
            is_derived: false
        )
        let metadata = SessionExportService.FixedCycleMetadata(
            schema_version: 4,
            template_id: template.id.uuidString,
            cycle_instance_id: cycle.id.uuidString,
            day_label: dayLabel,
            ordered_exercises: [],
            readiness: [],
            skips: [],
            program_identifier: FixedCycleClusterProgramService.programIdentifier,
            program_version: FixedCycleClusterProgramService.structureVersion,
            cluster_key: cluster.rawValue,
            absolute_cluster_step: absoluteStep,
            cluster_occurrences: [occurrence],
            cluster_rotation_states: [pointer]
        )
        return SessionExportService.ExportPayload(
            session_id: sessionID.uuidString,
            cycle_name: template.name,
            cycle_day_index: dayPosition,
            date: ISO8601DateFormatter().string(from: date),
            exercises: [],
            workout_kind: "rotation",
            fixed_cycle: metadata
        )
    }

    func testProgramContainsLockedThreeSixSixRotations() throws {
        let (exercises, template, cycle, states) = try program()
        let names = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
        let selections = try FixedCycleClusterProgramService.selections(
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )

        XCTAssertEqual(template.days.count, 15)
        XCTAssertEqual(selections.map(\.effectiveStep), [0, 0, 0])
        XCTAssertEqual(
            template.days.sorted { $0.position < $1.position }.map { day in
                CycleOrdering.sortedSlots(day.slots).compactMap { names[$0.exerciseId] }
            },
            [
                ["Incline Dumbbell Press", "Lat Pulldown"],
                ["Flat Dumbbell Press", "Lat Prayer"],
                ["Incline Dumbbell Press-Flye", "Chest Supported Row"],
                ["Belt Squat", "Overhead Cable Extension", "Incline Curl"],
                ["Stiff-Leg Deadlift", "Cable Pushdown", "Dumbbell Preacher Curl"],
                ["Sumo Belt Squat", "Dumbbell Skullcrusher", "Bayesian Curl"],
                ["Back Extension", "Overhead Cable Extension", "Incline Curl"],
                ["Bulgarian Split Squat", "Cable Pushdown", "Dumbbell Preacher Curl"],
                ["Leg Curl", "Dumbbell Skullcrusher", "Bayesian Curl"],
                ["Super ROM Dumbbell Lateral Raise", "Stair Calves"],
                ["Cable Lateral Raise", "Bench-Supported Cable Wrist Curl (Supinated)"],
                ["Super ROM Dumbbell Lateral Raise", "Stair Calves"],
                ["Cable Lateral Raise", "Bench-Supported Cable Wrist Extension (Pronated)"],
                ["Super ROM Dumbbell Lateral Raise", "Stair Calves"],
                ["Cable Lateral Raise", "Captains of Crush"]
            ]
        )
        XCTAssertTrue(template.days.flatMap(\.slots).allSatisfy { $0.defaultSetCount == 3 })
        XCTAssertEqual(
            FixedCycleClusterProgramService.defaultResistanceProfile(
                forExerciseNamed: "Bench-Supported Cable Wrist Extension (Pronated)"
            ),
            .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30)
        )
    }

    func testCompletingOneClusterAdvancesOnlyThatPointerAndAllowsAllSkippedSets() throws {
        let (exercises, template, cycle, states) = try program()
        let selection = try FixedCycleClusterProgramService.selection(
            cluster: .cluster2,
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)

        let occurrence = try FixedCycleClusterProgramService.makeOccurrence(
            session: session,
            selection: selection,
            exercises: exercises,
            entries: [],
            resistanceProfiles: []
        )
        XCTAssertEqual(occurrence.exerciseSnapshots.map(\.completionStatus), [
            .skipped, .skipped, .skipped
        ])
        _ = try FixedCycleClusterProgramService.advanceCompletedCluster(
            selection: selection,
            occurrence: occurrence,
            states: states
        )

        let next = try FixedCycleClusterProgramService.selections(
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        XCTAssertEqual(next.map(\.absoluteStep), [0, 1, 0])
        XCTAssertEqual(states.map(\.positionIndex), [0, 1, 0])
    }

    func testCompletedClusterEvidenceRetainsOnlyPerformedExerciseRows() throws {
        let (exercises, template, cycle, states) = try program()
        let selection = try FixedCycleClusterProgramService.selection(
            cluster: .cluster2,
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let performedExercise = try XCTUnwrap(selection.day.slots.first?.exerciseId)
        let occurrence = try FixedCycleClusterProgramService.makeOccurrence(
            session: session,
            selection: selection,
            exercises: exercises,
            entries: [
                SetEntry(
                    sessionId: session.id,
                    exerciseId: performedExercise,
                    setIndex: 1,
                    weight: 100,
                    reps: 10,
                    isLocked: true
                )
            ],
            resistanceProfiles: []
        )

        XCTAssertEqual(
            FixedCycleWorkoutService.completedClusterExerciseIds(
                sessionId: session.id,
                occurrences: [occurrence]
            ),
            [performedExercise]
        )
    }

    func testClusteredDraftCarriesForwardManualSetCountReduction() {
        let effort = ExerciseEffortLookupResult(
            sessionId: UUID(),
            completedAt: Date(timeIntervalSince1970: 100),
            sourceKind: .fixedCycle,
            matchKind: .sameProgressionIdentity,
            cycleName: FixedCycleClusterProgramService.templateName,
            dayLabel: "Cluster 1 · A",
            rows: [
                ComparableSetRow(setIndex: 1, weight: 20, reps: 12, isLocked: true),
                ComparableSetRow(setIndex: 2, weight: 20, reps: 10, isLocked: true)
            ],
            resistanceProfile: nil,
            profileComparison: .unknown
        )

        XCTAssertEqual(
            FixedCycleWorkoutService.draftSetCount(defaultSetCount: 3, effort: effort),
            2
        )
        XCTAssertEqual(
            FixedCycleWorkoutService.draftSetCount(defaultSetCount: 3, effort: nil),
            3
        )
    }

    func testTemplateReusesExistingCatalogIdentitiesBeforeFreshFallbacks() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let existingFlye = Exercise(
            name: "Incline Press-Flye",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .dumbbell
        )
        let existingGripper = Exercise(
            name: "Captain of Crush",
            primaryMuscle: .forearms,
            type: .isolation,
            equipment: .machine
        )
        let existingDumbbellWristCurl = Exercise(
            name: "Bench-Supported Wrist Curl",
            primaryMuscle: .forearms,
            type: .isolation,
            equipment: .dumbbell
        )
        context.insert(existingFlye)
        context.insert(existingGripper)
        context.insert(existingDumbbellWristCurl)
        try context.save()
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: catalog)

        XCTAssertEqual(
            template.days.first { $0.position == 2 }?.slots.first?.exerciseId,
            existingFlye.id
        )
        XCTAssertEqual(
            template.days.first { $0.position == 14 }?.slots.last?.exerciseId,
            existingGripper.id
        )
        XCTAssertNotEqual(
            template.days.first { $0.position == 10 }?.slots.last?.exerciseId,
            existingDumbbellWristCurl.id
        )
        XCTAssertFalse(catalog.contains { $0.name == "Incline Dumbbell Press-Flye" })
        XCTAssertFalse(catalog.contains { $0.name == "Captains of Crush" })
    }

    func testResolvingDraftSelectionsDoesNotAdvanceAnyPointer() throws {
        let (_, template, cycle, states) = try program()
        _ = try FixedCycleClusterProgramService.selections(
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        _ = try FixedCycleClusterProgramService.selections(
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        XCTAssertEqual(states.map(\.positionIndex), [0, 0, 0])
        XCTAssertFalse(FixedCycleWorkoutService.canIntentionallyComplete(
            sessionId: UUID(),
            entries: [],
            isClusteredProgram: true,
            hasCompletedCluster: false
        ))
        XCTAssertTrue(FixedCycleWorkoutService.canIntentionallyComplete(
            sessionId: UUID(),
            entries: [],
            isClusteredProgram: true,
            hasCompletedCluster: true
        ))
    }

    func testProgressionKeysShareOnlyTheSpecifiedModuloIdentity() {
        func key(
            _ cluster: FixedCycleClusterProgramService.Cluster,
            _ step: Int,
            _ slot: Int
        ) -> String {
            FixedCycleClusterProgramService.progressionKey(
                cluster: cluster,
                effectiveStep: step,
                slotPosition: slot
            )
        }
        XCTAssertEqual(
            key(.cluster1, 0, 0),
            key(.cluster1, 3, 0)
        )
        XCTAssertEqual(
            key(.cluster2, 0, 1),
            key(.cluster2, 3, 1)
        )
        XCTAssertNotEqual(
            key(.cluster2, 0, 0),
            key(.cluster2, 2, 0)
        )
        XCTAssertEqual(
            key(.cluster3, 0, 0),
            key(.cluster3, 2, 0)
        )
        XCTAssertNotEqual(
            key(.cluster3, 0, 1),
            key(.cluster3, 2, 1)
        )
        XCTAssertTrue(key(.cluster2, 0, 0).contains(".v1."))
        let cycleID = UUID()
        XCTAssertNotEqual(
            FixedCycleClusterPointer.key(
                cycleInstanceId: cycleID,
                programVersionID: "program.v1",
                clusterID: "cluster-1"
            ),
            FixedCycleClusterPointer.key(
                cycleInstanceId: cycleID,
                programVersionID: "program.v2",
                clusterID: "cluster-1"
            )
        )
    }

    func testOccurrenceFreezesExactVOLTRAProfileAndProgressionIdentity() throws {
        let (exercises, template, cycle, states) = try program()
        let selection = try FixedCycleClusterProgramService.selection(
            cluster: .cluster3,
            template: template,
            cycleInstanceId: cycle.id,
            states: states.map {
                $0.clusterID == FixedCycleClusterProgramService.Cluster.cluster3.rawValue
                    ? FixedCycleClusterPointer(
                        cycleInstanceId: cycle.id,
                        templateId: template.id,
                        programVersionID: $0.programVersionID,
                        clusterID: $0.clusterID,
                        completedCount: 3
                    )
                    : $0
            }
        )
        let wrist = try XCTUnwrap(selection.day.slots.last)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let profileValue = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        let profile = ExerciseResistanceProfile(
            workoutKind: .fixed,
            sessionId: session.id,
            exerciseId: wrist.exerciseId,
            resistanceSource: profileValue.resistanceSource,
            chainType: profileValue.chainType,
            chainPercent: profileValue.chainPercent,
            eccentricPercent: profileValue.eccentricPercent
        )
        let entry = SetEntry(
            sessionId: session.id,
            exerciseId: wrist.exerciseId,
            setIndex: 1,
            weight: 20,
            reps: 12,
            isLocked: true
        )

        let occurrence = try FixedCycleClusterProgramService.makeOccurrence(
            session: session,
            selection: selection,
            exercises: exercises,
            entries: [entry],
            resistanceProfiles: [profile]
        )
        let snapshot = try XCTUnwrap(occurrence.exerciseSnapshots.last)
        XCTAssertEqual(snapshot.resistanceProfile, profileValue)
        XCTAssertEqual(snapshot.completionStatus, .performed)
        XCTAssertEqual(
            snapshot.progressionKey,
            FixedCycleClusterProgramService.progressionKey(
                cluster: .cluster3,
                effectiveStep: 3,
                slotPosition: wrist.position
            )
        )

        let skippedOccurrence = try FixedCycleClusterProgramService.makeOccurrence(
            session: Session(cycleInstanceId: cycle.id, cycleDayIndex: 0),
            selection: selection,
            exercises: exercises,
            entries: [],
            resistanceProfiles: []
        )
        XCTAssertNil(skippedOccurrence.exerciseSnapshots.last?.resistanceProfile)
    }

    func testPrefillPrioritizesExactKeyAndProfileThenSameKeyAnyProfileThenGlobal() throws {
        let exerciseID = UUID()
        let cycleID = UUID()
        let templateID = UUID()
        let key = "program.v1.cluster-2.biceps.a"
        let exactProfile = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 70,
            eccentricPercent: 30
        )
        let otherProfile = ResistanceProfileValue.voltra(
            chainType: .inverseChains,
            chainPercent: 25,
            eccentricPercent: 25
        )
        func completed(_ time: TimeInterval) -> Session {
            Session(
                cycleInstanceId: cycleID,
                cycleDayIndex: 0,
                finishedAt: Date(timeIntervalSince1970: time),
                status: .completed
            )
        }
        let exact = completed(100)
        let sameKeyOtherProfile = completed(200)
        let global = completed(300)
        let otherKey = completed(400)
        func row(_ session: Session, _ weight: Double) -> SetEntry {
            SetEntry(
                sessionId: session.id,
                exerciseId: exerciseID,
                setIndex: 1,
                weight: weight,
                reps: 10,
                isLocked: true
            )
        }
        func occurrence(_ session: Session, _ profile: ResistanceProfileValue) throws -> FixedCycleProgressionOccurrence {
            try FixedCycleProgressionOccurrence(
                sessionId: session.id,
                cycleInstanceId: cycleID,
                templateId: templateID,
                programVersionID: "program.v1",
                clusterID: "cluster-2",
                positionIndex: 0,
                templateDayPosition: 3,
                dayLabel: "Cluster 2 · A",
                exerciseSnapshots: [
                    FixedCycleProgressionSnapshot(
                        position: 2,
                        exerciseId: exerciseID,
                        exerciseName: "Curl",
                        muscle: .biceps,
                        prescribedSetCount: 3,
                        progressionKey: key,
                        resistanceProfile: profile,
                        completionStatus: .performed
                    )
                ]
            )
        }
        let otherKeyOccurrence = try FixedCycleProgressionOccurrence(
            sessionId: otherKey.id,
            cycleInstanceId: cycleID,
            templateId: templateID,
            programVersionID: "program.v1",
            clusterID: "cluster-2",
            positionIndex: 1,
            templateDayPosition: 4,
            dayLabel: "Cluster 2 · B",
            exerciseSnapshots: [
                FixedCycleProgressionSnapshot(
                    position: 2,
                    exerciseId: exerciseID,
                    exerciseName: "Curl",
                    muscle: .biceps,
                    prescribedSetCount: 3,
                    progressionKey: "program.v1.cluster-2.biceps.b",
                    resistanceProfile: exactProfile,
                    completionStatus: .performed
                )
            ]
        )
        let occurrences = try [
            occurrence(exact, exactProfile),
            occurrence(sameKeyOtherProfile, otherProfile),
            otherKeyOccurrence
        ]
        let sessions = [exact, sameKeyOtherProfile, global, otherKey]
        let entries = [
            row(exact, 70), row(sameKeyOtherProfile, 25), row(global, 99), row(otherKey, 400)
        ]

        let exactResult = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseID,
            cycleInstanceId: cycleID,
            cycleDayIndex: 0,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: sessions,
            rotationSetEntries: entries,
            progressionKey: key,
            progressionOccurrences: occurrences,
            resistanceRequirement: .cable(exactProfile)
        )
        XCTAssertEqual(exactResult?.sessionId, exact.id)
        XCTAssertEqual(exactResult?.rows.first?.weight, 70)

        let sameKeyFallback = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseID,
            cycleInstanceId: cycleID,
            cycleDayIndex: 0,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: sessions,
            rotationSetEntries: entries,
            progressionKey: key,
            progressionOccurrences: occurrences,
            resistanceRequirement: .cable(.weightStack)
        )
        XCTAssertEqual(sameKeyFallback?.sessionId, sameKeyOtherProfile.id)
        XCTAssertTrue(sameKeyFallback?.isProgressionPrefillEligible == true)

        let globalFallback = ExerciseEffortLookupService.fixedCycleEffort(
            exerciseId: exerciseID,
            cycleInstanceId: cycleID,
            cycleDayIndex: 0,
            adaptiveSessions: [],
            adaptiveSetEntries: [],
            rotationSessions: sessions,
            rotationSetEntries: entries,
            progressionKey: "fresh-versioned-key",
            progressionOccurrences: occurrences
        )
        XCTAssertEqual(globalFallback?.sessionId, global.id)
        XCTAssertEqual(globalFallback?.matchKind, .globalLatest)
    }

    func testClusterMetadataRoundTripsOccurrenceAndExplicitPointers() throws {
        let schema = Schema(versionedSchema: OpenLiftSchemaV13.self)
        let sourceContainer = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        let sourceContext = ModelContext(sourceContainer)
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: sourceContext)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: catalog)
        let cycle = ActiveCycleInstance(templateId: template.id)
        let states = FixedCycleClusterProgramService.makeRotationStates(
            cycleInstanceId: cycle.id,
            templateId: template.id
        )
        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: template.name,
            dayLabelSnapshot: "Cluster 1",
            finishedAt: Date(timeIntervalSince1970: 500),
            status: .completed
        )
        let selection = try FixedCycleClusterProgramService.selection(
            cluster: .cluster1,
            template: template,
            cycleInstanceId: cycle.id,
            states: states
        )
        let first = try XCTUnwrap(selection.day.slots.first)
        let entry = SetEntry(
            sessionId: session.id,
            exerciseId: first.exerciseId,
            setIndex: 1,
            weight: 60,
            reps: 10,
            isLocked: true
        )
        let occurrence = try FixedCycleClusterProgramService.makeOccurrence(
            session: session,
            selection: selection,
            exercises: catalog,
            entries: [entry],
            resistanceProfiles: []
        )
        _ = try FixedCycleClusterProgramService.advanceCompletedCluster(
            selection: selection,
            occurrence: occurrence,
            states: states
        )
        let metadata = SessionExportService.fixedCycleMetadata(
            session: session,
            template: template,
            day: selection.day,
            exercises: catalog,
            setEntries: [entry],
            readiness: [],
            overrides: [],
            clusterOccurrences: [occurrence],
            clusterRotationStates: states
        )
        XCTAssertEqual(metadata.schema_version, 4)
        XCTAssertEqual(metadata.ordered_exercises.map(\.exercise_id), [first.exerciseId.uuidString])
        XCTAssertEqual(metadata.cluster_occurrences?.first?.exercises.count, 1)
        XCTAssertEqual(metadata.cluster_occurrences?.first?.exercises.first?.progression_key,
                       occurrence.exerciseSnapshots.first?.progressionKey)

        let destinationContainer = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
        let destinationContext = ModelContext(destinationContainer)
        let destinationCatalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: destinationContext)
        let destinationTemplate = try FixedCycleClusterProgramService.makeTemplate(exercises: destinationCatalog)
        destinationTemplate.id = template.id
        let destinationCycle = ActiveCycleInstance(id: cycle.id, templateId: destinationTemplate.id)
        destinationContext.insert(destinationTemplate)
        destinationContext.insert(destinationCycle)
        try destinationContext.save()
        let exercise = try XCTUnwrap(catalog.first { $0.id == first.exerciseId })
        let payload = SessionExportService.ExportPayload(
            session_id: session.id.uuidString,
            cycle_name: template.name,
            cycle_day_index: 0,
            date: ISO8601DateFormatter().string(from: session.finishedAt!),
            exercises: [
                .init(
                    exercise_id: exercise.id.uuidString,
                    exercise_name: exercise.name,
                    muscle: exercise.primaryMuscle.rawValue,
                    sets: [.init(set_index: 1, weight: 60, reps: 10)]
                )
            ],
            workout_kind: "rotation",
            fixed_cycle: metadata
        )
        _ = try BootstrapDataService.reconcileWorkoutExports(
            [payload],
            cycle: destinationCycle,
            modelContext: destinationContext
        )

        let hydrated = try destinationContext.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>())
        let hydratedStates = try destinationContext.fetch(FetchDescriptor<FixedCycleClusterPointer>())
        XCTAssertEqual(hydrated.count, 1)
        XCTAssertEqual(hydrated.first?.exerciseSnapshots.first?.progressionKey,
                       occurrence.exerciseSnapshots.first?.progressionKey)
        XCTAssertEqual(hydratedStates.first { $0.clusterID == "cluster-1" }?.positionIndex, 1)
        XCTAssertFalse(hydratedStates.first { $0.clusterID == "cluster-1" }?.isDerived ?? true)
    }

    func testClusteredRetryMetadataUsesFrozenOccurrenceAfterTemplateDeletion() throws {
        let templateID = UUID()
        let cycle = ActiveCycleInstance(templateId: templateID)
        let session = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 14,
            cycleNameSnapshot: "A Later Renamed Template",
            dayLabelSnapshot: "Cluster 2 · D",
            finishedAt: Date(timeIntervalSince1970: 800),
            status: .completed
        )
        let occurrence = try FixedCycleProgressionOccurrence(
            sessionId: session.id,
            cycleInstanceId: cycle.id,
            templateId: templateID,
            programVersionID: FixedCycleClusterProgramService.programVersionID,
            clusterID: FixedCycleClusterProgramService.Cluster.cluster2.rawValue,
            positionIndex: 3,
            templateDayPosition: 6,
            dayLabel: "Cluster 2 · D",
            exerciseSnapshots: [
                FixedCycleProgressionSnapshot(
                    position: 1,
                    exerciseId: UUID(),
                    exerciseName: "Frozen Arm A",
                    muscle: .triceps,
                    prescribedSetCount: 3,
                    progressionKey: "openlift.clustered-hypertrophy.v1.cluster-2.triceps.a",
                    resistanceProfile: .voltra(
                        chainType: .inverseChains,
                        chainPercent: 70,
                        eccentricPercent: 30
                    ),
                    completionStatus: .performed
                )
            ]
        )
        let currentState = FixedCycleClusterPointer(
            cycleInstanceId: cycle.id,
            templateId: templateID,
            programVersionID: FixedCycleClusterProgramService.programVersionID,
            clusterID: FixedCycleClusterProgramService.Cluster.cluster2.rawValue,
            positionIndex: 4
        )
        let futureState = FixedCycleClusterPointer(
            cycleInstanceId: cycle.id,
            templateId: templateID,
            programVersionID: "openlift.clustered-hypertrophy.v2",
            clusterID: FixedCycleClusterProgramService.Cluster.cluster2.rawValue,
            positionIndex: 99
        )

        let metadata = try XCTUnwrap(SessionExportService.resolvedFixedCycleMetadata(
            session: session,
            activeCycles: [cycle],
            templates: [],
            exercises: [],
            setEntries: [],
            readiness: [],
            overrides: [],
            snapshots: [],
            clusterOccurrences: [occurrence],
            clusterRotationStates: [futureState, currentState]
        ))

        XCTAssertEqual(metadata.schema_version, 4)
        XCTAssertEqual(metadata.template_id, templateID.uuidString)
        XCTAssertEqual(metadata.day_label, "Cluster 2 · D")
        XCTAssertEqual(metadata.ordered_exercises.map(\.exercise_name), ["Frozen Arm A"])
        XCTAssertEqual(metadata.cluster_occurrences?.first?.position_index, 3)
        XCTAssertEqual(metadata.cluster_rotation_states?.map(\.position_index), [4])
        XCTAssertEqual(metadata.program_identifier, FixedCycleClusterProgramService.programIdentifier)
        XCTAssertEqual(metadata.program_version, 1)
    }

    func testExplicitRolloutPreservesLegacyHistoryAndCreatesFreshPointers() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let legacyExercise = try XCTUnwrap(catalog.first)
        let legacyTemplate = CycleTemplate(
            name: "Legacy Program",
            days: [
                CycleDay(
                    label: "Legacy Day",
                    slots: [
                        CycleSlot(
                            position: 0,
                            muscle: legacyExercise.primaryMuscle,
                            exerciseId: legacyExercise.id,
                            defaultSetCount: 3
                        )
                    ],
                    position: 0
                )
            ]
        )
        let legacyCycle = ActiveCycleInstance(templateId: legacyTemplate.id)
        let legacySession = Session(
            cycleInstanceId: legacyCycle.id,
            cycleDayIndex: 0,
            finishedAt: Date(timeIntervalSince1970: 100),
            status: .completed
        )
        let legacyEntry = SetEntry(
            sessionId: legacySession.id,
            exerciseId: legacyExercise.id,
            setIndex: 1,
            weight: 50,
            reps: 10,
            isLocked: true
        )
        context.insert(legacyTemplate)
        context.insert(legacyCycle)
        context.insert(legacySession)
        context.insert(legacyEntry)
        try context.save()

        let result = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)

        XCTAssertTrue(result.didApply)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Session>()).first { $0.id == legacySession.id })
        XCTAssertNotNil(try context.fetch(FetchDescriptor<SetEntry>()).first { $0.id == legacyEntry.id })
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleClusterPointer>()).map(\.positionIndex),
            [0, 0, 0]
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>()).isEmpty)
    }

    func testExplicitRolloutAdoptsCompleteExportRecoveredPointersWithoutRewinding() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises)
        let cycle = ActiveCycleInstance(templateId: template.id)
        context.insert(template)
        context.insert(cycle)
        for (state, position) in zip(
            FixedCycleClusterProgramService.makeRotationStates(
                cycleInstanceId: cycle.id,
                templateId: template.id
            ),
            [2, 4, 5]
        ) {
            state.positionIndex = position
            context.insert(state)
        }
        try context.save()

        let result = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)

        XCTAssertTrue(result.didApply)
        XCTAssertEqual(result.cycleId, cycle.id)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleClusterPointer>())
                .sorted { $0.clusterID < $1.clusterID }
                .map(\.positionIndex),
            [2, 4, 5]
        )

        let retry = try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        XCTAssertFalse(retry.didApply)
        XCTAssertEqual(result.templateId, retry.templateId)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleClusterPointer>())
                .sorted { $0.clusterID < $1.clusterID }
                .map(\.positionIndex),
            [2, 4, 5]
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TrainingPreference>()).filter {
                $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey
            }.count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TrainingPreference>()).first {
                $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey
            }?.modeRawValue,
            "\(template.id.uuidString)|\(cycle.id.uuidString)"
        )
    }

    func testExplicitRolloutRejectsPartialRecoveredPointerState() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        context.insert(
            FixedCycleClusterPointer(
                cycleInstanceId: UUID(),
                templateId: UUID(),
                programVersionID: FixedCycleClusterProgramService.programVersionID,
                clusterID: FixedCycleClusterProgramService.Cluster.cluster1.rawValue,
                positionIndex: 3,
                isDerived: true
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.ClusteredProgramRolloutError,
                .existingRotationStateConflict
            )
        }
    }

    func testClusteredRolloutRejectsNonEmptyDraftWithoutMutation() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let template = CycleTemplate(name: "Legacy", days: [])
        let cycle = ActiveCycleInstance(templateId: template.id)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let entry = SetEntry(
            sessionId: session.id,
            exerciseId: UUID(),
            setIndex: 1,
            weight: 10,
            reps: 0,
            isLocked: false
        )
        context.insert(template)
        context.insert(cycle)
        context.insert(session)
        context.insert(entry)
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.ClusteredProgramRolloutError,
                .nonEmptyDraft(sessionId: session.id)
            )
        }
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Session>()).first { $0.id == session.id })
        XCTAssertNotNil(try context.fetch(FetchDescriptor<SetEntry>()).first { $0.id == entry.id })
        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleClusterPointer>()).isEmpty)
        XCTAssertFalse(try context.fetch(FetchDescriptor<TrainingPreference>()).contains {
            $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey
        })
    }

    func testClusteredRolloutRejectsDraftWithCompletedAllSkippedCluster() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let template = CycleTemplate(name: "Legacy", days: [])
        let cycle = ActiveCycleInstance(templateId: template.id)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let occurrence = try FixedCycleProgressionOccurrence(
            sessionId: session.id,
            cycleInstanceId: cycle.id,
            templateId: template.id,
            programVersionID: FixedCycleClusterProgramService.programVersionID,
            clusterID: FixedCycleClusterProgramService.Cluster.cluster1.rawValue,
            positionIndex: 0,
            templateDayPosition: 0,
            dayLabel: "Cluster 1 · A",
            exerciseSnapshots: [
                FixedCycleProgressionSnapshot(
                    position: 0,
                    exerciseId: UUID(),
                    exerciseName: "Skipped",
                    muscle: .chest,
                    prescribedSetCount: 3,
                    progressionKey: "openlift.clustered-hypertrophy.v1.cluster-1.chest.a",
                    resistanceProfile: nil,
                    completionStatus: .skipped
                )
            ]
        )
        context.insert(template)
        context.insert(cycle)
        context.insert(session)
        context.insert(occurrence)
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.ClusteredProgramRolloutError,
                .nonEmptyDraft(sessionId: session.id)
            )
        }
        XCTAssertNotNil(
            try context.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>()).first {
                $0.id == occurrence.id
            }
        )
        XCTAssertFalse(try context.fetch(FetchDescriptor<TrainingPreference>()).contains {
            $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey
        })
    }

    func testClusteredRolloutRejectsConflictingNamedTemplate() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let conflicting = CycleTemplate(
            name: FixedCycleClusterProgramService.templateName,
            days: [CycleDay(label: "Not the locked program", slots: [], position: 0)]
        )
        context.insert(conflicting)
        try context.save()

        XCTAssertThrowsError(
            try BootstrapDataService.prepareClusteredProgramRollout(modelContext: context)
        ) { error in
            XCTAssertEqual(
                error as? BootstrapDataService.ClusteredProgramRolloutError,
                .existingTemplateConflict
            )
        }
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CycleTemplate>())
                .first { $0.id == conflicting.id }?.days.first?.label,
            "Not the locked program"
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleClusterPointer>()).isEmpty)
        XCTAssertFalse(try context.fetch(FetchDescriptor<TrainingPreference>()).contains {
            $0.key == BootstrapDataService.clusteredProgramRolloutMarkerKey
        })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Exercise>()).isEmpty)
    }

    func testVersionedIdentityRejectsSameNameAndStructuralMutation() throws {
        let (_, template, _, _) = try program()
        XCTAssertTrue(FixedCycleClusterProgramService.isProgramTemplate(template))

        let sameName = CycleTemplate(
            name: FixedCycleClusterProgramService.templateName,
            days: template.days
        )
        XCTAssertFalse(FixedCycleClusterProgramService.isProgramTemplate(sameName))

        template.days[0].slots[0].muscle = .biceps
        XCTAssertFalse(FixedCycleClusterProgramService.isProgramTemplate(template))
    }

    func testActivationCleanupReplacesCyclePointersButPreservesCompletedContexts() throws {
        let (exercises, template, cycle, pointers) = try program()
        let completed = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            finishedAt: .now,
            status: .completed
        )
        let draft = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let selection = try FixedCycleClusterProgramService.selection(
            cluster: .cluster1,
            template: template,
            cycleInstanceId: cycle.id,
            states: pointers
        )
        let completedContext = try FixedCycleClusterProgramService.makeSessionContext(
            session: completed,
            selection: selection,
            exercises: exercises
        )
        let draftContext = try FixedCycleClusterProgramService.makeSessionContext(
            session: draft,
            selection: selection,
            exercises: exercises
        )
        let orphanSession = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let orphanContext = try FixedCycleClusterProgramService.makeSessionContext(
            session: orphanSession,
            selection: selection,
            exercises: exercises
        )

        let cleanup = FixedCycleClusterProgramService.activationCleanupPlan(
            existingCycles: [cycle],
            pointers: pointers,
            contexts: [completedContext, draftContext, orphanContext],
            sessions: [completed, draft]
        )

        XCTAssertEqual(cleanup.pointerIDs, Set(pointers.map(\.id)))
        XCTAssertFalse(cleanup.contextIDs.contains(completedContext.id))
        XCTAssertTrue(cleanup.contextIDs.contains(draftContext.id))
        XCTAssertTrue(cleanup.contextIDs.contains(orphanContext.id))

        let replacementCycle = ActiveCycleInstance(templateId: template.id)
        let replacements = FixedCycleClusterProgramService.makeRotationStates(
            cycleInstanceId: replacementCycle.id,
            templateId: template.id
        )
        XCTAssertEqual(replacements.count, 3)
        XCTAssertTrue(replacements.allSatisfy {
            $0.cycleInstanceId == replacementCycle.id && $0.completedCount == 0
        })
    }

    func testV4HydrationNeverRewindsAnExistingCycleOwnedPointer() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: catalog)
        let cycle = ActiveCycleInstance(templateId: template.id)
        let pointers = FixedCycleClusterProgramService.makeRotationStates(
            cycleInstanceId: cycle.id,
            templateId: template.id
        )
        pointers.first { $0.clusterID == "cluster-1" }?.completedCount = 5
        context.insert(template)
        context.insert(cycle)
        pointers.forEach(context.insert)
        try context.save()

        let exercise = try XCTUnwrap(catalog.first { $0.primaryMuscle == .chest })
        _ = try BootstrapDataService.reconcileWorkoutExports(
            [clusteredExport(
                template: template,
                cycle: cycle,
                exercise: exercise,
                absoluteStep: 0,
                pointerCount: 1,
                date: Date(timeIntervalSince1970: 1_000)
            )],
            cycle: cycle,
            modelContext: context
        )

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FixedCycleClusterPointer>())
                .first { $0.clusterID == "cluster-1" }?.completedCount,
            5
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<FixedCycleSessionContext>()).count, 1)
    }

    func testV4HydrationRejectsOccurrenceGapsAndConflicts() throws {
        func fixture() throws -> (
            ModelContext, [Exercise], CycleTemplate, ActiveCycleInstance
        ) {
            let container = OpenLiftModelContainerFactory.makeInMemory(
                schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
            )
            let context = ModelContext(container)
            let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
            let template = try FixedCycleClusterProgramService.makeTemplate(exercises: catalog)
            let cycle = ActiveCycleInstance(templateId: template.id)
            context.insert(template)
            context.insert(cycle)
            try context.save()
            return (context, catalog, template, cycle)
        }

        do {
            let (context, catalog, template, cycle) = try fixture()
            let exercise = try XCTUnwrap(catalog.first { $0.primaryMuscle == .chest })
            XCTAssertThrowsError(try BootstrapDataService.reconcileWorkoutExports(
                [clusteredExport(
                    template: template,
                    cycle: cycle,
                    exercise: exercise,
                    absoluteStep: 1,
                    pointerCount: 2,
                    date: Date(timeIntervalSince1970: 1_100)
                )],
                cycle: cycle,
                modelContext: context
            )) { error in
                guard case .occurrenceGap = error as? BootstrapDataService.ClusteredProgramRecoveryError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        do {
            let (context, catalog, template, cycle) = try fixture()
            let exercise = try XCTUnwrap(catalog.first { $0.primaryMuscle == .chest })
            let exports = [
                clusteredExport(
                    template: template,
                    cycle: cycle,
                    exercise: exercise,
                    absoluteStep: 0,
                    pointerCount: 1,
                    date: Date(timeIntervalSince1970: 1_200)
                ),
                clusteredExport(
                    template: template,
                    cycle: cycle,
                    exercise: exercise,
                    absoluteStep: 0,
                    pointerCount: 1,
                    date: Date(timeIntervalSince1970: 1_201)
                )
            ]
            XCTAssertThrowsError(try BootstrapDataService.reconcileWorkoutExports(
                exports,
                cycle: cycle,
                modelContext: context
            )) { error in
                guard case .occurrenceConflict = error as? BootstrapDataService.ClusteredProgramRecoveryError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testLegacyV3ExportCannotInventClusterIdentityOrPointers() throws {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV13.self)
        )
        let context = ModelContext(container)
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: catalog)
        let cycle = ActiveCycleInstance(templateId: template.id)
        context.insert(template)
        context.insert(cycle)
        try context.save()
        let exercise = try XCTUnwrap(catalog.first { $0.primaryMuscle == .chest })
        let v4 = clusteredExport(
            template: template,
            cycle: cycle,
            exercise: exercise,
            absoluteStep: 0,
            pointerCount: 1,
            date: Date(timeIntervalSince1970: 1_300)
        )
        let source = try XCTUnwrap(v4.fixed_cycle)
        let legacyMetadata = SessionExportService.FixedCycleMetadata(
            schema_version: 3,
            template_id: source.template_id,
            cycle_instance_id: source.cycle_instance_id,
            day_label: source.day_label,
            ordered_exercises: source.ordered_exercises,
            readiness: [],
            skips: [],
            program_identifier: source.program_identifier,
            program_version: source.program_version,
            cluster_key: source.cluster_key,
            absolute_cluster_step: source.absolute_cluster_step,
            cluster_occurrences: source.cluster_occurrences,
            cluster_rotation_states: source.cluster_rotation_states
        )
        let legacy = SessionExportService.ExportPayload(
            session_id: v4.session_id,
            cycle_name: v4.cycle_name,
            cycle_day_index: v4.cycle_day_index,
            date: v4.date,
            exercises: [],
            workout_kind: v4.workout_kind,
            fixed_cycle: legacyMetadata
        )

        _ = try BootstrapDataService.reconcileWorkoutExports(
            [legacy],
            cycle: cycle,
            modelContext: context
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleClusterPointer>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleSessionContext>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FixedCycleProgressionOccurrence>()).isEmpty)
    }
}
