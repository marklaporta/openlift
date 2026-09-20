import SwiftData
import XCTest
@testable import OpenLift

@MainActor
final class WorkoutCompletionTests: XCTestCase {
    private enum InjectedFailure: Error { case save }

    private func context() -> ModelContext {
        let container = OpenLiftModelContainerFactory.makeInMemory(
            schema: Schema(versionedSchema: OpenLiftSchemaV16.self)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func fixedFixture(_ context: ModelContext) throws -> (Session, ActiveCycleInstance, CycleTemplate, SetEntry, SetEntry) {
        let exercise = Exercise(name: "Completion fixture", primaryMuscle: .chest, type: .compound, equipment: .dumbbell)
        let day = CycleDay(label: "A", slots: [CycleSlot(position: 0, muscle: .chest, exerciseId: exercise.id)], position: 0)
        let template = CycleTemplate(name: "Completion fixture", days: [day, CycleDay(label: "B", slots: [], position: 1)])
        let cycle = ActiveCycleInstance(templateId: template.id)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        let locked = SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: 1, weight: 25, reps: 8, isLocked: true)
        let draft = SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: 2, weight: 25, reps: 8)
        context.insert(exercise)
        context.insert(template)
        context.insert(cycle)
        context.insert(session)
        context.insert(locked)
        context.insert(draft)
        try context.save()
        return (session, cycle, template, locked, draft)
    }

