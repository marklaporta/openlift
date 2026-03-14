import XCTest
@testable import OpenLift

final class BootstrapDataServiceTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateName")
        super.tearDown()
    }

    func testPreferredPublishedCyclePrefersFB2DName() {
        let files = [
            PublishedCycleFile(
                url: URL(fileURLWithPath: "/tmp/a.json"),
                name: "general-template",
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
            PublishedCycleFile(
                url: URL(fileURLWithPath: "/tmp/b.json"),
                name: "fb-2d",
                modifiedAt: Date(timeIntervalSince1970: 50)
            )
        ]

        let preferred = BootstrapDataService.preferredPublishedCycle(from: files)
        XCTAssertEqual(preferred?.name, "fb-2d")
    }

    func testPreferredPublishedCycleFallsBackToFirst() {
        let first = PublishedCycleFile(
            url: URL(fileURLWithPath: "/tmp/first.json"),
            name: "alpha",
            modifiedAt: Date()
        )
        let second = PublishedCycleFile(
            url: URL(fileURLWithPath: "/tmp/second.json"),
            name: "beta",
            modifiedAt: Date()
        )

        let preferred = BootstrapDataService.preferredPublishedCycle(from: [first, second])
        XCTAssertEqual(preferred?.name, "alpha")
    }

    func testPreferredPublishedCycleMatchesSavedTemplateNameWithPunctuation() {
        UserDefaults.standard.set("4D Upper/Lower", forKey: "openlift.lastActivatedTemplateName")
        defer { UserDefaults.standard.removeObject(forKey: "openlift.lastActivatedTemplateName") }

        let files = [
            PublishedCycleFile(
                url: URL(fileURLWithPath: "/tmp/fb2d.json"),
                name: "fb-2d",
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
            PublishedCycleFile(
                url: URL(fileURLWithPath: "/tmp/uplow.json"),
                name: "4d-upper-lower",
                modifiedAt: Date(timeIntervalSince1970: 90)
            )
        ]

        let preferred = BootstrapDataService.preferredPublishedCycle(from: files)
        XCTAssertEqual(preferred?.name, "4d-upper-lower")
    }

    func testInferredNextDayIndexUsesLatestCompletedSessionFirst() {
        let oldCompleted = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )
        let latestCompleted = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 1,
            createdAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 220),
            status: .completed,
            exportStatus: .success
        )

        let next = BootstrapDataService.inferredNextDayIndex(
            dayCount: 2,
            sessions: [oldCompleted, latestCompleted],
            latestExportCycleDayIndex: 0
        )

        XCTAssertEqual(next, 0)
    }

    func testInferredNextDayIndexFallsBackToLatestExport() {
        let next = BootstrapDataService.inferredNextDayIndex(
            dayCount: 2,
            sessions: [],
            latestExportCycleDayIndex: 0
        )
        XCTAssertEqual(next, 1)
    }

    func testInferredNextDayIndexDefaultsToZero() {
        let next = BootstrapDataService.inferredNextDayIndex(
            dayCount: 2,
            sessions: [],
            latestExportCycleDayIndex: nil
        )
        XCTAssertEqual(next, 0)
    }

    func testRecentCycleNamePrefersLatestCompletedSnapshotOverExport() {
        let earlier = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "FB 2D",
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )
        let latest = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "4D Upper/Lower",
            createdAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 220),
            status: .completed,
            exportStatus: .success
        )
        let export = SessionExportService.ExportPayload(
            session_id: UUID().uuidString,
            cycle_name: "FB 2D",
            cycle_day_index: 1,
            date: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 230)),
            exercises: []
        )

        let selected = BootstrapDataService.recentCycleName(
            sessions: [earlier, latest],
            latestExport: export
        )

        XCTAssertEqual(selected, "4D Upper/Lower")
    }

    func testMatchingTemplateIgnoresPunctuationDifferences() {
        let template = CycleTemplate(name: "4D Upper/Lower", days: [CycleDay(label: "Upper A", slots: [])])

        let matched = BootstrapDataService.matchingTemplate(
            named: "4d-upper-lower",
            in: [template]
        )

        XCTAssertEqual(matched?.id, template.id)
    }

    func testInferredNextDayIndexFiltersSessionsByCycleName() {
        let oldFB2D = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 1,
            cycleNameSnapshot: "FB 2D",
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )
        let latestUpperLower = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 0,
            cycleNameSnapshot: "4D Upper/Lower",
            createdAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 220),
            status: .completed,
            exportStatus: .success
        )

        let next = BootstrapDataService.inferredNextDayIndex(
            dayCount: 4,
            sessions: [oldFB2D, latestUpperLower],
            targetCycleName: "4d-upper-lower",
            latestExport: nil
        )

        XCTAssertEqual(next, 1)
    }

    func testBuildDebugSnapshotIncludesExpectedCounts() {
        let exercises = [
            Exercise(name: "Leg Press", primaryMuscle: .quads, type: .compound, equipment: .machine),
            Exercise(name: "Leg Curl", primaryMuscle: .hamstrings, type: .isolation, equipment: .machine)
        ]
        let dayA = CycleDay(label: "Day A", slots: [])
        let dayB = CycleDay(label: "Day B", slots: [])
        let template = CycleTemplate(name: "FB 2D", days: [dayA, dayB])
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 1)
        let completed = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 150),
            status: .completed,
            exportStatus: .success
        )
        let draft = Session(
            cycleInstanceId: cycle.id,
            cycleDayIndex: 1,
            createdAt: Date(timeIntervalSince1970: 200),
            finishedAt: nil,
            status: .draft,
            exportStatus: .pending
        )

        let snapshot = BootstrapDataService.buildDebugSnapshot(
            exercises: exercises,
            templates: [template],
            activeCycles: [cycle],
            sessions: [completed, draft],
            latestExportCycleDayIndex: 0
        )

        XCTAssertEqual(snapshot.exerciseCount, 2)
        XCTAssertEqual(snapshot.templateCount, 1)
        XCTAssertEqual(snapshot.activeCycleCount, 1)
        XCTAssertEqual(snapshot.sessionCount, 2)
        XCTAssertEqual(snapshot.completedSessionCount, 1)
        XCTAssertEqual(snapshot.draftSessionCount, 1)
        XCTAssertEqual(snapshot.latestCompletedDayIndex, 0)
        XCTAssertEqual(snapshot.latestExportDayIndex, 0)
        XCTAssertEqual(snapshot.inferredNextDayIndex, 1)
        XCTAssertTrue(snapshot.summary.contains("templates=1"))
    }

    func testDefaultStarterTemplateBuildsExpected4DUpperLowerShape() throws {
        let template = try BootstrapDataService.defaultStarterTemplate(exercises: starterExercises())

        XCTAssertEqual(template.name, "4D Upper/Lower")
        XCTAssertEqual(CycleOrdering.sortedDays(template.days).map(\.label), ["Upper A", "Lower A", "Upper B", "Lower B"])

        let orderedDays = CycleOrdering.sortedDays(template.days)
        XCTAssertEqual(CycleOrdering.sortedSlots(orderedDays[0].slots).count, 6)
        XCTAssertEqual(CycleOrdering.sortedSlots(orderedDays[1].slots).count, 4)
        XCTAssertEqual(CycleOrdering.sortedSlots(orderedDays[2].slots).count, 6)
        XCTAssertEqual(CycleOrdering.sortedSlots(orderedDays[3].slots).count, 4)
    }

    func testDefaultStarterTemplateUsesExpectedOpeningExercises() throws {
        let exercises = starterExercises()
        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
        let template = try BootstrapDataService.defaultStarterTemplate(exercises: exercises)
        let orderedDays = CycleOrdering.sortedDays(template.days)

        let upperA = CycleOrdering.sortedSlots(orderedDays[0].slots).compactMap { exercisesById[$0.exerciseId] }
        let lowerA = CycleOrdering.sortedSlots(orderedDays[1].slots).compactMap { exercisesById[$0.exerciseId] }

        XCTAssertEqual(
            upperA,
            [
                "Flat Dumbbell Press",
                "Single-Arm Dumbbell Row",
                "Assisted Pull-Up",
                "Cable Crossover Lateral Raise",
                "Assisted Dips",
                "Incline Curl"
            ]
        )
        XCTAssertEqual(
            lowerA,
            [
                "Pendulum Squat",
                "Stiff-Leg Deadlift",
                "Leg Press",
                "Leg Curl",
            ]
        )
    }

    private func starterExercises() -> [Exercise] {
        [
            Exercise(name: "Flat Dumbbell Press", primaryMuscle: .chest, type: .compound, equipment: .dumbbell),
            Exercise(name: "Single-Arm Dumbbell Row", primaryMuscle: .back, type: .compound, equipment: .dumbbell),
            Exercise(name: "Assisted Pull-Up", primaryMuscle: .back, type: .compound, equipment: .machine),
            Exercise(name: "Cable Crossover Lateral Raise", primaryMuscle: .sideDelts, type: .isolation, equipment: .cable),
            Exercise(name: "Assisted Dips", primaryMuscle: .triceps, type: .compound, equipment: .machine),
            Exercise(name: "Incline Curl", primaryMuscle: .biceps, type: .isolation, equipment: .dumbbell),
            Exercise(name: "Pendulum Squat", primaryMuscle: .quads, type: .compound, equipment: .machine),
            Exercise(name: "Stiff-Leg Deadlift", primaryMuscle: .hamstrings, type: .compound, equipment: .barbell),
            Exercise(name: "Leg Press", primaryMuscle: .quads, type: .compound, equipment: .machine),
            Exercise(name: "Leg Curl", primaryMuscle: .hamstrings, type: .isolation, equipment: .machine),
            Exercise(name: "Incline Dumbbell Press", primaryMuscle: .chest, type: .compound, equipment: .dumbbell),
            Exercise(name: "Chest Supported Row", primaryMuscle: .back, type: .compound, equipment: .machine),
            Exercise(name: "Lat Pulldown", primaryMuscle: .back, type: .compound, equipment: .machine),
            Exercise(name: "Dumbbell Lateral Raise", primaryMuscle: .sideDelts, type: .isolation, equipment: .dumbbell),
            Exercise(name: "Dumbbell Skullcrusher", primaryMuscle: .triceps, type: .isolation, equipment: .dumbbell),
            Exercise(name: "EZ Bar Curl", primaryMuscle: .biceps, type: .isolation, equipment: .barbell),
            Exercise(name: "Hack Squat", primaryMuscle: .quads, type: .compound, equipment: .machine),
            Exercise(name: "Romanian Deadlift", primaryMuscle: .hamstrings, type: .compound, equipment: .barbell),
            Exercise(name: "Bulgarian Split Squat", primaryMuscle: .quads, type: .compound, equipment: .dumbbell),
            Exercise(name: "Lying Leg Curl", primaryMuscle: .hamstrings, type: .isolation, equipment: .machine),
        ]
    }
}

