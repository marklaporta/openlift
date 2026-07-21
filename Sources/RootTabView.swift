import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            LogWorkoutView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle")
                }

            WorkoutView()
                .tabItem {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            CycleView()
                .tabItem {
                    Label("Cycle", systemImage: "arrow.triangle.2.circlepath")
                }

            ImportView()
                .tabItem {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
        }
        .task {
            retryPendingExports()
            importAvailableWorkoutExportsIfRequested()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                retryPendingExports()
            }
        }
    }

    private func retryPendingExports() {
        do {
            _ = try SessionExportService.retryPendingCompletedSessionExports(modelContext: modelContext)
            if try SessionExportService.hasPendingCompletedSessionExports(modelContext: modelContext) {
                SessionExportService.scheduleBackgroundExportRetry()
            }
        } catch {
            SessionExportService.scheduleBackgroundExportRetry()
        }
    }

    private func importAvailableWorkoutExportsIfRequested() {
        guard AppRuntime.shouldImportAvailableWorkoutExports || AppRuntime.shouldPrepareAdaptiveRollout else { return }
        guard let cycle = try? modelContext.fetch(FetchDescriptor<ActiveCycleInstance>()).first else { return }
        let exports = BootstrapDataService.allExportSummaries()
        if AppRuntime.shouldPrepareAdaptiveRollout {
            _ = try? BootstrapDataService.prepareAdaptiveRollout(
                exports: exports,
                cycle: cycle,
                modelContext: modelContext
            )
        } else {
            _ = try? BootstrapDataService.reconcileWorkoutExports(
                exports,
                cycle: cycle,
                modelContext: modelContext
            )
        }
    }
}

#Preview {
    RootTabView()
}
