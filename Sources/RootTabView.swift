import SwiftUI
import SwiftData

struct RootTabView: View {
    private enum Tab: Hashable {
        case log, workout, history, cycle
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .workout

    var body: some View {
        TabView(selection: $selectedTab) {
            LogWorkoutView()
                .tabItem {
                    Label("Log", systemImage: "plus.circle")
                }
                .tag(Tab.log)

            WorkoutView()
                .tabItem {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }
                .tag(Tab.workout)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(Tab.history)

            CycleView()
                .tabItem {
                    Label("Cycle", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(Tab.cycle)

        }
        .task {
            _ = try? BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
            _ = try? AdaptiveProgramService.normalizeLegacyDemoLabels(modelContext: modelContext)
            _ = try? AdaptiveProgramService.ensureWorkoutSizePreferences(modelContext: modelContext)
            _ = try? AdaptiveProgramService.ensurePlanDesignStates(modelContext: modelContext)
            _ = try? AdaptiveProgramService.normalizeOpenPlanExerciseCategories(
                modelContext: modelContext
            )
            if AppRuntime.shouldDisableGluteProgramming {
                do {
                    let changed = try AdaptiveProgramService.disableMuscleProgramming(
                        .glutes,
                        modelContext: modelContext
                    )
                    print("OPENLIFT_DISABLE_GLUTE_PROGRAMMING_RESULT changes=\(changed)")
                } catch {
                    print("OPENLIFT_DISABLE_GLUTE_PROGRAMMING_FAILED")
                }
            }
            _ = try? AdaptiveExerciseSelectionPreferenceService.ensureRequestedDefaults(
                modelContext: modelContext
            )
            retryPendingExports()
            importAvailableWorkoutExportsIfRequested()
            _ = try? AdaptiveVolumeControllerService.ensureStoredConfiguration(
                modelContext: modelContext
            )
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