final class WorkoutEntryEditingTests: XCTestCase {
    func testEntryEditingSupportsDeleteAndReentryWithoutHistory() {
        var entries = [
            WorkoutEntryEditing.EntryState(setIndex: 1, weight: 0, reps: 0, isLocked: false),
            WorkoutEntryEditing.EntryState(setIndex: 2, weight: 0, reps: 0, isLocked: false)
        ]

        XCTAssertNil(WorkoutEntryEditing.displayWeight(entries[0].weight))
        XCTAssertNil(WorkoutEntryEditing.displayReps(entries[0].reps))

        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 1, newWeight: 22.5)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 1, newReps: 9)
        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 2, newWeight: 22.5)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 2, newReps: 8)

        XCTAssertEqual(entries[0].weight, 22.5)
        XCTAssertEqual(entries[0].reps, 9)
        XCTAssertEqual(entries[1].weight, 22.5)
        XCTAssertEqual(entries[1].reps, 8)

        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 1, newWeight: nil)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 1, newReps: nil)

        XCTAssertEqual(entries[0].weight, 0)
        XCTAssertEqual(entries[0].reps, 0)
        XCTAssertEqual(entries[1].weight, 0)
        XCTAssertEqual(entries[1].reps, 8)
        XCTAssertNil(WorkoutEntryEditing.displayWeight(entries[0].weight))
        XCTAssertNil(WorkoutEntryEditing.displayReps(entries[0].reps))

        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 1, newWeight: 25)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 1, newReps: 10)

        XCTAssertEqual(entries[0].weight, 25)
        XCTAssertEqual(entries[0].reps, 10)
        XCTAssertEqual(entries[1].weight, 25)
        XCTAssertEqual(entries[1].reps, 8)
    }

    func testEntryEditingSupportsDeleteAndReentryWithHistoryPrefill() {
        var entries = [
            WorkoutEntryEditing.EntryState(setIndex: 1, weight: 22.5, reps: 9, isLocked: false),
            WorkoutEntryEditing.EntryState(setIndex: 2, weight: 22.5, reps: 8, isLocked: false),
            WorkoutEntryEditing.EntryState(setIndex: 3, weight: 22.5, reps: 8, isLocked: false)
        ]

        XCTAssertEqual(WorkoutEntryEditing.displayWeight(entries[0].weight), 22.5)
        XCTAssertEqual(WorkoutEntryEditing.displayReps(entries[0].reps), 9)

        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 2, newWeight: nil)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 2, newReps: nil)

        XCTAssertEqual(entries[1].weight, 0)
        XCTAssertEqual(entries[1].reps, 0)
        XCTAssertEqual(entries[2].weight, 0)
        XCTAssertEqual(entries[2].reps, 8)

        WorkoutEntryEditing.applyWeightEdit(to: &entries, setIndex: 2, newWeight: 20)
        WorkoutEntryEditing.applyRepsEdit(to: &entries, setIndex: 2, newReps: 12)

        XCTAssertEqual(entries[1].weight, 20)
        XCTAssertEqual(entries[1].reps, 12)
        XCTAssertEqual(entries[2].weight, 20)
        XCTAssertEqual(entries[2].reps, 8)
    }

    func testRepairKnownMalformedEntryFixesReportedWorkoutValues() {
        var cableWeight = 15.0
        var cableReps = 68
        XCTAssertTrue(
            WorkoutEntryEditing.repairKnownMalformedEntry(
                exerciseName: "Cable Crossover Lateral Raise",
                setIndex: 2,
                weight: &cableWeight,
                reps: &cableReps
            )
        )
        XCTAssertEqual(cableWeight, 15.0)
        XCTAssertEqual(cableReps, 8)

        var skullWeight = 0.0
        var skullReps = 910
        XCTAssertTrue(
            WorkoutEntryEditing.repairKnownMalformedEntry(
                exerciseName: "Dumbell Skullcrusher",
                setIndex: 1,
                weight: &skullWeight,
                reps: &skullReps
            )
        )
        XCTAssertEqual(skullWeight, 22.5)
        XCTAssertEqual(skullReps, 9)

        var inclineWeight = 0.0
        var inclineReps = 19
        XCTAssertTrue(
            WorkoutEntryEditing.repairKnownMalformedEntry(
                exerciseName: "Incline Curl",
                setIndex: 1,
                weight: &inclineWeight,
                reps: &inclineReps
            )
        )
        XCTAssertEqual(inclineWeight, 22.5)
        XCTAssertEqual(inclineReps, 9)
    }
}

