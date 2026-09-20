import SwiftUI
import UIKit
import SwiftData

/// Opt-in simulator diagnostic: dispatch-to-main delay while a numeric field is
/// focused. It measures main-thread availability, not physical keyboard latency.
struct InputResponsivenessProbe: ViewModifier {
    @StateObject private var probe = Probe()
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if AppRuntime.isUITesting && ProcessInfo.processInfo.environment["OPENLIFT_INPUT_PROBE"] == "1" {
                Text(probe.report).font(.system(size: 1)).accessibilityIdentifier("input.probe")
                    .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in probe.start() }
                    .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in probe.stop() }
            }
        }
    }

    @MainActor private final class Probe: ObservableObject {
        @Published var report = "Waiting"
        private var timer: DispatchSourceTimer?
        private var samples: [Double] = []
        private var active = false
        func start() {
            guard !active else { return }
            active = true
            samples = []
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.setEventHandler { [weak self] in
                let scheduled = CACurrentMediaTime()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.samples.append((CACurrentMediaTime() - scheduled) * 1000)
                }
            }
            self.timer = timer
            timer.resume()
        }
        func stop() {
            active = false
            timer?.cancel(); timer = nil
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return }
            report = String(format: "samples=%d p95=%.2fms max=%.2fms over16=%d", sorted.count, sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!, sorted.filter { $0 > 16.7 }.count)
        }
    }
}

@MainActor
enum WorkoutInputUITestFixture {
    static func seed(in context: ModelContext) throws {
        let exercises = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let template = try BootstrapDataService.ensureDefaultStarterTemplateIfNeeded(
            modelContext: context, existingTemplates: [], exercises: exercises)!
        let exercise = exercises.first { $0.name == "Flat DB Press" }!
        let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let session = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0,
            cycleNameSnapshot: template.name, dayLabelSnapshot: "Upper A", createdAt: yesterday,
            finishedAt: yesterday, status: .completed)
        context.insert(cycle); context.insert(session)
        for index in 1...3 {
            context.insert(SetEntry(sessionId: session.id, exerciseId: exercise.id,
                setIndex: index, weight: 45, reps: 9, isLocked: true))
        }
        if ProcessInfo.processInfo.environment["OPENLIFT_INPUT_EXISTING_DRAFT_UI"] == "1" {
            let draft = Session(cycleInstanceId: cycle.id, cycleDayIndex: 0)
            context.insert(draft)
            context.insert(SetEntry(sessionId: draft.id, exerciseId: exercise.id, setIndex: 1, weight: 47.5, reps: 11))
        }
        try context.save()
    }
}
