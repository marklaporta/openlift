import XCTest
@testable import OpenLift

final class AdaptivePlanningServicesTests: XCTestCase {
    func testBackMovementPatternsDistinguishVerticalPullsFromRows() {
        for name in ["Lat Pulldown", "Assisted Pull-Up", "Chin Up"] {
            XCTAssertEqual(
                BackMovementPatternService.pattern(for: exercise(name, muscle: .back)),
                .verticalPull
            )
        }
        for name in ["Cable Row", "Chest Supported Row", "Single-Arm Dumbbell Row"] {
            XCTAssertEqual(
                BackMovementPatternService.pattern(for: exercise(name, muscle: .back)),
                .horizontalPull
            )
        }
        XCTAssertNil(
            BackMovementPatternService.pattern(
                for: exercise("Dumbbell Pullover", muscle: .back)
            )
        )
    }

    func testPlannerAllowsComplementaryBackCompoundsButRejectsRedundantBackCompounds() {
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let cableRow = exercise("Cable Row", muscle: .back)
        let chestSupportedRow = exercise("Chest Supported Row", muscle: .back)
        let complementary = makeComplex(
            id: uuid(910),
            position: 0,
            primary: .back,
            components: [
                component(pulldown, position: 0, sets: 2),
                component(cableRow, position: 1, sets: 2)
            ]
        )
        let redundant = makeComplex(
            id: uuid(911),
            position: 0,
            primary: .back,
            components: [
                component(cableRow, position: 0, sets: 2),
                component(chestSupportedRow, position: 1, sets: 2)
            ]
        )

        let allowed = unwrapProposal(AdaptivePlanService.generate(
            program: makeProgram(
                movements: 4,
                difficulty: 60,
                enabled: [.back],
                exerciseCaps: [.back: 1],
                complexes: [complementary]
            ),
            exercises: [pulldown, cableRow, chestSupportedRow],
            readiness: readyInputs,
            ledger: recentLedger([.back]),
            targetComplexCount: 1,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(
            allowed.complexes.first?.components.map(\.exerciseName),
            ["Lat Pulldown", "Cable Row"]
        )
        XCTAssertEqual(allowed.muscleSetDose[.back], 6)

        let rejected = unwrapProposal(AdaptivePlanService.generate(
            program: makeProgram(
                movements: 4,
                difficulty: 60,
                enabled: [.back],
                complexes: [redundant]
            ),
            exercises: [pulldown, cableRow, chestSupportedRow],
            readiness: readyInputs,
            ledger: recentLedger([.back]),
            targetComplexCount: 1,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertTrue(rejected.complexes.isEmpty)
        XCTAssertTrue(rejected.rejections.contains {
            $0.complexDefinitionId == uuid(911)
                && $0.code == "required_exercise_split_unavailable"
        })
    }

    func testBackExerciseSelectionContinuityIsPatternSpecific() {
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let assistedPullUp = exercise("Assisted Pull-Up", muscle: .back)
        let cableRow = exercise("Cable Row", muscle: .back)
        let chestSupportedRow = exercise("Chest Supported Row", muscle: .back)
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            createdAt: now,
            finishedAt: now,
            status: .completed
        )
        let entries = [
            SetEntry(
                sessionId: session.id,
                exerciseId: pulldown.id,
                setIndex: 1,
                weight: 100,
                reps: 10,
                isLocked: true
            ),
            SetEntry(
                sessionId: session.id,
                exerciseId: cableRow.id,
                setIndex: 1,
                weight: 100,
                reps: 10,
                isLocked: true
            )
        ]
        let preference = AdaptiveExerciseSelectionPreference(
            muscle: .back,
            mode: .repeatLast,
            eligibleExerciseIds: [
                pulldown.id,
                assistedPullUp.id,
                cableRow.id,
                chestSupportedRow.id
            ]
        )

        let recommendations = AdaptiveExerciseSelectionService.recommendations(
            exercises: [pulldown, assistedPullUp, cableRow, chestSupportedRow],
            preferences: [preference],
            rotationSessions: [session],
            rotationSetEntries: entries,
            adaptiveSessions: [],
            adaptiveSetEntries: []
        )

        XCTAssertEqual(
            recommendations[
                .init(muscle: .back, type: .compound, backPattern: .verticalPull)
            ]?.exercise.id,
            pulldown.id
        )
        XCTAssertEqual(
            recommendations[
                .init(muscle: .back, type: .compound, backPattern: .horizontalPull)
            ]?.exercise.id,
            cableRow.id
        )

        let proposal = unwrapProposal(AdaptivePlanService.generate(
            program: makeProgram(
                movements: 4,
                difficulty: 60,
                enabled: [.back],
                complexes: [
                    makeComplex(
                        id: uuid(912),
                        position: 0,
                        primary: .back,
                        components: [component(pulldown, sets: 2)]
                    )
                ]
            ),
            exercises: [pulldown, assistedPullUp, cableRow, chestSupportedRow],
            readiness: readyInputs,
            ledger: recentLedger([.back]),
            targetComplexCount: 1,
            exerciseSelections: recommendations,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(
            proposal.complexes.first?.components.map(\.exerciseName),
            ["Lat Pulldown", "Cable Row"]
        )
        XCTAssertTrue(
            proposal.complexes.first?.reasonCodes.contains(
                "back_horizontalPull_coverage"
            ) == true
        )
    }

    func testKnownLowerBodyRolesDistinguishHeavyFoundationsFromLightAccessories() {
        for name in ["Belt Squat", "Safety Squat Bar Squat", "Leg Press", "Hack Squat"] {
            XCTAssertEqual(
                AdaptiveExerciseRoleService.difficulty(for: exercise(name, muscle: .quads)),
                .hard
            )
        }
        XCTAssertEqual(
            AdaptiveExerciseRoleService.difficulty(
                for: exercise("Leg Extension", muscle: .quads, type: .isolation)
            ),
            .easy
        )
        for name in ["Stiff-Leg Deadlift", "GHD", "Glute-Ham Raise"] {
            XCTAssertEqual(
                AdaptiveExerciseRoleService.difficulty(for: exercise(name, muscle: .hamstrings)),
                .hard
            )
        }
        for name in ["Leg Curl", "Reverse Hyper"] {
            XCTAssertEqual(
                AdaptiveExerciseRoleService.difficulty(
                    for: exercise(name, muscle: .hamstrings, type: .isolation)
                ),
                .easy
            )
        }
    }

    func testPinnedHeavySelectionsStillHonorSoftQuadHamstringPreference() {
        let configuredQuad = exercise("Configured Quad", muscle: .quads)
        let configuredHamstring = exercise("Configured Hamstring", muscle: .hamstrings, type: .isolation)
        let configuredBack = exercise("Configured Row", muscle: .back)
        let verticalBack = exercise("Lat Pulldown", muscle: .back)
        let beltSquat = exercise("Belt Squat", muscle: .quads)
        let stiffLegDeadlift = exercise("Stiff-Leg Deadlift", muscle: .hamstrings)
        let program = makeProgram(
            movements: 2,
            difficulty: 60,
            enabled: [.quads, .hamstrings, .back],
            complexes: [
                makeComplex(
                    id: uuid(800),
                    position: 0,
                    primary: .quads,
                    components: [component(configuredQuad)]
                ),
                makeComplex(
                    id: uuid(801),
                    position: 1,
                    primary: .hamstrings,
                    components: [component(configuredHamstring)]
                ),
                makeComplex(
                    id: uuid(802),
                    position: 2,
                    primary: .back,
                    components: [component(configuredBack)]
                )
            ]
        )

        let result = AdaptivePlanService.generate(
            program: program,
            exercises: [
                configuredQuad, configuredHamstring, configuredBack, verticalBack,
                beltSquat, stiffLegDeadlift
            ],
            readiness: [
                .quads: .init(soreness: .none, connectiveTissuePain: .none, eagerness: .neutral),
                .hamstrings: .init(soreness: .none, connectiveTissuePain: .none, eagerness: .neutral),
                .back: .init(soreness: .none, connectiveTissuePain: .none, eagerness: .neutral)
            ],
            ledger: recentLedger([.quads, .hamstrings]),
            targetComplexCount: 2,
            exerciseSelections: [
                .init(muscle: .quads, type: .compound): .init(
                    exercise: beltSquat,
                    reasonCodeSuffix: "exercise_pinned"
                ),
                .init(muscle: .hamstrings, type: .compound): .init(
                    exercise: stiffLegDeadlift,
                    reasonCodeSuffix: "exercise_pinned"
                )
            ],
            now: now,
            calendar: utcCalendar
        )

        let proposal = unwrapProposal(result)
        XCTAssertEqual(
            Set(proposal.complexes.flatMap(\.components).map(\.exerciseName)),
            ["Belt Squat", "Configured Row", "Lat Pulldown"]
        )
        XCTAssertTrue(proposal.rejections.contains { $0.complexDefinitionId == uuid(801) })
    }

    func testDisabledMusclesDoNotRequireReadiness() {
        let chest = exercise("Chest", muscle: .chest)
        let fly = exercise("Chest Fly", muscle: .chest, type: .isolation)
        let program = makeProgram(
            movements: 1,
            difficulty: 3,
            enabled: [.chest],
            complexes: [
                makeComplex(
                    id: uuid(1),
                    position: 0,
                    primary: .chest,
                    components: [component(chest, sets: 2)]
                )
            ]
        )
        let result = AdaptivePlanService.generate(
            program: program,
            exercises: [chest, fly],
            readiness: [
                .chest: MuscleReadinessInput(
                    soreness: .none,
                    connectiveTissuePain: .none,
                    eagerness: .neutral
                )
            ],
            ledger: recentLedger([.chest]),
            now: now,
            calendar: utcCalendar
        )

        XCTAssertEqual(unwrapProposal(result).complexes.map(\.primaryMuscle), [.chest])
    }

    func testTomorrowForecastUsesDirectExposureRecoveryGates() {
        let chest = exercise("Chest Press", muscle: .chest)
        let fly = exercise("Chest Fly", muscle: .chest, type: .isolation)
        let back = exercise("Cable Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let shoulders = exercise("Lateral Raise", muscle: .sideDelts, type: .isolation)
        let program = makeProgram(
            movements: 2,
            difficulty: 20,
            enabled: [.chest, .back, .sideDelts],
            complexes: [
                makeComplex(id: uuid(850), position: 0, primary: .chest, components: [component(chest)]),
                makeComplex(id: uuid(851), position: 1, primary: .back, components: [component(back)]),
                makeComplex(id: uuid(852), position: 2, primary: .sideDelts, components: [component(shoulders)])
            ]
        )
        let ledger = TrainingLoadLedger(byMuscle: [
            .chest: MuscleLoadSummary(
                lockedSetCount: 2,
                lastProductiveExposureAt: now,
                lastDirectProductiveExposureAt: now
            ),
            .sideDelts: MuscleLoadSummary(
                lockedSetCount: 2,
                lastProductiveExposureAt: now,
                lastDirectProductiveExposureAt: now
            )
        ])
        let tomorrow = utcCalendar.date(byAdding: .day, value: 1, to: now)!

        let prediction = AdaptiveForecastService.expectedProposal(
            program: program,
            exercises: [chest, fly, back, pulldown, shoulders],
            ledger: ledger,
            targetComplexCount: 2,
            asOf: tomorrow,
            calendar: utcCalendar
        )

        XCTAssertEqual(prediction?.complexes.map(\.primaryMuscle), [.chest, .back])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLedgerCountsOnlyCompletedLockedSetsAndIncludesAdHocAndSecondaryLoad() {
        let evidence = [
            evidence(muscles: [.chest], daysAgo: 1, completed: true, locked: true, kind: .adHoc),
            evidence(muscles: [.chest, .triceps], daysAgo: 2, completed: true, locked: true, kind: .adaptiveComparable),
            evidence(muscles: [.chest], daysAgo: 1, completed: false, locked: true, kind: .rotation),
            evidence(muscles: [.chest], daysAgo: 1, completed: true, locked: false, kind: .rotation),
            evidence(muscles: [.chest], daysAgo: 10, completed: true, locked: true, kind: .rotation)
        ]
        let ledger = TrainingLoadLedgerService.build(
            evidence: evidence,
            asOf: now,
            rollingWindowDays: [.chest: 7, .triceps: 7],
            calendar: utcCalendar
        )

        XCTAssertEqual(ledger[.chest].lockedSetCount, 2)
        XCTAssertEqual(ledger[.triceps].lockedSetCount, 1)
        XCTAssertEqual(ledger[.chest].lastProductiveExposureAt, now.addingTimeInterval(-86_400))
        XCTAssertEqual(ledger[.chest].lastDirectProductiveExposureAt, now.addingTimeInterval(-86_400))
        XCTAssertNil(ledger[.triceps].lastDirectProductiveExposureAt)
    }

    func testStoredAdHocHistoryIsLoadEvidenceButHasNoComparableContext() {
        let exercise = Exercise(
            name: "Belt Squat",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine
        )
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "Return Session",
            dayLabelSnapshot: "Off-Schedule",
            createdAt: now.addingTimeInterval(-60),
            finishedAt: now,
            status: .completed
        )
        let set = SetEntry(
            sessionId: session.id,
            exerciseId: exercise.id,
            setIndex: 1,
            weight: 185,
            reps: 9,
            isLocked: true
        )

        let evidence = TrainingLoadLedgerService.storedEvidence(
            sessions: [session],
            setEntries: [set],
            exercises: [exercise],
            adaptivePlans: [],
            occurrenceLinks: [],
            overrides: []
        )

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.kind, .adHoc)
        XCTAssertNil(evidence.first?.complexDefinitionId)
        XCTAssertNil(evidence.first?.componentPosition)
        XCTAssertEqual(evidence.first?.muscles, [.quads])
    }

    func testAtomicPressFlyComplexCountsAsOneExposureWithTwoExercises() {
        let press = exercise("Press", muscle: .chest)
        let fly = exercise("Fly", muscle: .chest, type: .isolation)
        let complex = makeComplex(
            id: uuid(1),
            position: 0,
            primary: .chest,
            components: [component(press, sets: 2, difficulty: .moderate), component(fly, position: 1, sets: 2)]
        )
        let program = makeProgram(
            movements: 2,
            difficulty: 3,
            enabled: [.chest],
            complexes: [complex]
        )

        let result = AdaptivePlanService.generate(
            program: program,
            exercises: [press, fly],
            readiness: readyInputs,
            ledger: recentLedger([.chest]),
            now: now,
            calendar: utcCalendar
        )

        let proposal = unwrapProposal(result)
        XCTAssertEqual(proposal.complexes.count, 1)
        XCTAssertEqual(proposal.complexes.first?.components.count, 2)
        XCTAssertEqual(proposal.totalMovements, 2)
        XCTAssertEqual(proposal.muscleSetDose[.chest], 4)
        let trace = AdaptivePlanService.trace(for: result)
        XCTAssertEqual(trace.plannerVersion, 10)
        XCTAssertEqual(trace.outcomeCode, "proposal")
        XCTAssertEqual(trace.selectedComplexDefinitionIds, [uuid(1)])
        XCTAssertNil(trace.conflictCode)
    }

    func testCompoundSelectionReplacesCoreSlotWithoutReplacingIsolationSlot() {
        let inclinePress = exercise("Incline Press", muscle: .chest)
        let flatPress = exercise("Flat Dumbbell Press", muscle: .chest)
        let fly = exercise("Chest Fly", muscle: .chest, type: .isolation)
        let program = makeProgram(
            movements: 2,
            difficulty: 60,
            enabled: [.chest],
            complexes: [
                makeComplex(
                    id: uuid(15),
                    position: 0,
                    primary: .chest,
                    components: [component(inclinePress), component(fly, position: 1)]
                )
            ]
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [inclinePress, flatPress, fly],
                readiness: readyInputs,
                ledger: recentLedger([.chest]),
                exerciseSelections: [
                    .init(muscle: .chest, type: .compound): .init(
                        exercise: flatPress,
                        reasonCodeSuffix: "exercise_rotation"
                    )
                ],
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.first?.components.map(\.exerciseName), [
            "Flat Dumbbell Press", "Chest Fly"
        ])
        XCTAssertEqual(proposal.complexes.first?.components.map(\.difficulty), [.hard, .easy])
    }

    func testAutomaticPlanUsesOnlyOneComplexPerMuscleExposure() {
        let inclinePress = exercise("Incline Press", muscle: .chest)
        let flatPress = exercise("Flat Dumbbell Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let program = makeProgram(
            movements: 2,
            difficulty: 60,
            enabled: [.chest],
            complexes: [
                makeComplex(id: uuid(16), position: 0, primary: .chest, components: [component(inclinePress)]),
                makeComplex(id: uuid(17), position: 1, primary: .chest, components: [component(flatPress)])
            ]
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [inclinePress, flatPress, fly],
                readiness: readyInputs,
                ledger: recentLedger([.chest]),
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.count, 1)
        XCTAssertTrue(proposal.rejections.contains {
            $0.complexDefinitionId == uuid(17) && $0.code == "muscle_already_selected"
        })
    }

    func testRecoveredLowerPriorityFloorWinsBeforeHigherPriorityFill() {
        let chest = exercise("Chest", muscle: .chest)
        let back = exercise("Cable Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let program = makeProgram(
            movements: 1,
            difficulty: 3,
            enabled: [.chest, .back],
            floors: [.back: 1],
            complexes: [
                makeComplex(id: uuid(1), position: 0, primary: .chest, components: [component(chest, sets: 2)]),
                makeComplex(id: uuid(2), position: 1, primary: .back, components: [component(back, sets: 2)])
            ]
        )
        var ledger = recentLedger([.chest])
        ledger.byMuscle[.back] = MuscleLoadSummary(lockedSetCount: 0, lastProductiveExposureAt: now.addingTimeInterval(-20 * 86_400))

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [chest, back, pulldown],
                readiness: readyInputs,
                ledger: ledger,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), [.back])
        XCTAssertEqual(proposal.complexes.first?.reasonCodes.last, "back_cadence_due")
    }

    func testBinaryTrainingWindowSchedulesOneQualifyingExposureWithoutCreatingASetQuota() {
        let back = exercise("Cable Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let program = makeProgram(
            movements: 1,
            difficulty: 3,
            enabled: [.back],
            floors: [.back: 1],
            complexes: [
                makeComplex(id: uuid(1), position: 0, primary: .back, components: [component(back, sets: 2)])
            ]
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [back, pulldown],
                readiness: readyInputs,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), [.back])
        XCTAssertEqual(proposal.muscleSetDose[.back], 6)
        XCTAssertEqual(proposal.complexes.first?.reasonCodes.last, "back_cadence_due")
    }

    func testColdStartAcrossAllEnabledMusclesBuildsPrioritySlateFromBinaryExposureRequirements() {
        let muscles = MuscleGroup.initialAdaptiveRankOrder
        let exercises = muscles.enumerated().map { index, muscle in
            exercise("Cold Start \(index)", muscle: muscle)
        }
        let floors = Dictionary(uniqueKeysWithValues: muscles.map { ($0, 1) })
        let complexes = zip(muscles.indices, zip(muscles, exercises)).map { index, pair in
            makeComplex(
                id: uuid(index + 1),
                position: index,
                primary: pair.0,
                components: [component(pair.1, sets: 2)]
            )
        }
        let program = makeProgram(
            movements: 4,
            difficulty: 60,
            enabled: muscles,
            floors: floors,
            complexes: complexes
        )

        var statuses = dueStatuses(muscles)
        for muscle in [MuscleGroup.chest, .back] {
            statuses[muscle]?.rule.exerciseSplitKind = .none
            statuses[muscle]?.rule.normalSetCount = 3
        }
        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: exercises,
                readiness: readyInputs,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                exposureStatuses: statuses,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.totalMovements, 4)
        XCTAssertEqual(
            proposal.complexes.map(\.primaryMuscle),
            [.chest, .back, .quads, .sideDelts]
        )
        XCTAssertEqual(
            proposal.complexes.flatMap(\.components).map(\.prescribedSetCount),
            [3, 3, 3, 3]
        )
        XCTAssertTrue(
            proposal.complexes.allSatisfy {
                $0.reasonCodes.first?.hasSuffix("_cadence_due") == true
            }
        )
    }

    func testFirstLateralDeltExposureWaitsTwoCalendarDays() {
        let shoulder = exercise("Shoulder", muscle: .sideDelts)
        let program = makeProgram(
            movements: 1,
            difficulty: 3,
            enabled: [.sideDelts],
            floors: [.sideDelts: 1],
            complexes: [
                makeComplex(
                    id: uuid(1),
                    position: 0,
                    primary: .sideDelts,
                    components: [component(shoulder, sets: 2)]
                )
            ]
        )
        let yesterday = now.addingTimeInterval(-86_400)
        let ledger = TrainingLoadLedger(
            byMuscle: [
                .sideDelts: MuscleLoadSummary(
                    lockedSetCount: 1,
                    lastProductiveExposureAt: yesterday,
                    lastDirectProductiveExposureAt: yesterday
                )
            ]
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [shoulder],
                readiness: readyInputs,
                ledger: ledger,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertTrue(proposal.complexes.isEmpty)
    }

    func testHamstringSetCapBeatsGlobalCapacity() {
        let curl = exercise("Leg Curl", muscle: .hamstrings)
        let program = makeProgram(
            movements: 6,
            difficulty: 10,
            enabled: [.hamstrings],
            floors: [.hamstrings: 1],
            setCaps: [.hamstrings: 2],
            complexes: [
                makeComplex(id: uuid(1), position: 0, primary: .hamstrings, components: [component(curl, sets: 3)])
            ]
        )

        let result = AdaptivePlanService.generate(
            program: program,
            exercises: [curl],
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            now: now,
            calendar: utcCalendar
        )
        guard case .infeasible(let conflict) = result else {
            return XCTFail("Expected a cap conflict")
        }
        XCTAssertEqual(conflict.muscle, .hamstrings)
        XCTAssertEqual(conflict.code, "sets_per_exercise_cap")
    }

    func testHardQuadAndHamstringMovementsAreNotPairedButOtherHardWorkIsAllowed() {
        let sldl = exercise("SLDL", muscle: .hamstrings)
        let hackSquat = exercise("Hack Squat", muscle: .quads)
        let row = exercise("Hard Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let program = makeProgram(
            movements: 3,
            difficulty: 1,
            enabled: [.hamstrings, .quads, .back],
            complexes: [
                makeComplex(id: uuid(1), name: "SLDL Complex", position: 0, primary: .hamstrings, components: [component(sldl, difficulty: .hard)]),
                makeComplex(id: uuid(2), name: "Hack Squat Complex", position: 1, primary: .quads, components: [component(hackSquat, difficulty: .hard)]),
                makeComplex(id: uuid(3), name: "Hard Row Complex", position: 2, primary: .back, components: [component(row, difficulty: .hard)])
            ]
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [sldl, hackSquat, row, pulldown],
                readiness: readyInputs,
                ledger: recentLedger([.hamstrings, .quads, .back]),
                targetComplexCount: 2,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(
            proposal.complexes.map(\.name),
            ["Hard Row Complex", "Hack Squat Complex"]
        )
        XCTAssertEqual(proposal.totalDifficultyCost, 9)
        XCTAssertTrue(proposal.rejections.contains { $0.complexDefinitionId == uuid(1) })

        let noConflict = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [sldl, hackSquat, row, pulldown],
                readiness: readyInputs,
                ledger: recentLedger([.hamstrings, .quads, .back]),
                targetComplexCount: 3,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(Set(noConflict.complexes.map(\.primaryMuscle)), [.hamstrings, .quads, .back])
    }

    func testFirstMorningAfterExposureIsHeldByRecoveryGateEvenWithNoSoreness() {
        let press = exercise("Press", muscle: .chest)
        let fly = exercise("Fly", muscle: .chest, type: .isolation)
        let program = makeProgram(
            movements: 4,
            difficulty: 1,
            enabled: [.chest],
            complexes: [
                makeComplex(id: uuid(80), position: 0, primary: .chest, components: [component(press)])
            ]
        )
        let firstMorningLedger = TrainingLoadLedger(byMuscle: [
            .chest: MuscleLoadSummary(
                lockedSetCount: 100,
                lastProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -1, to: now),
                lastDirectProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -1, to: now)
            )
        ])

        let firstMorning = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [press, fly],
                readiness: readyInputs,
                ledger: firstMorningLedger,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertTrue(firstMorning.complexes.isEmpty)
        XCTAssertEqual(firstMorning.rejections, [
            .init(complexDefinitionId: uuid(80), code: "lower_priority_complex")
        ])

        let secondMorningLedger = TrainingLoadLedger(byMuscle: [
            .chest: MuscleLoadSummary(
                lockedSetCount: 100,
                lastProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -2, to: now),
                lastDirectProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -2, to: now)
            )
        ])
        let secondMorning = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [press, fly],
                readiness: readyInputs,
                ledger: secondMorningLedger,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(secondMorning.complexes.map(\.name), ["Chest Complex"])
    }

    func testLateralDeltsHonorCadenceWhileSecondaryArmLoadingDoesNotResetClock() {
        let lateral = exercise("Lateral Raise", muscle: .sideDelts, type: .isolation)
        let triceps = exercise("Pushdown", muscle: .triceps, type: .isolation)
        let program = makeProgram(
            movements: 4,
            difficulty: 1,
            enabled: [.sideDelts, .triceps],
            complexes: [
                makeComplex(id: uuid(81), position: 0, primary: .sideDelts, components: [component(lateral)]),
                makeComplex(id: uuid(82), position: 1, primary: .triceps, components: [component(triceps)])
            ]
        )
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: now)
        let ledger = TrainingLoadLedger(byMuscle: [
            .sideDelts: MuscleLoadSummary(
                lockedSetCount: 100,
                lastProductiveExposureAt: yesterday,
                lastDirectProductiveExposureAt: yesterday
            ),
            .triceps: MuscleLoadSummary(
                lockedSetCount: 100,
                lastProductiveExposureAt: yesterday,
                lastDirectProductiveExposureAt: nil
            )
        ])

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [lateral, triceps],
                readiness: readyInputs,
                ledger: ledger,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(proposal.complexes.map(\.name), ["Triceps Complex"])
    }

    func testEasyHamstringCurlIsStillIneligibleWhenHamstringsAreUnrecovered() {
        let curl = exercise("Hamstring Curl", muscle: .hamstrings, type: .isolation)
        let program = makeProgram(
            movements: 4,
            difficulty: 10,
            enabled: [.hamstrings],
            complexes: [
                makeComplex(
                    id: uuid(41),
                    position: 0,
                    primary: .hamstrings,
                    components: [component(curl, sets: 2, difficulty: .easy)]
                )
            ]
        )
        var readiness = readyInputs
        readiness[.hamstrings] = MuscleReadinessInput(
            soreness: .high,
            connectiveTissuePain: .none,
            eagerness: .neutral
        )

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [curl],
                readiness: readiness,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertTrue(proposal.complexes.isEmpty)
        XCTAssertEqual(proposal.rejections.first?.code, "held_for_recovery")
    }

    func testPlannerIsStableAcrossCollectionOrdering() {
        let first = exercise("First", muscle: .chest)
        let second = exercise("Second", muscle: .chest)
        let fly = exercise("Fly", muscle: .chest, type: .isolation)
        let a = makeComplex(id: uuid(1), position: 0, primary: .chest, components: [component(first)])
        let b = makeComplex(id: uuid(2), position: 0, primary: .chest, components: [component(second)])
        let programA = makeProgram(movements: 1, difficulty: 3, enabled: [.chest], complexes: [b, a])
        let programB = makeProgram(movements: 1, difficulty: 3, enabled: [.chest], complexes: [a, b])

        let idsA = unwrapProposal(AdaptivePlanService.generate(
            program: programA,
            exercises: [second, first, fly],
            readiness: readyInputs,
            ledger: recentLedger([.chest]),
            now: now,
            calendar: utcCalendar
        )).complexes.map(\.definitionId)
        let idsB = unwrapProposal(AdaptivePlanService.generate(
            program: programB,
            exercises: [first, second, fly],
            readiness: readyInputs,
            ledger: recentLedger([.chest]),
            now: now,
            calendar: utcCalendar
        )).complexes.map(\.definitionId)

        XCTAssertEqual(idsA, [uuid(1)])
        XCTAssertEqual(idsA, idsB)
    }

    func testPlannerPropertyLoopNeverExceedsAutomaticExposureTarget() {
        let exercises = (1...8).map { exercise("Chest \($0)", muscle: .chest) }
        for seed in 1...80 {
            let movementCap = (seed % 5) + 1
            let difficultyCap = (seed % 7) + 2
            let complexes = exercises.enumerated().map { index, exercise in
                makeComplex(
                    id: uuid(index + 1),
                    position: (seed * (index + 3)) % 11,
                    primary: .chest,
                    components: [component(exercise, difficulty: MovementDifficulty.allCases[(seed + index) % 3])]
                )
            }
            let program = makeProgram(
                movements: movementCap,
                difficulty: difficultyCap,
                enabled: [.chest],
                exerciseCaps: [.chest: 10],
                complexes: complexes
            )
            let proposal = unwrapProposal(AdaptivePlanService.generate(
                program: program,
                exercises: Array(exercises.reversed()),
                readiness: readyInputs,
                ledger: recentLedger([.chest]),
                now: now,
                calendar: utcCalendar
            ))
            XCTAssertLessThanOrEqual(proposal.complexes.count, movementCap, "seed \(seed)")
            XCTAssertEqual(proposal.totalMovements, proposal.complexes.reduce(0) { $0 + $1.components.count })
            XCTAssertEqual(
                proposal.totalDifficultyCost,
                proposal.complexes.flatMap(\.components).reduce(0) { $0 + $1.difficulty.cost }
            )
        }
    }

    func testRepeatPerformanceRequiresSameAdaptiveOccurrenceContext() {
        let exerciseId = UUID()
        let definitionId = UUID()
        let previous = PerformanceOccurrence(
            exerciseId: exerciseId,
            complexDefinitionId: definitionId,
            componentPosition: 0,
            isCompleted: true,
            isSubstitution: false,
            sets: [ComparableSetRow(setIndex: 1, weight: 60, reps: 9, isLocked: true)]
        )
        var current = previous
        current.sets[0].reps = 10
        XCTAssertEqual(RepeatPerformanceService.compare(previous: previous, current: current).label, .moreRepsAtSameWeight)

        current.complexDefinitionId = nil
        XCTAssertEqual(RepeatPerformanceService.compare(previous: previous, current: current).label, .notComparable)
        current = previous
        current.isSubstitution = true
        XCTAssertEqual(RepeatPerformanceService.compare(previous: previous, current: current).label, .notComparable)
    }

    func testPerMuscleSelectionAlternatesApprovedChestButPinsQuadAndHamstringFoundations() {
        let incline = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let cambered = Exercise(
            name: "Cambered Bar Bench Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let unavailableMachine = Exercise(
            name: "Machine Chest Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .machine
        )
        let fly = Exercise(
            name: "Cable Fly",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let beltSquat = Exercise(
            name: "Belt Squat",
            primaryMuscle: .quads,
            type: .compound,
            equipment: .machine
        )
        let stiffLegDeadlift = Exercise(
            name: "Stiff-Leg Deadlift",
            primaryMuscle: .hamstrings,
            type: .compound,
            equipment: .barbell
        )

        func completedSession(_ date: Date) -> Session {
            Session(
                cycleInstanceId: UUID(),
                cycleDayIndex: 0,
                cycleNameSnapshot: "History",
                dayLabelSnapshot: "History",
                createdAt: date,
                finishedAt: date,
                status: .completed
            )
        }
        func row(session: Session, exercise: Exercise) -> SetEntry {
            SetEntry(
                sessionId: session.id,
                exerciseId: exercise.id,
                setIndex: 1,
                weight: 1,
                reps: 8,
                isLocked: true
            )
        }

        let older = completedSession(Date(timeIntervalSince1970: 100))
        let yesterday = completedSession(Date(timeIntervalSince1970: 200))
        let unavailableLatest = completedSession(Date(timeIntervalSince1970: 300))
        let isolationLatest = completedSession(Date(timeIntervalSince1970: 350))
        let preferences = [
            AdaptiveExerciseSelectionPreference(
                muscle: .chest,
                mode: .rotateRecent,
                eligibleExerciseIds: [incline.id, cambered.id, fly.id]
            ),
            AdaptiveExerciseSelectionPreference(
                muscle: .quads,
                mode: .pinned,
                pinnedExerciseId: beltSquat.id,
                eligibleExerciseIds: [beltSquat.id]
            ),
            AdaptiveExerciseSelectionPreference(
                muscle: .hamstrings,
                mode: .pinned,
                pinnedExerciseId: stiffLegDeadlift.id,
                eligibleExerciseIds: [stiffLegDeadlift.id]
            )
        ]
        let exercises = [incline, cambered, unavailableMachine, fly, beltSquat, stiffLegDeadlift]
        let first = AdaptiveExerciseSelectionService.recommendations(
            exercises: exercises,
            preferences: preferences,
            rotationSessions: [older, yesterday, unavailableLatest, isolationLatest],
            rotationSetEntries: [
                row(session: older, exercise: cambered),
                row(session: yesterday, exercise: incline),
                row(session: unavailableLatest, exercise: unavailableMachine),
                row(session: isolationLatest, exercise: fly)
            ],
            adaptiveSessions: [],
            adaptiveSetEntries: []
        )
        XCTAssertEqual(first[.init(muscle: .chest, type: .compound)]?.exercise.id, cambered.id)
        XCTAssertEqual(first[.init(muscle: .chest, type: .isolation)]?.exercise.id, fly.id)
        XCTAssertEqual(first[.init(muscle: .quads, type: .compound)]?.exercise.id, beltSquat.id)
        XCTAssertEqual(
            first[.init(muscle: .hamstrings, type: .compound)]?.exercise.id,
            stiffLegDeadlift.id
        )

        let today = completedSession(Date(timeIntervalSince1970: 400))
        let second = AdaptiveExerciseSelectionService.recommendations(
            exercises: exercises,
            preferences: preferences,
            rotationSessions: [older, yesterday, unavailableLatest, isolationLatest, today],
            rotationSetEntries: [
                row(session: older, exercise: cambered),
                row(session: yesterday, exercise: incline),
                row(session: unavailableLatest, exercise: unavailableMachine),
                row(session: isolationLatest, exercise: fly),
                row(session: today, exercise: cambered)
            ],
            adaptiveSessions: [],
            adaptiveSetEntries: []
        )
        XCTAssertEqual(second[.init(muscle: .chest, type: .compound)]?.exercise.id, incline.id)
    }

    func testAlternateRecentChoosesAvailableDifferentExerciseAfterOnlyOneExposure() {
        let incline = Exercise(
            name: "Incline Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let flat = Exercise(
            name: "Flat Dumbbell Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .dumbbell
        )
        let unavailable = Exercise(
            name: "Barbell Bench Press",
            primaryMuscle: .chest,
            type: .compound,
            equipment: .barbell
        )
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "History",
            dayLabelSnapshot: "History",
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 100),
            status: .completed
        )
        let row = SetEntry(
            sessionId: session.id,
            exerciseId: incline.id,
            setIndex: 1,
            weight: 60,
            reps: 9,
            isLocked: true
        )
        let preference = AdaptiveExerciseSelectionPreference(
            muscle: .chest,
            mode: .rotateRecent,
            eligibleExerciseIds: [incline.id, flat.id]
        )

        let result = AdaptiveExerciseSelectionService.recommendations(
            exercises: [incline, flat, unavailable],
            preferences: [preference],
            rotationSessions: [session],
            rotationSetEntries: [row],
            adaptiveSessions: [],
            adaptiveSetEntries: []
        )

        XCTAssertEqual(result[.init(muscle: .chest, type: .compound)]?.exercise.id, flat.id)
    }

    func testDoseChangesAreBoundedAndOneTooLittleTapDoesNotIncrease() {
        XCTAssertEqual(
            DoseRecommendationService.recommend(
                currentSetCount: 1,
                maximumSetCount: 3,
                recentFeedback: [.tooLittle],
                latestPerformance: .matched,
                recoveredOnTime: true
            ).prescribedSetCount,
            1
        )
        XCTAssertEqual(
            DoseRecommendationService.recommend(
                currentSetCount: 1,
                maximumSetCount: 3,
                recentFeedback: [.tooLittle, .tooLittle],
                latestPerformance: .moreRepsAtSameWeight,
                recoveredOnTime: true
            ).prescribedSetCount,
            2
        )
        XCTAssertEqual(
            DoseRecommendationService.recommend(
                currentSetCount: 1,
                maximumSetCount: 3,
                recentFeedback: [.tooLittle, .tooLittle],
                latestPerformance: .moreRepsAtSameWeight,
                recoveredOnTime: true,
                allowsPositiveProgression: false
            ).prescribedSetCount,
            1
        )
        XCTAssertEqual(
            DoseRecommendationService.recommend(
                currentSetCount: 3,
                minimumSetCount: 1,
                maximumSetCount: 5,
                recentFeedback: [.tooMuch],
                latestPerformance: .matched,
                recoveredOnTime: true
            ).prescribedSetCount,
            2
        )
        XCTAssertTrue(
            DoseRecommendationService.recommend(
                currentSetCount: 2,
                maximumSetCount: 4,
                recentFeedback: [.painProblem],
                latestPerformance: nil,
                recoveredOnTime: false
            ).isPainBlocked
        )
    }

    private var readyInputs: [MuscleGroup: MuscleReadinessInput] {
        Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
            ($0, MuscleReadinessInput(soreness: .none, connectiveTissuePain: .none, eagerness: .neutral))
        })
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func recentLedger(_ muscles: [MuscleGroup]) -> TrainingLoadLedger {
        TrainingLoadLedger(
            byMuscle: Dictionary(uniqueKeysWithValues: muscles.map {
                ($0, MuscleLoadSummary(
                    lockedSetCount: 100,
                    lastProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -3, to: now),
                    lastDirectProductiveExposureAt: utcCalendar.date(byAdding: .day, value: -3, to: now)
                ))
            })
        )
    }

    private func evidence(
        muscles: [MuscleGroup],
        daysAgo: Int,
        completed: Bool,
        locked: Bool,
        kind: TrainingEvidenceKind
    ) -> TrainingLoadEvidence {
        TrainingLoadEvidence(
            sessionId: UUID(),
            setEntryId: UUID(),
            exerciseId: UUID(),
            completedAt: now.addingTimeInterval(Double(-daysAgo * 86_400)),
            muscles: muscles,
            weight: 100,
            reps: 10,
            isSessionCompleted: completed,
            isLocked: locked,
            kind: kind,
            complexDefinitionId: nil,
            componentPosition: nil
        )
    }

    private func exercise(
        _ name: String,
        muscle: MuscleGroup,
        type: ExerciseType = .compound
    ) -> Exercise {
        Exercise(name: name, primaryMuscle: muscle, type: type, equipment: .machine)
    }

    private func component(
        _ exercise: Exercise,
        position: Int = 0,
        sets: Int = 1,
        secondary: MuscleGroup? = nil,
        difficulty: MovementDifficulty = .easy
    ) -> AdaptiveComplexComponent {
        AdaptiveComplexComponent(
            position: position,
            exerciseId: exercise.id,
            prescribedSetCount: sets,
            primaryMuscle: exercise.primaryMuscle,
            secondaryMuscle: secondary,
            difficulty: difficulty
        )
    }

    func testExposureTargetCountsComplexesAndIncreasingTakesNextPriorityMuscle() {
        let press = exercise("Press", muscle: .chest)
        let fly = Exercise(
            name: "Fly",
            primaryMuscle: .chest,
            type: .isolation,
            equipment: .cable
        )
        let row = exercise("Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let curl = exercise("Curl", muscle: .biceps)
        let program = makeProgram(
            movements: 1,
            difficulty: 1,
            enabled: [.chest, .back, .biceps],
            complexes: [
                makeComplex(
                    id: uuid(201),
                    position: 0,
                    primary: .chest,
                    components: [component(press), component(fly, position: 1)]
                ),
                makeComplex(id: uuid(202), position: 1, primary: .back, components: [component(row)]),
                makeComplex(id: uuid(203), position: 2, primary: .biceps, components: [component(curl)])
            ]
        )

        let one = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [press, fly, row, pulldown, curl],
            readiness: readyInputs,
            ledger: recentLedger([.chest, .back, .biceps]),
            targetComplexCount: 1,
            now: now,
            calendar: utcCalendar
        ))
        let two = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [press, fly, row, pulldown, curl],
            readiness: readyInputs,
            ledger: recentLedger([.chest, .back, .biceps]),
            targetComplexCount: 2,
            now: now,
            calendar: utcCalendar
        ))

        XCTAssertEqual(one.complexes.count, 1)
        XCTAssertEqual(one.complexes.first?.components.count, 2)
        XCTAssertEqual(two.complexes.map(\.primaryMuscle), [.chest, .back])
    }

    func testExposureDefaultsMatchApprovedDosesCadencesAndManualOnlyGroups() {
        let back = AdaptiveExposureControllerService.defaultRule(for: .back)
        XCTAssertEqual(back.normalSetCount, 6)
        XCTAssertEqual(back.minimumCalendarDays, 2)
        XCTAssertEqual(back.exerciseSplitKind, .backVerticalHorizontal)
        XCTAssertEqual([back.firstSplitSetCount, back.secondSplitSetCount], [3, 3])

        let chest = AdaptiveExposureControllerService.defaultRule(for: .chest)
        XCTAssertEqual(chest.normalSetCount, 4)
        XCTAssertEqual(chest.minimumCalendarDays, 2)
        XCTAssertEqual(chest.exerciseSplitKind, .chestCompoundIsolation)
        XCTAssertEqual([chest.firstSplitSetCount, chest.secondSplitSetCount], [2, 2])

        for muscle in [MuscleGroup.quads, .hamstrings] {
            let rule = AdaptiveExposureControllerService.defaultRule(for: muscle)
            XCTAssertEqual(rule.normalSetCount, 3)
            XCTAssertEqual(rule.minimumCalendarDays, 3)
        }
        for muscle in [MuscleGroup.triceps, .biceps] {
            let rule = AdaptiveExposureControllerService.defaultRule(for: muscle)
            XCTAssertEqual(rule.normalSetCount, 3)
            XCTAssertEqual(rule.minimumCalendarDays, 2)
        }
        let delts = AdaptiveExposureControllerService.defaultRule(for: .sideDelts)
        XCTAssertEqual(delts.normalSetCount, 3)
        XCTAssertEqual(delts.cadenceKind, .lateralDelts2221)
        XCTAssertEqual(delts.cadencePattern, [2, 2, 2, 1])

        XCTAssertEqual(
            AdaptiveExposureControllerService.automaticPriority,
            [.chest, .back, .quads, .hamstrings, .triceps, .biceps, .sideDelts]
        )
        for muscle in [MuscleGroup.forearms, .calves, .glutes, .abs, .traps] {
            XCTAssertFalse(
                AdaptiveExposureControllerService.defaultRule(for: muscle)
                    .isAutomaticPlanningEnabled
            )
        }
    }

    func testClockUsesCalendarBoundariesAndOnlyDirectHypertrophyEvidence() {
        let press = exercise("Chest Press", muscle: .chest)
        let tricepsExtension = exercise(
            "Triceps Extension",
            muscle: .triceps,
            type: .isolation
        )
        let reverseHyper = exercise("Reverse Hyper", muscle: .hamstrings)
        let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: now)!
        let directPress = TrainingLoadEvidence(
            sessionId: UUID(),
            setEntryId: UUID(),
            exerciseId: press.id,
            completedAt: yesterday,
            muscles: [.chest, .triceps],
            weight: 100,
            reps: 8,
            isSessionCompleted: true,
            isLocked: true,
            kind: .adaptiveComparable,
            complexDefinitionId: nil,
            componentPosition: nil
        )
        let loggedAccessory = TrainingLoadEvidence(
            sessionId: UUID(),
            setEntryId: UUID(),
            exerciseId: tricepsExtension.id,
            completedAt: yesterday,
            muscles: [.triceps],
            weight: 20,
            reps: 12,
            isSessionCompleted: true,
            isLocked: true,
            kind: .adHoc,
            complexDefinitionId: nil,
            componentPosition: nil
        )
        let recoveryWork = TrainingLoadEvidence(
            sessionId: UUID(),
            setEntryId: UUID(),
            exerciseId: reverseHyper.id,
            completedAt: yesterday,
            muscles: [.hamstrings],
            weight: 20,
            reps: 15,
            isSessionCompleted: true,
            isLocked: true,
            kind: .adaptiveOverride,
            complexDefinitionId: nil,
            componentPosition: nil
        )
        let rules = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
            ($0, AdaptiveExposureControllerService.defaultRule(for: $0))
        })
        let statuses = AdaptiveExposureControllerService.statuses(
            rules: rules,
            readiness: readyInputs,
            evidence: [directPress, loggedAccessory, recoveryWork],
            exercises: [press, tricepsExtension, reverseHyper],
            asOf: now,
            calendar: utcCalendar
        )

        XCTAssertFalse(statuses[.chest]?.isEligible == true)
        XCTAssertEqual(
            statuses[.triceps]?.lastDirectExposureAt,
            utcCalendar.startOfDay(for: yesterday)
        )
        XCTAssertFalse(statuses[.triceps]?.isEligible == true)
        XCTAssertNil(statuses[.hamstrings]?.lastDirectExposureAt)
        XCTAssertTrue(statuses[.hamstrings]?.isEligible == true)

        let tomorrow = utcCalendar.date(byAdding: .day, value: 1, to: now)!
        let tomorrowStatuses = AdaptiveExposureControllerService.statuses(
            rules: rules,
            readiness: readyInputs,
            evidence: [directPress],
            exercises: [press, tricepsExtension],
            asOf: tomorrow,
            calendar: utcCalendar
        )
        XCTAssertTrue(tomorrowStatuses[.chest]?.isEligible == true)
        XCTAssertEqual(tomorrowStatuses[.chest]?.daysOverdue, 0)
        XCTAssertNil(tomorrowStatuses[.triceps]?.lastDirectExposureAt)
    }

    func testLateralDeltCadenceDoesNotAdvanceWhenDueDateIsSkipped() {
        let raise = exercise("Cable Lateral Raise", muscle: .sideDelts, type: .isolation)
        let exposureOffsets = [-6, -4, -2, 0]
        var evidence = exposureOffsets.map { offset in
            TrainingLoadEvidence(
                sessionId: UUID(),
                setEntryId: UUID(),
                exerciseId: raise.id,
                completedAt: utcCalendar.date(byAdding: .day, value: offset, to: now)!,
                muscles: [.sideDelts],
                weight: 15,
                reps: 12,
                isSessionCompleted: true,
                isLocked: true,
                kind: .adaptiveComparable,
                complexDefinitionId: nil,
                componentPosition: nil
            )
        }
        let rules: [MuscleGroup: AdaptiveExposureRule] = [
            .sideDelts: AdaptiveExposureControllerService.defaultRule(for: .sideDelts)
        ]
        let threeDaysLater = utcCalendar.date(byAdding: .day, value: 3, to: now)!
        var status = AdaptiveExposureControllerService.statuses(
            rules: rules,
            readiness: readyInputs,
            evidence: evidence,
            exercises: [raise],
            asOf: threeDaysLater,
            calendar: utcCalendar
        )[.sideDelts]
        XCTAssertEqual(
            status?.nextEligibleAt,
            utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 1, to: now)!
            )
        )
        XCTAssertEqual(status?.daysOverdue, 2)

        evidence.append(
            TrainingLoadEvidence(
                sessionId: UUID(),
                setEntryId: UUID(),
                exerciseId: raise.id,
                completedAt: threeDaysLater,
                muscles: [.sideDelts],
                weight: 15,
                reps: 12,
                isSessionCompleted: true,
                isLocked: true,
                kind: .adaptiveComparable,
                complexDefinitionId: nil,
                componentPosition: nil
            )
        )
        status = AdaptiveExposureControllerService.statuses(
            rules: rules,
            readiness: readyInputs,
            evidence: evidence,
            exercises: [raise],
            asOf: threeDaysLater,
            calendar: utcCalendar
        )[.sideDelts]
        XCTAssertEqual(
            status?.nextEligibleAt,
            utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 5, to: now)!
            )
        )
    }

    func testEligibleRankingUsesOverdueThenFixedPriorityThenSorenessAndRecency() {
        var statuses = dueStatuses(
            [.chest, .back, .quads, .biceps],
            overdueDays: [.biceps: 3, .quads: 3, .chest: 1, .back: 1]
        )
        statuses[.quads]?.soreness = .mild
        statuses[.back]?.soreness = .mild
        XCTAssertEqual(
            AdaptiveExposureControllerService.rankedEligible(statuses).map(\.muscle),
            [.quads, .biceps, .chest, .back]
        )
    }

    func testFixedRecoveryGatesUseCalendarDaysAcrossDST() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let exposure = try XCTUnwrap(
            losAngeles.date(
                from: DateComponents(
                    year: 2026,
                    month: 10,
                    day: 31,
                    hour: 20
                )
            )
        )
        let press = exercise("Chest Press", muscle: .chest)
        let squat = exercise("Belt Squat", muscle: .quads)
        let evidence = [
            TrainingLoadEvidence(
                sessionId: UUID(),
                setEntryId: UUID(),
                exerciseId: press.id,
                completedAt: exposure,
                muscles: [.chest, .triceps],
                weight: 100,
                reps: 8,
                isSessionCompleted: true,
                isLocked: true,
                kind: .rotation,
                complexDefinitionId: nil,
                componentPosition: nil
            ),
            TrainingLoadEvidence(
                sessionId: UUID(),
                setEntryId: UUID(),
                exerciseId: squat.id,
                completedAt: exposure,
                muscles: [.quads],
                weight: 100,
                reps: 8,
                isSessionCompleted: true,
                isLocked: true,
                kind: .adaptiveComparable,
                complexDefinitionId: nil,
                componentPosition: nil
            )
        ]
        let rules = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map {
            ($0, AdaptiveExposureControllerService.defaultRule(for: $0))
        })
        func status(day: Int) throws -> [MuscleGroup: AdaptiveMuscleExposureStatus] {
            let date = try XCTUnwrap(
                losAngeles.date(
                    from: DateComponents(
                        year: 2026,
                        month: 11,
                        day: day,
                        hour: 12
                    )
                )
            )
            return AdaptiveExposureControllerService.statuses(
                rules: rules,
                readiness: readyInputs,
                evidence: evidence,
                exercises: [press, squat],
                asOf: date,
                calendar: losAngeles
            )
        }

        XCTAssertFalse(try status(day: 1)[.chest]?.isEligible == true)
        XCTAssertFalse(try status(day: 1)[.quads]?.isEligible == true)
        XCTAssertTrue(try status(day: 2)[.chest]?.isEligible == true)
        XCTAssertFalse(try status(day: 2)[.quads]?.isEligible == true)
        XCTAssertTrue(try status(day: 3)[.quads]?.isEligible == true)
    }

    func testPairBansApplyInEitherSelectionOrderAndPreferredPairsRemainAllowed() {
        let press = exercise("Chest Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let row = exercise("Cable Row", muscle: .back)
        let pushdown = exercise("Triceps Pushdown", muscle: .triceps, type: .isolation)
        let curl = exercise("Bayesian Curl", muscle: .biceps, type: .isolation)
        let exercises = [press, fly, pulldown, row, pushdown, curl]
        let program = makeProgram(
            movements: 4,
            difficulty: 60,
            enabled: [.chest, .back, .triceps, .biceps],
            complexes: [
                makeComplex(
                    id: uuid(960),
                    position: 0,
                    primary: .chest,
                    components: [component(press), component(fly, position: 1)]
                ),
                makeComplex(
                    id: uuid(961),
                    position: 1,
                    primary: .back,
                    components: [component(pulldown), component(row, position: 1)]
                ),
                makeComplex(
                    id: uuid(962),
                    position: 2,
                    primary: .triceps,
                    components: [component(pushdown)]
                ),
                makeComplex(
                    id: uuid(963),
                    position: 3,
                    primary: .biceps,
                    components: [component(curl)]
                )
            ]
        )
        func planned(
            _ statuses: [MuscleGroup: AdaptiveMuscleExposureStatus]
        ) -> [MuscleGroup] {
            unwrapProposal(
                AdaptivePlanService.generate(
                    program: program,
                    exercises: exercises,
                    readiness: readyInputs,
                    ledger: TrainingLoadLedger(byMuscle: [:]),
                    exposureStatuses: statuses,
                    targetComplexCount: 2,
                    capacity: .initial,
                    now: now,
                    calendar: utcCalendar
                )
            ).complexes.map(\.primaryMuscle)
        }

        XCTAssertEqual(planned(dueStatuses([.chest, .biceps])), [.chest, .biceps])
        XCTAssertEqual(planned(dueStatuses([.back, .triceps])), [.back, .triceps])
        XCTAssertEqual(planned(dueStatuses([.chest, .triceps])), [.chest])
        XCTAssertEqual(planned(dueStatuses([.back, .biceps])), [.back])
        XCTAssertEqual(
            planned(
                dueStatuses(
                    [.chest, .triceps],
                    overdueDays: [.triceps: 2, .chest: 1]
                )
            ),
            [.triceps]
        )
        XCTAssertEqual(
            planned(
                dueStatuses(
                    [.back, .biceps],
                    overdueDays: [.biceps: 2, .back: 1]
                )
            ),
            [.biceps]
        )
    }

    func testReverseHyperSelectionReplacementCannotEnterAutomaticPlan() {
        let sldl = exercise("Stiff-Leg Deadlift", muscle: .hamstrings)
        let reverseHyper = exercise(
            "Reverse Hyper",
            muscle: .hamstrings,
            type: .isolation
        )
        let program = makeProgram(
            movements: 1,
            difficulty: 20,
            enabled: [.hamstrings],
            complexes: [
                makeComplex(
                    id: uuid(970),
                    position: 0,
                    primary: .hamstrings,
                    components: [component(sldl)]
                )
            ]
        )
        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [sldl, reverseHyper],
                readiness: readyInputs,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                exposureStatuses: dueStatuses([.hamstrings]),
                exerciseSelections: [
                    AdaptiveExerciseSelectionKey(
                        muscle: .hamstrings,
                        type: .compound
                    ): AdaptiveExerciseSelectionRecommendation(
                        exercise: reverseHyper,
                        reasonCodeSuffix: "exercise_rotation"
                    )
                ],
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertTrue(proposal.complexes.isEmpty)
        XCTAssertTrue(
            proposal.rejections.contains {
                $0.complexDefinitionId == uuid(970)
                    && $0.code == "manual_recovery_exercise"
            }
        )
    }

    func testVolumeControllerCountsOnlyPrimarySetsAndCapsDebtAtOneWeek() {
        let program = makeProgram(
            movements: 1,
            difficulty: 10,
            enabled: [.chest, .triceps],
            complexes: []
        )
        let targetTime = now
        let targets = [MuscleGroup.chest, .triceps].map {
            AdaptiveMuscleVolumeTarget(
                adaptiveProgramId: program.id,
                lineageId: program.lineageId,
                muscle: $0,
                weeklySetTarget: 7,
                dailySetCap: 4,
                effectiveAt: targetTime
            )
        }
        let anchors = [MuscleGroup.chest, .triceps].map {
            AdaptiveMuscleVolumeAnchor(
                lineageId: program.lineageId,
                muscle: $0,
                activatedAt: targetTime,
                initialBalance: 0
            )
        }
        let evidence = TrainingLoadEvidence(
            sessionId: UUID(),
            setEntryId: UUID(),
            exerciseId: UUID(),
            completedAt: targetTime.addingTimeInterval(43_200),
            muscles: [.chest, .triceps],
            weight: 100,
            reps: 8,
            isSessionCompleted: true,
            isLocked: true,
            kind: .rotation,
            complexDefinitionId: nil,
            componentPosition: nil
        )

        let afterOneDay = AdaptiveVolumeControllerService.statuses(
            program: program,
            allTargets: targets,
            anchors: anchors,
            evidence: [evidence],
            asOf: targetTime.addingTimeInterval(86_400)
        )
        XCTAssertEqual(afterOneDay[.chest]?.balance ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(afterOneDay[.triceps]?.balance ?? .nan, -1, accuracy: 0.001)

        let afterTwentyDays = AdaptiveVolumeControllerService.statuses(
            program: program,
            allTargets: targets,
            anchors: anchors,
            evidence: [],
            asOf: targetTime.addingTimeInterval(20 * 86_400)
        )
        XCTAssertEqual(afterTwentyDays[.chest]?.balance ?? .nan, -7, accuracy: 0.001)
    }

    func testVolumeControllerAppliesTargetChangesProspectively() {
        let first = makeProgram(
            movements: 1,
            difficulty: 10,
            enabled: [.chest],
            complexes: []
        )
        let second = AdaptiveProgram(
            lineageId: first.lineageId,
            version: 2,
            name: "Edited",
            createdAt: now.addingTimeInterval(7 * 86_400),
            isActiveVersion: true,
            isReviewedForUse: true,
            globalMaxMovements: 1,
            maxDifficultyCost: 10,
            muscleRules: first.muscleRules,
            complexes: []
        )
        let targets = [
            AdaptiveMuscleVolumeTarget(
                adaptiveProgramId: first.id,
                lineageId: first.lineageId,
                muscle: .chest,
                weeklySetTarget: 7,
                dailySetCap: 4,
                effectiveAt: now
            ),
            AdaptiveMuscleVolumeTarget(
                adaptiveProgramId: second.id,
                lineageId: second.lineageId,
                muscle: .chest,
                weeklySetTarget: 14,
                dailySetCap: 6,
                effectiveAt: now.addingTimeInterval(7 * 86_400)
            )
        ]
        let status = AdaptiveVolumeControllerService.statuses(
            program: second,
            allTargets: targets,
            anchors: [
                AdaptiveMuscleVolumeAnchor(
                    lineageId: first.lineageId,
                    muscle: .chest,
                    activatedAt: now,
                    initialBalance: 0
                )
            ],
            evidence: [],
            asOf: now.addingTimeInterval(8 * 86_400)
        )[.chest]

        XCTAssertEqual(status?.weeklySetTarget, 14)
        XCTAssertEqual(status?.dailySetCap, 6)
        XCTAssertEqual(status?.balance ?? .nan, -9, accuracy: 0.001)
    }

    func testVolumeControllerIncludesHistoryHydratedAfterAnchorCreation() {
        let program = makeProgram(
            movements: 1,
            difficulty: 10,
            enabled: [.chest],
            complexes: []
        )
        let target = AdaptiveMuscleVolumeTarget(
            adaptiveProgramId: program.id,
            lineageId: program.lineageId,
            muscle: .chest,
            weeklySetTarget: 9,
            dailySetCap: 4,
            effectiveAt: now
        )
        let lateHistory = (1...2).map { offset in
            TrainingLoadEvidence(
                sessionId: UUID(),
                setEntryId: UUID(),
                exerciseId: UUID(),
                completedAt: now.addingTimeInterval(-Double(offset) * 86_400),
                muscles: [.chest],
                weight: 100,
                reps: 8,
                isSessionCompleted: true,
                isLocked: true,
                kind: offset == 1 ? .adHoc : .adaptiveComparable,
                complexDefinitionId: nil,
                componentPosition: nil
            )
        }
        let status = AdaptiveVolumeControllerService.statuses(
            program: program,
            allTargets: [target],
            anchors: [
                AdaptiveMuscleVolumeAnchor(
                    lineageId: program.lineageId,
                    muscle: .chest,
                    activatedAt: now,
                    initialBalance: -9,
                    seededDirectSetEntryIds: []
                )
            ],
            evidence: lateHistory,
            asOf: now
        )[.chest]

        XCTAssertEqual(status?.balance ?? .nan, -7, accuracy: 0.001)
    }

    func testExposurePlannerUsesFixedPriorityAndNormalSplits() {
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let row = exercise("Chest Supported Row", muscle: .back)
        let press = exercise("Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let program = makeProgram(
            movements: 2,
            difficulty: 20,
            enabled: [.back, .chest],
            complexes: [
                makeComplex(
                    id: uuid(401),
                    position: 0,
                    primary: .back,
                    components: [component(pulldown, sets: 2), component(row, position: 1, sets: 2)]
                ),
                makeComplex(
                    id: uuid(402),
                    position: 1,
                    primary: .chest,
                    components: [component(press, sets: 2)]
                )
            ]
        )
        let statuses = dueStatuses([.back, .chest])
        let first = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [pulldown, row, press, fly],
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: statuses,
            targetComplexCount: 1,
            capacity: .initial,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(first.complexes.map(\.primaryMuscle), [.chest])
        XCTAssertEqual(
            first.complexes.first?.components.map(\.exerciseName),
            ["Press", "Cable Fly"]
        )
        XCTAssertEqual(first.complexes.first?.components.map(\.prescribedSetCount), [2, 2])

        var backOnly = statuses
        backOnly[.chest]?.isEligible = false
        let back = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [pulldown, row, press, fly],
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: backOnly,
            targetComplexCount: 1,
            capacity: .initial,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(back.complexes.map(\.primaryMuscle), [.back])
        XCTAssertEqual(back.complexes.first?.components.map(\.prescribedSetCount), [3, 3])
        XCTAssertEqual(back.muscleSetDose[.back], 6)
        XCTAssertNil(back.muscleSetDose[.biceps])
    }

    func testNoneRanksBeforeLightWithNormalDoseWhileModerateIsHeld() throws {
        let chestPress = exercise("Chest Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let row = exercise("Cable Row", muscle: .back)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let curl = exercise("Curl", muscle: .biceps, type: .isolation)
        let program = makeProgram(
            movements: 4,
            difficulty: 60,
            enabled: [.chest, .back, .biceps],
            complexes: [
                makeComplex(
                    id: uuid(920),
                    position: 0,
                    primary: .chest,
                    components: [component(chestPress)]
                ),
                makeComplex(
                    id: uuid(921),
                    position: 1,
                    primary: .back,
                    components: [component(row)]
                ),
                makeComplex(
                    id: uuid(922),
                    position: 2,
                    primary: .biceps,
                    components: [component(curl)]
                )
            ]
        )
        var readiness = readyInputs
        readiness[.chest]?.soreness = .moderate
        readiness[.back]?.soreness = .mild
        readiness[.biceps]?.soreness = .none
        let statuses = dueStatuses([.chest, .back, .biceps], readiness: readiness)

        let proposal = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [chestPress, fly, row, pulldown, curl],
            readiness: readiness,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: statuses,
            targetComplexCount: 3,
            capacity: .initial,
            now: now,
            calendar: utcCalendar
        ))

        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), [.back])
        let back = try XCTUnwrap(
            proposal.complexes.first { $0.primaryMuscle == .back }
        )
        XCTAssertEqual(back.components.map(\.prescribedSetCount), [3, 3])
        XCTAssertTrue(
            proposal.rejections.contains {
                $0.complexDefinitionId == uuid(920)
                    && $0.code == "held_for_recovery"
            }
        )
    }

    func testFourthSetVariationAppliesToChestAndBackButNotIsolationOrLegWork() {
        let press = exercise("Chest Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let row = exercise("Cable Row", muscle: .back)
        let curl = exercise("Dumbbell Curl", muscle: .biceps, type: .isolation)
        let squat = exercise("Belt Squat", muscle: .quads)
        let exercises = [press, fly, pulldown, row, curl, squat]
        let program = makeProgram(
            movements: 4,
            difficulty: 60,
            enabled: [.chest, .back, .biceps, .quads],
            complexes: [
                makeComplex(
                    id: uuid(930),
                    position: 0,
                    primary: .chest,
                    components: [component(press)]
                ),
                makeComplex(
                    id: uuid(931),
                    position: 1,
                    primary: .back,
                    components: [component(pulldown)]
                ),
                makeComplex(
                    id: uuid(932),
                    position: 2,
                    primary: .biceps,
                    components: [component(curl)]
                ),
                makeComplex(
                    id: uuid(933),
                    position: 3,
                    primary: .quads,
                    components: [component(squat)]
                )
            ]
        )
        let statuses = dueStatuses([.chest, .back, .biceps, .quads])
        let proposal = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: exercises,
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: statuses,
            targetComplexCount: 4,
            capacity: AdaptiveWorkoutCapacity(
                maxMuscleGroupCount: 4,
                maxExerciseCount: 8,
                maxExercisesPerMuscle: 2,
                maxWorkingSetCount: 30,
                maxSetsPerExercise: 4
            ),
            now: now,
            calendar: utcCalendar
        ))
        let byMuscle = Dictionary(uniqueKeysWithValues: proposal.complexes.map {
            ($0.primaryMuscle, $0)
        })
        XCTAssertEqual(
            byMuscle[.chest]?.components.map(\.exerciseName),
            ["Chest Press", "Cable Fly"]
        )
        XCTAssertEqual(byMuscle[.chest]?.components.map(\.prescribedSetCount), [2, 2])
        XCTAssertEqual(
            byMuscle[.back]?.components.map(\.exerciseName),
            ["Lat Pulldown", "Cable Row"]
        )
        XCTAssertEqual(byMuscle[.back]?.components.map(\.prescribedSetCount), [3, 3])
        XCTAssertNil(byMuscle[.biceps])
        XCTAssertEqual(byMuscle[.quads]?.components.map(\.prescribedSetCount), [3])
    }

    func testLegacyIsolationOnlyChestDefinitionIsPlannedAsCompoundThenIsolation() {
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let press = exercise("Incline Dumbbell Press", muscle: .chest)
        let program = makeProgram(
            movements: 2,
            difficulty: 20,
            enabled: [.chest],
            complexes: [
                makeComplex(
                    id: uuid(940),
                    position: 0,
                    primary: .chest,
                    components: [component(fly, sets: 2)]
                )
            ]
        )
        let proposal = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [fly, press],
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: dueStatuses([.chest]),
            targetComplexCount: 1,
            capacity: .initial,
            now: now,
            calendar: utcCalendar
        ))
        XCTAssertEqual(
            proposal.complexes.first?.components.map(\.exerciseName),
            ["Incline Dumbbell Press", "Cable Fly"]
        )
        XCTAssertEqual(
            proposal.complexes.first?.components.map(\.prescribedSetCount),
            [2, 2]
        )
        XCTAssertTrue(
            proposal.complexes.first?.reasonCodes.contains("chest_compound_lead")
                == true
        )
    }

    func testInitialWorkoutCapacityHonorsPairBansAndFifteenSetCeiling() {
        let pulldown = exercise("Lat Pulldown", muscle: .back)
        let row = exercise("Cable Row", muscle: .back)
        let press = exercise("Chest Press", muscle: .chest)
        let fly = exercise("Cable Fly", muscle: .chest, type: .isolation)
        let curl = exercise("Curl", muscle: .biceps, type: .isolation)
        let tricepsExtension = exercise("Extension", muscle: .triceps, type: .isolation)
        let squat = exercise("Belt Squat", muscle: .quads)
        let hinge = exercise("Stiff-Leg Deadlift", muscle: .hamstrings)
        let allExercises = [pulldown, row, press, fly, curl, tricepsExtension, squat, hinge]
        let program = makeProgram(
            movements: 6,
            difficulty: 60,
            enabled: [.back, .chest, .biceps, .triceps, .quads, .hamstrings],
            complexes: [
                makeComplex(
                    id: uuid(501),
                    position: 0,
                    primary: .back,
                    components: [component(pulldown), component(row, position: 1)]
                ),
                makeComplex(
                    id: uuid(502),
                    position: 1,
                    primary: .chest,
                    components: [component(press), component(fly, position: 1)]
                ),
                makeComplex(id: uuid(503), position: 2, primary: .biceps, components: [component(curl)]),
                makeComplex(
                    id: uuid(504),
                    position: 3,
                    primary: .triceps,
                    components: [component(tricepsExtension)]
                ),
                makeComplex(id: uuid(505), position: 4, primary: .quads, components: [component(squat)]),
                makeComplex(id: uuid(506), position: 5, primary: .hamstrings, components: [component(hinge)])
            ]
        )
        let statuses = dueStatuses([
            .back, .chest, .biceps, .triceps, .quads, .hamstrings
        ])
        let proposal = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: allExercises,
            readiness: readyInputs,
            ledger: TrainingLoadLedger(byMuscle: [:]),
            exposureStatuses: statuses,
            targetComplexCount: 6,
            capacity: .initial,
            now: now,
            calendar: utcCalendar
        ))
        let components = proposal.complexes.flatMap(\.components)
        XCTAssertLessThanOrEqual(proposal.complexes.count, 5)
        XCTAssertLessThanOrEqual(components.count, 7)
        XCTAssertLessThanOrEqual(
            components.reduce(0) { $0 + $1.prescribedSetCount },
            15
        )
        XCTAssertTrue(Dictionary(grouping: components, by: \.primaryMuscle).values.allSatisfy {
            $0.count <= 2
        })
        XCTAssertTrue(components.allSatisfy { $0.prescribedSetCount <= 4 })
        XCTAssertFalse(
            Set(proposal.complexes.map(\.primaryMuscle)).isSuperset(of: [.chest, .triceps])
        )
        XCTAssertFalse(
            Set(proposal.complexes.map(\.primaryMuscle)).isSuperset(of: [.back, .biceps])
        )
    }

    private func makeComplex(
        id: UUID,
        name: String? = nil,
        position: Int,
        primary: MuscleGroup,
        components: [AdaptiveComplexComponent]
    ) -> AdaptiveExerciseComplex {
        AdaptiveExerciseComplex(
            definitionId: id,
            version: 1,
            name: name ?? "\(primary.displayName) Complex",
            position: position,
            primaryMuscle: primary,
            qualifiesForPrimaryFloor: true,
            components: components
        )
    }

    private func makeProgram(
        movements: Int,
        difficulty: Int,
        enabled: [MuscleGroup],
        floors: [MuscleGroup: Int] = [:],
        exerciseCaps: [MuscleGroup: Int] = [:],
        setCaps: [MuscleGroup: Int] = [:],
        complexes: [AdaptiveExerciseComplex]
    ) -> AdaptiveProgram {
        let rules = MuscleGroup.allCases.map { muscle in
            AdaptiveMuscleRule(
                muscle: muscle,
                priorityRank: enabled.firstIndex(of: muscle).map { $0 + 1 } ?? 0,
                rollingSetFloor: floors[muscle] ?? 0,
                rollingWindowDays: 7,
                maxRecoveredDayGap: 10,
                maxExercisesPerExposure: exerciseCaps[muscle] ?? 10,
                maxSetsPerExercise: setCaps[muscle] ?? 10,
                isEnabled: enabled.contains(muscle)
            )
        }
        return AdaptiveProgram(
            version: 1,
            name: "Test",
            isReviewedForUse: false,
            globalMaxMovements: movements,
            maxDifficultyCost: difficulty,
            muscleRules: rules,
            complexes: complexes
        )
    }

    private func unwrapProposal(
        _ result: AdaptivePlannerResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AdaptivePlanProposal {
        guard case .proposal(let proposal) = result else {
            XCTFail("Expected proposal, got \(result)", file: file, line: line)
            return AdaptivePlanProposal(complexes: [], totalMovements: 0, totalDifficultyCost: 0, muscleSetDose: [:], rejections: [])
        }
        return proposal
    }

    private func dueStatuses(
        _ muscles: [MuscleGroup],
        readiness: [MuscleGroup: MuscleReadinessInput]? = nil,
        overdueDays: [MuscleGroup: Int] = [:]
    ) -> [MuscleGroup: AdaptiveMuscleExposureStatus] {
        let inputs = readiness ?? readyInputs
        return Dictionary(uniqueKeysWithValues: muscles.map { muscle in
            let rule = AdaptiveExposureControllerService.defaultRule(for: muscle)
            let input = inputs[muscle]!
            return (
                muscle,
                AdaptiveMuscleExposureStatus(
                    muscle: muscle,
                    rule: rule,
                    lastDirectExposureAt: now.addingTimeInterval(-10 * 86_400),
                    nextEligibleAt: now.addingTimeInterval(
                        -Double(overdueDays[muscle] ?? 0) * 86_400
                    ),
                    daysOverdue: overdueDays[muscle] ?? 0,
                    soreness: input.soreness,
                    isEligible: rule.isAutomaticPlanningEnabled && !input.isHardBlocked
                )
            )
        })
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