final class WorkoutDraftSelectionTests: XCTestCase {
    func testPrefersDraftMatchingActiveCycleCurrentDayOverNewerStaleDraft() {
        let activeCycle = ActiveCycleInstance(templateId: UUID(), currentDayIndex: 1)
        let staleDraft = Session(
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 200),
            status: .draft
        )
        let correctDraft = Session(
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            status: .draft
        )

        let selected = preferredDraftSession(
            from: [staleDraft, correctDraft],
            activeCycle: activeCycle
        )

        XCTAssertEqual(selected?.id, correctDraft.id)
    }

    func testFallsBackToNewestDraftForActiveCycleWhenCurrentDayDraftMissing() {
        let activeCycle = ActiveCycleInstance(templateId: UUID(), currentDayIndex: 1)
        let olderDraft = Session(
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 100),
            status: .draft
        )
        let newerDraft = Session(
            cycleInstanceId: activeCycle.id,
            cycleDayIndex: 2,
            createdAt: Date(timeIntervalSince1970: 200),
            status: .draft
        )

        let selected = preferredDraftSession(
            from: [olderDraft, newerDraft],
            activeCycle: activeCycle
        )

        XCTAssertEqual(selected?.id, newerDraft.id)
    }

    private func preferredDraftSession(
        from sessions: [Session],
        activeCycle: ActiveCycleInstance?
    ) -> Session? {
        let drafts = sessions
            .filter { $0.status == .draft }
            .sorted { $0.createdAt > $1.createdAt }

        guard let activeCycle else {
            return drafts.first
        }

        return drafts.first(where: {
            $0.cycleInstanceId == activeCycle.id && $0.cycleDayIndex == activeCycle.currentDayIndex
        }) ?? drafts.first(where: {
            $0.cycleInstanceId == activeCycle.id
        }) ?? drafts.first
    }
}

