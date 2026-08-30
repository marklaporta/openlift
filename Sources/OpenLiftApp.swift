import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct OpenLiftApp: App {
    private static let schema = Schema(versionedSchema: OpenLiftSchemaV14.self)

    private static let startup: OpenLiftContainerStartup = {
        AppRuntime.prepareForUITesting()

        if AppRuntime.isUITesting {
            let container = OpenLiftModelContainerFactory.makeInMemory(schema: schema)
            if AppRuntime.shouldPrepareClusteredProgramRollout {
                let modelContext = ModelContext(container)
                _ = try? BootstrapDataService.prepareClusteredProgramRollout(
                    modelContext: modelContext,
                    clusteredDraftBackupConfirmed: true
                )
            }
            return OpenLiftContainerStartup(
                container: container,
                issue: nil
            )
        }

        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )
        let startup = OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: configuration
        )
        if startup.issue == nil, AppRuntime.shouldPreparePushPullRollout {
            let modelContext = ModelContext(startup.container)
            do {
                let result = try BootstrapDataService.preparePushPullABRollout(
                    modelContext: modelContext,
                    archivedDraftsConfirmed: AppRuntime.archivedPushPullDraftsAreConfirmed
                )
                print(
                    "OPENLIFT_PUSH_PULL_ROLLOUT_RESULT applied=\(result.didApply) template=\(result.templateId) cycle=\(result.cycleId)"
                )
            } catch {
                print("OPENLIFT_PUSH_PULL_ROLLOUT_FAILED \(error.localizedDescription)")
            }
        }
        if startup.issue == nil, AppRuntime.shouldPrepareClusteredProgramRollout {
            let modelContext = ModelContext(startup.container)
            do {
                let result = try BootstrapDataService.prepareClusteredProgramRollout(
                    modelContext: modelContext,
                    clusteredDraftBackupConfirmed: AppRuntime.clusteredDraftBackupIsConfirmed
                )
                print(
                    "OPENLIFT_CLUSTERED_PROGRAM_ROLLOUT_RESULT applied=\(result.didApply) template=\(result.templateId) cycle=\(result.cycleId)"
                )
            } catch {
                print("OPENLIFT_CLUSTERED_PROGRAM_ROLLOUT_FAILED \(error.localizedDescription)")
            }
        }
        if startup.issue == nil, AppRuntime.shouldRepairJuly27AdaptiveInclineCurl {
            let modelContext = ModelContext(startup.container)
            do {
                let result = try BootstrapDataService.repairJuly27AdaptiveInclineCurl(
                    modelContext: modelContext,
                    backupConfirmed: AppRuntime.july27AdaptiveInclineCurlBackupIsConfirmed
                )
                let exportOutcome = try AdaptiveExportService.retryCompletedSessionExport(
                    sessionId: result.sessionId,
                    modelContext: modelContext
                )
                print(
                    "OPENLIFT_JULY_27_INCLINE_CURL_REPAIR_RESULT applied=\(result.didApply) session=\(result.sessionId) export=\(exportOutcome.status.rawValue) file=\(exportOutcome.filename)"
                )
            } catch {
                print(
                    "OPENLIFT_JULY_27_INCLINE_CURL_REPAIR_FAILED \(error.localizedDescription)"
                )
            }
        }
        if startup.issue == nil, !AppRuntime.isUITesting {
            let modelContext = ModelContext(startup.container)
            do {
                let result = try BootstrapDataService.repairAugust16PullACompletionDate(
                    modelContext: modelContext
                )
                if result.didApply {
                    let exportOutcome = try SessionExportService.retryCompletedSessionExport(
                        sessionId: result.sessionId,
                        modelContext: modelContext
                    )
                    print(
                        "OPENLIFT_AUGUST_16_PULL_A_DATE_REPAIR_RESULT applied=true session=\(result.sessionId) export=\(exportOutcome.status.rawValue) file=\(exportOutcome.filename)"
                    )
                }
            } catch BootstrapDataService.August16PullACompletionRepairError.targetSessionNotFound {
                // Expected for clean installs and stores that predate this
                // exact reviewed session. This build is safe for every tester.
            } catch {
                print(
                    "OPENLIFT_AUGUST_16_PULL_A_DATE_REPAIR_FAILED \(error.localizedDescription)"
                )
            }
        }
        if startup.issue == nil, !AppRuntime.isUITesting {
            let modelContext = ModelContext(startup.container)
            do {
                let result = try HistoricalResistanceProfileMigration.runAtStartup(
                    modelContext: modelContext
                )
                print(
                    "OPENLIFT_VOLTRA_BACKFILL_RESULT status=\(result.status.rawValue) candidates=\(result.auditedCandidateCount) created=\(result.createdProfileCount) corrected=\(result.correctedProfileCount) sessions=\(result.repairedSessionCount)"
                )
                if result.status == .applied {
                    let adaptiveIds = Set(
                        try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>()).map(\.id)
                    )
                    var successes = 0
                    var hadFailure = false
                    for sessionId in result.repairedSessionIds {
                        do {
                            if adaptiveIds.contains(sessionId) {
                                _ = try AdaptiveExportService.retryCompletedSessionExport(
                                    sessionId: sessionId,
                                    modelContext: modelContext
                                )
                            } else {
                                _ = try SessionExportService.retryCompletedSessionExport(
                                    sessionId: sessionId,
                                    modelContext: modelContext
                                )
                            }
                            successes += 1
                        } catch {
                            hadFailure = true
                            print(
                                "OPENLIFT_VOLTRA_BACKFILL_EXPORT_FAILED session=\(sessionId.uuidString) \(error.localizedDescription)"
                            )
                        }
                    }
                    if hadFailure {
                        SessionExportService.scheduleBackgroundExportRetry()
                    }
                    print("OPENLIFT_VOLTRA_BACKFILL_EXPORT_RESULT successes=\(successes)")
                }
            } catch {
                print("OPENLIFT_VOLTRA_BACKFILL_FAILED \(error.localizedDescription)")
            }
        }
        return startup
    }()

    private static var sharedModelContainer: ModelContainer {
        startup.container
    }

    init() {
        guard !AppRuntime.isUITesting else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SessionExportService.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let operation = Task {
                let startup = Self.startup
                guard startup.issue == nil else {
                    refreshTask.setTaskCompleted(success: false)
                    return
                }
                await SessionExportService.runBackgroundExportRetry(
                    modelContainer: startup.container
                )
                refreshTask.setTaskCompleted(success: !Task.isCancelled)
            }
            refreshTask.expirationHandler = {
                operation.cancel()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let issue = Self.startup.issue {
                StoreStartupFailureView(issue: issue)
            } else {
                RootTabView()
            }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}

private struct StoreStartupFailureView: View {
    let issue: OpenLiftStoreStartupIssue

    var body: some View {
        ContentUnavailableView {
            Label("Workout Database Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(issue.userMessage)
                .textSelection(.enabled)
        } actions: {
            Text("No workout data was moved, deleted, or replaced.")
                .font(.headline)
                .accessibilityLabel("No workout data was moved, deleted, or replaced")
        }
        .padding()
    }
}
