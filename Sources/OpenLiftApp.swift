import SwiftUI
import SwiftData

@main
struct OpenLiftApp: App {
    private static let schema = Schema(versionedSchema: OpenLiftSchemaV6.self)

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
        return OpenLiftModelContainerFactory.makePersistent(
            schema: schema,
            migrationPlan: OpenLiftSchemaMigrationPlan.self,
            configuration: configuration
        )
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