final class CycleActivationConfirmationTests: XCTestCase {
    func testRequiresConfirmationWhenSwitchingToDifferentTemplate() {
        let activeTemplateId = UUID()
        let requestedTemplateId = UUID()

        let shouldConfirm = cycleActivationShouldConfirm(
            activeTemplateId: activeTemplateId,
            requestedTemplateId: requestedTemplateId
        )

        XCTAssertTrue(shouldConfirm)
    }

    func testSkipsConfirmationWhenReactivatingCurrentTemplate() {
        let activeTemplateId = UUID()

        let shouldConfirm = cycleActivationShouldConfirm(
            activeTemplateId: activeTemplateId,
            requestedTemplateId: activeTemplateId
        )

        XCTAssertFalse(shouldConfirm)
    }

    func testSkipsConfirmationWhenNoCycleIsActive() {
        let shouldConfirm = cycleActivationShouldConfirm(
            activeTemplateId: nil,
            requestedTemplateId: UUID()
        )

        XCTAssertFalse(shouldConfirm)
    }

    private func cycleActivationShouldConfirm(
        activeTemplateId: UUID?,
        requestedTemplateId: UUID
    ) -> Bool {
        guard let activeTemplateId else { return false }
        return activeTemplateId != requestedTemplateId
    }
}

