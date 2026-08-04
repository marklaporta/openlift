import SwiftUI
import SwiftData

@main
struct OpenLiftApp: App {
    private static let schema = Schema(versionedSchema: OpenLiftSchemaV12.self)

    private static let startup: OpenLiftContainerStartup = {
        AppRuntime.prepareForUITesting()

        if AppRuntime.isUITesting {
            return OpenLiftContainerStartup(
                container: OpenLiftModelContainerFactory.makeInMemory(schema: schema),
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
                let result = try HistoricalResistanceProfileMigration.runAtStartup(
                    modelContext: modelContext
                )
                print(
                    "OPENLIFT_VOLTRA_BACKFILL_RESULT status=\(result.status.rawValue) candidates=\(result.auditedCandidateCount) profiles=\(result.createdProfileCount) sessions=\(result.repairedSessionCount)"
                )
                if result.status == .applied {
                    do {
                        let exportCount = try SessionExportService.retryPendingCompletedSessionExports(
                            modelContext: modelContext
                        )
                        print("OPENLIFT_VOLTRA_BACKFILL_EXPORT_RESULT successes=\(exportCount)")
                    } catch {
                        SessionExportService.scheduleBackgroundExportRetry()
                        print(
                            "OPENLIFT_VOLTRA_BACKFILL_EXPORT_FAILED \(error.localizedDescription)"
                        )
                    }
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

    var body: some Scene {
        WindowGroup {
            if let issue = Self.startup.issue {
                StoreStartupFailureView(issue: issue)
            } else {
                RootTabView()
            }
        }
        .modelContainer(Self.sharedModelContainer)
        .backgroundTask(.appRefresh(SessionExportService.backgroundRefreshIdentifier)) {
            let startup = await Self.startup
            if startup.issue == nil {
                await SessionExportService.runBackgroundExportRetry(modelContainer: startup.container)
            }
        }
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
