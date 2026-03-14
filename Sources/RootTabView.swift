import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
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
    }
}

#Preview {
    RootTabView()
}
