import XCTest
@testable import OpenLift

final class AdaptivePlanningServicesTests: XCTestCase {
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
        let configuredBack = exercise("Configured Back", muscle: .back)
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
            exercises: [configuredQuad, configuredHamstring, configuredBack, beltSquat, stiffLegDeadlift],
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
            ["Belt Squat", "Configured Back"]
        )
        XCTAssertTrue(proposal.rejections.contains { $0.complexDefinitionId == uuid(801) })
    }

    func testDisabledMusclesDoNotRequireReadiness() {
        let chest = exercise("Chest", muscle: .chest)
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
            exercises: [chest],
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
        XCTAssertEqual(trace.plannerVersion, 5)
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
                exercises: [inclinePress, flatPress],
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
        let back = exercise("Back", muscle: .back)
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
                exercises: [chest, back],
                readiness: readyInputs,
                ledger: ledger,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), [.back])
        XCTAssertEqual(proposal.complexes.first?.reasonCodes, ["back_exposure_due"])
    }

    func testBinaryTrainingWindowSchedulesOneQualifyingExposureWithoutCreatingASetQuota() {
        let back = exercise("Back", muscle: .back)
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
                exercises: [back],
                readiness: readyInputs,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), [.back])
        XCTAssertEqual(proposal.muscleSetDose[.back], 2)
        XCTAssertEqual(proposal.complexes.first?.reasonCodes, ["back_exposure_due"])
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

        let proposal = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: exercises,
                readiness: readyInputs,
                ledger: TrainingLoadLedger(byMuscle: [:]),
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.totalMovements, 4)
        XCTAssertEqual(proposal.complexes.map(\.primaryMuscle), Array(muscles.prefix(4)))
        XCTAssertEqual(proposal.complexes.flatMap(\.components).map(\.prescribedSetCount), [2, 2, 2, 2])
        XCTAssertTrue(proposal.complexes.allSatisfy { $0.reasonCodes.first?.hasSuffix("_exposure_due") == true })
    }

    func testOneShoulderSetSatisfiesTrainingWindowButShouldersRemainEligibleOnNextDay() {
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

        XCTAssertEqual(proposal.complexes.first?.reasonCodes, ["sideDelts_priority"])
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
                exercises: [sldl, hackSquat, row],
                readiness: readyInputs,
                ledger: recentLedger([.hamstrings, .quads, .back]),
                targetComplexCount: 2,
                now: now,
                calendar: utcCalendar
            )
        )

        XCTAssertEqual(proposal.complexes.map(\.name), ["SLDL Complex", "Hard Row Complex"])
        XCTAssertEqual(proposal.totalDifficultyCost, 6)
        XCTAssertTrue(proposal.rejections.contains { $0.complexDefinitionId == uuid(2) })

        let noConflict = unwrapProposal(
            AdaptivePlanService.generate(
                program: program,
                exercises: [sldl, hackSquat, row],
                readiness: readyInputs,
                ledger: recentLedger([.hamstrings, .quads, .back]),
                targetComplexCount: 3,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(Set(noConflict.complexes.map(\.primaryMuscle)), [.hamstrings, .quads, .back])
    }

    func testFirstMorningAfterExposureIsObservationWindowEvenWithNoSoreness() {
        let press = exercise("Press", muscle: .chest)
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
                exercises: [press],
                readiness: readyInputs,
                ledger: firstMorningLedger,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertTrue(firstMorning.complexes.isEmpty)
        XCTAssertEqual(firstMorning.rejections, [
            .init(complexDefinitionId: uuid(80), code: "doms_observation_window")
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
                exercises: [press],
                readiness: readyInputs,
                ledger: secondMorningLedger,
                now: now,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(secondMorning.complexes.map(\.name), ["Chest Complex"])
    }

    func testShouldersCanRepeatNextDayAndSecondaryArmLoadingDoesNotStartDirectHold() {
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
        XCTAssertEqual(proposal.complexes.map(\.name), ["Shoulders Complex", "Triceps Complex"])
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
        let a = makeComplex(id: uuid(1), position: 0, primary: .chest, components: [component(first)])
        let b = makeComplex(id: uuid(2), position: 0, primary: .chest, components: [component(second)])
        let programA = makeProgram(movements: 1, difficulty: 3, enabled: [.chest], complexes: [b, a])
        let programB = makeProgram(movements: 1, difficulty: 3, enabled: [.chest], complexes: [a, b])

        let idsA = unwrapProposal(AdaptivePlanService.generate(
            program: programA,
            exercises: [second, first],
            readiness: readyInputs,
            ledger: recentLedger([.chest]),
            now: now,
            calendar: utcCalendar
        )).complexes.map(\.definitionId)
        let idsB = unwrapProposal(AdaptivePlanService.generate(
            program: programB,
            exercises: [first, second],
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
            exercises: [press, fly, row, curl],
            readiness: readyInputs,
            ledger: recentLedger([.chest, .back, .biceps]),
            targetComplexCount: 1,
            now: now,
            calendar: utcCalendar
        ))
        let two = unwrapProposal(AdaptivePlanService.generate(
            program: program,
            exercises: [press, fly, row, curl],
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

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