final class OpenLiftStateResolverTests: XCTestCase {
    func testDraftSessionIdsOnlyIncludesDraftsForRequestedCycle() {
        let targetCycle = ActiveCycleInstance(templateId: UUID(), currentDayIndex: 0)
        let otherCycle = ActiveCycleInstance(templateId: UUID(), currentDayIndex: 1)

        let targetDraft = Session(
            cycleInstanceId: targetCycle.id,
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 100),
            status: .draft
        )
        let otherDraft = Session(
            cycleInstanceId: otherCycle.id,
            cycleDayIndex: 1,
            createdAt: Date(timeIntervalSince1970: 200),
            status: .draft
        )
        let completed = Session(
            cycleInstanceId: targetCycle.id,
            cycleDayIndex: 0,
            createdAt: Date(timeIntervalSince1970: 300),
            status: .completed,
            exportStatus: .success
        )

        let selectedIds = OpenLiftStateResolver.draftSessionIds(
            sessions: [targetDraft, otherDraft, completed],
            forCycleId: targetCycle.id
        )

        XCTAssertEqual(selectedIds, [targetDraft.id])
    }

    func testMostRecentCompletedSessionMatchesByTemplateNameNotCycleInstance() {
        let template = CycleTemplate(name: "4D Upper/Lower", days: [CycleDay(label: "Upper A", slots: [])])
        let oldCycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)
        let newCycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)

        let olderSession = Session(
            cycleInstanceId: oldCycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: "4D Upper/Lower",
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )
        let newerSession = Session(
            cycleInstanceId: newCycle.id,
            cycleDayIndex: 0,
            cycleNameSnapshot: "4D Upper/Lower",
            createdAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 220),
            status: .completed,
            exportStatus: .success
        )

        let selected = OpenLiftStateResolver.mostRecentCompletedSession(
            sessions: [olderSession, newerSession],
            activeCycles: [oldCycle, newCycle],
            templates: [template],
            templateName: "4d-upper-lower",
            cycleDayIndex: 0
        )

        XCTAssertEqual(selected?.id, newerSession.id)
    }

    func testCycleNameUsesSnapshotWhenCycleInstanceIsMissing() {
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 1,
            cycleNameSnapshot: "4D Upper/Lower",
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )

        let cycleName = OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: [],
            templates: []
        )

        XCTAssertEqual(cycleName, "4D Upper/Lower")
    }

    func testDayLabelFallsBackToIndexedLabelWhenCycleInstanceIsMissing() {
        let session = Session(
            cycleInstanceId: UUID(),
            cycleDayIndex: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 120),
            status: .completed,
            exportStatus: .success
        )

        let dayLabel = OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: [],
            templates: []
        )

        XCTAssertEqual(dayLabel, "Day 2")
    }
}