    func testFailedFixedSaveRestoresDraftRowsAndPointerThenRetryCompletesExactlyOnce() throws {
        let context = context()
        let (session, cycle, template, locked, draft) = try fixedFixture(context)
        XCTAssertThrowsError(try WorkoutCompletionService.finishFixed(
            session: session, cycle: cycle, template: template, modelContext: context,
            save: { _ in throw InjectedFailure.save }
        ))
        XCTAssertEqual(session.status, .draft)
        XCTAssertNil(session.finishedAt)
        XCTAssertEqual(cycle.currentDayIndex, 0)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<SetEntry>()).map(\.id)), Set([locked.id, draft.id]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FixedCycleExerciseSnapshot>()), 0)

        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context, now: finishedAt)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context, now: finishedAt.addingTimeInterval(60), save: { _ in XCTFail("Repeated completion must not save or advance") })
        let readback = ModelContext(context.container)
        let saved = try XCTUnwrap(readback.fetch(FetchDescriptor<Session>()).first)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.exportStatus, .pending)
        XCTAssertEqual(saved.finishedAt, finishedAt)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.currentDayIndex, 1)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<SetEntry>()).map(\.id), [locked.id])
        XCTAssertEqual(try readback.fetchCount(FetchDescriptor<FixedCycleExerciseSnapshot>()), 1)
        XCTAssertEqual(try readback.fetchCount(FetchDescriptor<ExportDiagnostic>()), 0)
    }

    func testPersistentCompletionReopensPendingBeforeAnyExportDelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        let sessionID: UUID = try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let (session, cycle, template, _, _) = try fixedFixture(context)
            try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
            return session.id
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let readback = ModelContext(reopened)
        let saved = try XCTUnwrap(readback.fetch(FetchDescriptor<Session>()).first { $0.id == sessionID })
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.exportStatus, .pending)
        XCTAssertNotNil(saved.finishedAt)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.currentDayIndex, 1)
        XCTAssertEqual(try readback.fetchCount(FetchDescriptor<SetEntry>()), 1)
        XCTAssertEqual(try readback.fetchCount(FetchDescriptor<ExportDiagnostic>()), 0)
    }

    func testCommittedWorkoutSurvivesFailedDeliveryAndRepeatedRetryNeverAdvances() async throws {
        let context = context()
        let (session, cycle, template, locked, _) = try fixedFixture(context)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
        let finishedAt = session.finishedAt
        let deliveryContext = ModelContext(context.container)
        let unavailable = SessionExportService.ExportEnvironment(
            containerIdentifier: nil, iCloudContainerURL: nil, localDocumentsURL: nil,
            coordinatedWrite: { _, _ in XCTFail("No destination should be written") },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: false, isUploaded: false, isUploading: false, uploadingErrorDescription: nil) }
        )
        _ = try await SessionExportService.retryPendingCompletedSessionExportsAsync(modelContext: deliveryContext, environment: unavailable)
        let afterFailure = ModelContext(context.container)
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<Session>()).first?.status, .completed)
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<Session>()).first?.exportStatus, .failed)
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.currentDayIndex, 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = SessionExportService.ExportEnvironment(
            containerIdentifier: nil, iCloudContainerURL: directory, localDocumentsURL: directory,
            coordinatedWrite: { data, url in
                XCTAssertFalse(Thread.isMainThread, "Completed export file delivery must not block the UI actor")
                try data.write(to: url, options: .atomic)
            },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: true, isUploaded: true, isUploading: false, uploadingErrorDescription: nil) }
        )
        _ = try await SessionExportService.retryPendingCompletedSessionExportsAsync(modelContext: deliveryContext, environment: local)
        _ = try await SessionExportService.retryPendingCompletedSessionExportsAsync(modelContext: deliveryContext, environment: local)
        let readback = ModelContext(context.container)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<Session>()).first?.exportStatus, .success)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<Session>()).first?.finishedAt, finishedAt)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.currentDayIndex, 1)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<SetEntry>()).map(\.id), [locked.id])
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("OpenLift/exports"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
    }

    func testProfileCorrectionDuringSuspendedExportStaysPendingUntilFreshPayloadIsDelivered() async throws {
        let context = context()
        let (session, cycle, template, locked, _) = try fixedFixture(context)
        let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first)
        exercise.equipment = .cable
        let profile = try ResistanceProfileService.create(
            workoutKind: .fixed, sessionId: session.id, exerciseId: exercise.id,
            value: .voltra(chainType: .none, eccentricPercent: 0), profiles: [], modelContext: context
        )
        profile.frozenAt = .now
        try context.save()
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writerStarted = expectation(description: "Old payload reached file writer")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        let suspended = SessionExportService.ExportEnvironment(
            containerIdentifier: nil, iCloudContainerURL: directory, localDocumentsURL: directory,
            coordinatedWrite: { data, url in
                writerStarted.fulfill()
                guard releaseWriter.wait(timeout: .now() + 10) == .success else {
                    throw NSError(domain: "SuspendedExportTest", code: 1)
                }
                try data.write(to: url, options: .atomic)
            },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: true, isUploaded: true, isUploading: false, uploadingErrorDescription: nil) }
        )
        let delivery = Task { @MainActor in
            try await SessionExportService.deliverCompletedSession(
                sessionId: session.id, kind: .fixed, modelContainer: context.container, environment: suspended
            )
        }
        await fulfillment(of: [writerStarted], timeout: 5)
        let correctionContext = ModelContext(context.container)
        let savedProfile = try XCTUnwrap(correctionContext.fetch(FetchDescriptor<ExerciseResistanceProfile>()).first)
        try ResistanceProfileService.update(
            savedProfile, to: .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30),
            confirmedOccurrenceWideCorrection: true, modelContext: correctionContext
        )
        releaseWriter.signal()
        let oldOutcome = try await delivery.value
        XCTAssertEqual(oldOutcome.status, .pending)
        let pendingReadback = ModelContext(context.container)
        XCTAssertEqual(try pendingReadback.fetch(FetchDescriptor<Session>()).first?.exportStatus, .pending)
        XCTAssertEqual(try pendingReadback.fetch(FetchDescriptor<ActiveCycleInstance>()).first?.currentDayIndex, 1)
        let freshEnvironment = SessionExportService.ExportEnvironment(
            containerIdentifier: nil, iCloudContainerURL: directory, localDocumentsURL: directory,
            coordinatedWrite: { data, url in try data.write(to: url, options: .atomic) },
            ubiquityMetadata: { _ in .init(isUbiquitousItem: true, isUploaded: true, isUploading: false, uploadingErrorDescription: nil) }
        )
        let freshOutcome = try await SessionExportService.deliverCompletedSession(
            sessionId: session.id, kind: .fixed, modelContainer: context.container, environment: freshEnvironment
        )
        XCTAssertEqual(freshOutcome.status, .success)
        let payload = try XCTUnwrap(SessionExportService.decodeExportPayload(data: Data(contentsOf: XCTUnwrap(freshOutcome.localMirrorURL))))
        XCTAssertEqual(payload.exercises.first?.resistance_profile?.chain_percent, 70)
        XCTAssertEqual(payload.exercises.first?.resistance_profile?.eccentric_percent, 30)
        let readback = ModelContext(context.container)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<Session>()).first?.exportStatus, .success)
        XCTAssertEqual(try readback.fetch(FetchDescriptor<SetEntry>()).map(\.id), [locked.id])
        XCTAssertEqual(try readback.fetchCount(FetchDescriptor<ExportDiagnostic>()), 1)
    }

    func testClusterSaveFailureAndFinishFailurePreserveIndependentAdvancement() throws {
        let context = context()
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try FixedCycleClusterProgramService.makeTemplate(exercises: exercises)
        let cycle = ActiveCycleInstance(templateId: template.id)
        context.insert(template)
        context.insert(cycle)
        let states = FixedCycleClusterProgramService.makeRotationStates(cycleInstanceId: cycle.id, templateId: template.id)
        states.forEach(context.insert)
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        context.insert(session)
        try context.save()
        let selection = try XCTUnwrap(FixedCycleClusterProgramService.selections(template: template, cycleInstanceId: cycle.id, states: states).first)
        XCTAssertThrowsError(try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context, save: { _ in throw InjectedFailure.save }))
        XCTAssertTrue(states.allSatisfy { $0.positionIndex == 0 })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClusterOccurrenceRecord>()), 0)
        try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context)
        try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context, save: { _ in XCTFail("Cluster completion must be idempotent") })
        XCTAssertEqual(states.map(\.positionIndex).sorted(), [0, 0, 1])
        XCTAssertThrowsError(try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context, save: { _ in throw InjectedFailure.save }))
        XCTAssertEqual(session.status, .draft)
        XCTAssertEqual(states.map(\.positionIndex).sorted(), [0, 0, 1])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClusterOccurrenceRecord>()), 1)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.exportStatus, .pending)
        XCTAssertEqual(cycle.currentDayIndex, 0)
        XCTAssertEqual(states.map(\.positionIndex).sorted(), [0, 0, 1])
    }

    func testCopiedCurrentStoreCompletionPreservesHistoryWhenOptedIn() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let source = documents.appendingPathComponent("OpenLiftCopiedCompletionStore/default.store")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Stage a verified store in Documents/OpenLiftCopiedCompletionStore/default.store")
        }
        let originalBytes = try Data(contentsOf: source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: source, to: scratch)
        let schema = Schema(versionedSchema: OpenLiftSchemaV16.self)
        let container = try ModelContainer(for: schema, migrationPlan: OpenLiftSchemaMigrationPlan.self, configurations: [ModelConfiguration(schema: schema, url: scratch, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let history = sessions.filter { $0.status == .completed }
        let historicalIDs = Set(history.map(\.id))
        let historyRows = try context.fetch(FetchDescriptor<SetEntry>()).filter { historicalIDs.contains($0.sessionId) }
        let rowEvidence = Dictionary(uniqueKeysWithValues: historyRows.map { ($0.id, "\($0.sessionId)|\($0.exerciseId)|\($0.weight)|\($0.reps)|\($0.isLocked)") })
        let states = try context.fetch(FetchDescriptor<ClusterRotationState>())
        let cycles = try context.fetch(FetchDescriptor<ActiveCycleInstance>())
        let templates = try context.fetch(FetchDescriptor<CycleTemplate>())
        let template = try XCTUnwrap(templates.first { $0.name.contains("v8") || $0.name.contains("Synced") })
        let cycle = try XCTUnwrap(cycles.first { $0.templateId == template.id })
        // Use a synthetic draft in the scratch store only; real pending work stays untouched.
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
        context.insert(session)
        try context.save()
        let selection = try XCTUnwrap(FixedCycleClusterProgramService.selections(template: template, cycleInstanceId: cycle.id, states: states).first)
        let preferences = try context.fetch(FetchDescriptor<ClusterExercisePreference>())
        let resolved = FixedCycleClusterProgramService.resolvedSlots(selection: selection, sessionId: session.id, preferences: preferences, overrides: [])
        let exerciseID = try XCTUnwrap(resolved.first?.exerciseId)
        let exercise = try XCTUnwrap(context.fetch(FetchDescriptor<Exercise>()).first { $0.id == exerciseID })
        context.insert(SetEntry(sessionId: session.id, exerciseId: exerciseID, setIndex: 1, weight: 25, reps: 8, isLocked: true))
        if exercise.equipment.supportsResistanceProfile {
            context.insert(ExerciseResistanceProfile(
                workoutKind: .fixed, sessionId: session.id, exerciseId: exerciseID,
                resistanceSource: .voltra, chainType: .inverseChains,
                chainPercent: 70, eccentricPercent: 30, frozenAt: .now
            ))
        }
        try context.save()
        let before = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.positionIndex) })
        try WorkoutCompletionService.completeCluster(selection, session: session, modelContext: context)
        let advanced = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.positionIndex) })
        XCTAssertEqual(states.filter { before[$0.id] != $0.positionIndex }.count, 1)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
        try WorkoutCompletionService.finishFixed(session: session, cycle: cycle, template: template, modelContext: context)
        let retry = ModelContext(container)
        let nowhere = SessionExportService.ExportEnvironment(containerIdentifier: nil, iCloudContainerURL: nil, localDocumentsURL: nil, coordinatedWrite: { _, _ in }, ubiquityMetadata: { _ in .init(isUbiquitousItem: false, isUploaded: false, isUploading: false, uploadingErrorDescription: nil) })
        // Retry only the new record: do not rewrite unrelated history even in this clone.
        let savedSession = try XCTUnwrap(retry.fetch(FetchDescriptor<Session>()).first { $0.id == session.id })
        XCTAssertThrowsError(try SessionExportService.retryCompletedSessionExport(sessionId: savedSession.id, modelContext: retry, environment: nowhere))
        try retry.save()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.positionIndex) }), advanced)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Session>()).filter { $0.status == .completed }.map(\.id)), historicalIDs.union([session.id]))
        let finalRows = try context.fetch(FetchDescriptor<SetEntry>()).filter { historicalIDs.contains($0.sessionId) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: finalRows.map { ($0.id, "\($0.sessionId)|\($0.exerciseId)|\($0.weight)|\($0.reps)|\($0.isLocked)") }), rowEvidence)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        print("COMPLETION_COPIED_STORE_PASS history=\(historicalIDs.count) historicalRows=\(rowEvidence.count) version=\(selection.programVersionID)")
    }
}
