import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query private var setEntries: [SetEntry]
    @Query private var exercises: [Exercise]
    @Query(sort: \AdaptiveWorkoutSession.createdAt, order: .reverse) private var adaptiveSessions: [AdaptiveWorkoutSession]
    @Query private var adaptiveSetEntries: [AdaptiveSetEntry]
    @Query private var generatedPlans: [GeneratedWorkoutPlan]
    @State private var exportedSessions: [ExportedSessionSummary] = []
    @State private var searchText = ""

    private var completedSessions: [Session] {
        let candidates = sessions.filter {
            $0.status == .completed || $0.finishedAt != nil || $0.exportStatus == .success
        }

        let grouped = Dictionary(grouping: candidates, by: dedupeKey(for:))
        let deduped = grouped.compactMap { _, group -> Session? in
            group.max { lhs, rhs in
                let lhsSetCount = lockedSetCount(for: lhs.id)
                let rhsSetCount = lockedSetCount(for: rhs.id)
                if lhsSetCount != rhsSetCount {
                    return lhsSetCount < rhsSetCount
                }
                return (lhs.finishedAt ?? lhs.createdAt) < (rhs.finishedAt ?? rhs.createdAt)
            }
        }

        return deduped.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    private var completedAdaptiveSessions: [AdaptiveWorkoutSession] {
        adaptiveSessions
            .filter { $0.status == .completed && $0.finishedAt != nil }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    private var exportedBySessionId: [String: ExportedSessionSummary] {
        Dictionary(uniqueKeysWithValues: exportedSessions.map { ($0.id, $0) })
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var exerciseSearchResults: [HistoryExerciseOccurrence] {
        var results = HistoryExerciseSearchService.results(
            query: searchText,
            sessions: completedSessions,
            setEntries: setEntries,
            adaptiveSessions: completedAdaptiveSessions,
            adaptiveSetEntries: adaptiveSetEntries,
            exercises: exercises
        )
        let knownSessionIds = Set(completedSessions.map { $0.id.uuidString })
            .union(completedAdaptiveSessions.map { $0.id.uuidString })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        for exported in exportedSessions where !knownSessionIds.contains(exported.id) {
            for exercise in exported.exercises where
                exercise.exercise_name.localizedCaseInsensitiveContains(query) {
                results.append(
                    HistoryExerciseOccurrence(
                        id: "exported-\(exported.id)-\(exercise.exercise_name)",
                        date: exported.date,
                        exerciseName: exercise.exercise_name,
                        workoutName: exported.cycleName,
                        sets: exercise.sets.sorted { $0.set_index < $1.set_index }.map {
                            HistoryExerciseSet(weight: $0.weight, reps: $0.reps)
                        }
                    )
                )
            }
        }
        return results.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if hasSearchQuery {
                    if exerciseSearchResults.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        Section("Exercise History") {
                            ForEach(exerciseSearchResults) { occurrence in
                                HistoryExerciseOccurrenceView(occurrence: occurrence)
                            }
                        }
                    }
                } else if completedSessions.isEmpty && completedAdaptiveSessions.isEmpty {
                    if exportedSessions.isEmpty {
                        ContentUnavailableView(
                            "No Completed Sessions",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Finish a workout to see it in history.")
                        )
                    } else {
                        Section("Exported Workouts") {
                            ForEach(exportedSessions) { exported in
                                NavigationLink {
                                    ExportedSessionDetailView(session: exported)
                                } label: {
                                    ExportedSessionRowView(session: exported)
                                }
                            }
                        }
                    }
                } else {
                    if !completedAdaptiveSessions.isEmpty {
                        Section("Adaptive Workouts") {
                            ForEach(completedAdaptiveSessions) { session in
                                NavigationLink {
                                    AdaptiveSessionDetailView(session: session)
                                } label: {
                                    AdaptiveSessionRowView(
                                        session: session,
                                        plan: generatedPlans.first(where: { $0.id == session.generatedPlanId })
                                    )
                                }
                            }
                        }
                    }
                    if !completedSessions.isEmpty {
                        Section("Rotation & Ad Hoc") {
                            ForEach(completedSessions) { session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRowView(
                                        session: session,
                                        cycleName: cycleName(for: session),
                                        dayLabel: dayLabel(for: session),
                                        exerciseCount: exerciseCount(for: session)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search exercises")
            .task {
                _ = try? AdaptiveExportService.hydrateAvailableExports(modelContext: modelContext)
                reloadExportedSessions()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    reloadExportedSessions()
                }
            }
        }
    }

    private func cycleName(for session: Session) -> String {
        if let snapshot = session.cycleNameSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        if let exported = exportedBySessionId[session.id.uuidString] {
            return exported.cycleName
        }
        return OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func dayLabel(for session: Session) -> String {
        if let snapshot = session.dayLabelSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        if let exported = exportedBySessionId[session.id.uuidString] {
            return exported.dayLabel
        }
        return OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private func exerciseCount(for session: Session) -> Int {
        Set(setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked }.map(\.exerciseId)).count
    }

    private func reloadExportedSessions() {
        exportedSessions = ExportedSessionSummary.loadAll()
    }

    private func dedupeKey(for session: Session) -> String {
        let timestamp = Int((session.finishedAt ?? session.createdAt).timeIntervalSince1970)
        let cycle = (session.cycleNameSnapshot ?? "").lowercased()
        let day = (session.dayLabelSnapshot ?? "").lowercased()
        return "\(timestamp)|\(session.cycleDayIndex)|\(cycle)|\(day)"
    }

    private func lockedSetCount(for sessionId: UUID) -> Int {
        setEntries.filter { $0.sessionId == sessionId && $0.reps > 0 && $0.isLocked }.count
    }

}

struct HistoryExerciseSet: Equatable {
    let weight: Double
    let reps: Int
}

struct HistoryExerciseOccurrence: Identifiable, Equatable {
    let id: String
    let date: Date
    let exerciseName: String
    let workoutName: String
    let sets: [HistoryExerciseSet]
}

enum HistoryExerciseSearchService {
    static func results(
        query: String,
        sessions: [Session],
        setEntries: [SetEntry],
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        exercises: [Exercise]
    ) -> [HistoryExerciseOccurrence] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matchingExercises = exercises.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        let matchingIds = Set(matchingExercises.map(\.id))
        let namesById = Dictionary(uniqueKeysWithValues: matchingExercises.map { ($0.id, $0.name) })
        var results: [HistoryExerciseOccurrence] = []

        for session in sessions where session.status == .completed {
            let rowsByExercise = Dictionary(grouping: setEntries.filter {
                $0.sessionId == session.id
                    && matchingIds.contains($0.exerciseId)
                    && $0.isLocked
                    && $0.reps > 0
            }, by: \.exerciseId)
            for (exerciseId, rows) in rowsByExercise {
                guard let name = namesById[exerciseId] else { continue }
                results.append(
                    HistoryExerciseOccurrence(
                        id: "fixed-\(session.id.uuidString)-\(exerciseId.uuidString)",
                        date: session.finishedAt ?? session.createdAt,
                        exerciseName: name,
                        workoutName: session.cycleNameSnapshot ?? session.dayLabelSnapshot ?? "Rotation",
                        sets: rows.sorted { $0.setIndex < $1.setIndex }.map {
                            HistoryExerciseSet(weight: $0.weight, reps: $0.reps)
                        }
                    )
                )
            }
        }

        for session in adaptiveSessions where session.status == .completed {
            let rowsByExercise = Dictionary(grouping: adaptiveSetEntries.filter {
                $0.adaptiveSessionId == session.id
                    && matchingIds.contains($0.exerciseId)
                    && $0.isLocked
                    && $0.reps > 0
            }, by: \.exerciseId)
            for (exerciseId, rows) in rowsByExercise {
                guard let name = namesById[exerciseId] else { continue }
                results.append(
                    HistoryExerciseOccurrence(
                        id: "adaptive-\(session.id.uuidString)-\(exerciseId.uuidString)",
                        date: session.finishedAt ?? session.createdAt,
                        exerciseName: name,
                        workoutName: "Adaptive Floating",
                        sets: rows.sorted {
                            if $0.occurrenceId != $1.occurrenceId {
                                return $0.occurrenceId.uuidString < $1.occurrenceId.uuidString
                            }
                            return $0.setIndex < $1.setIndex
                        }.map {
                            HistoryExerciseSet(weight: $0.weight, reps: $0.reps)
                        }
                    )
                )
            }
        }

        return results.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }
}

private struct HistoryExerciseOccurrenceView: View {
    let occurrence: HistoryExerciseOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(occurrence.exerciseName)
                    .font(.headline)
                Spacer()
                Text(occurrence.date, style: .date)
                    .font(.subheadline)
            }
            Text(occurrence.workoutName)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(occurrence.sets.enumerated()), id: \.offset) { index, set in
                HStack {
                    Text("Set \(index + 1)")
                    Spacer()
                    Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) × \(set.reps)")
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SessionRowView: View {
    let session: Session
    let cycleName: String
    let dayLabel: String
    let exerciseCount: Int

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.finishedAt ?? session.createdAt, style: .date)
                    .font(.headline)
                Text(cycleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(exerciseCount) exercises")
                    .font(.caption)
                if session.exportStatus != .success {
                    Text(session.exportStatus.displayName)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct AdaptiveSessionRowView: View {
    let session: AdaptiveWorkoutSession
    let plan: GeneratedWorkoutPlan?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.finishedAt ?? session.createdAt, style: .date)
                    .font(.headline)
                let exerciseCount = plan?.complexes.reduce(0, { $0 + $1.exercises.count }) ?? 0
                Text("\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.exportStatus != .success {
                Text(session.exportStatus.displayName)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct AdaptiveSessionDetailView: View {
    @Query private var plans: [GeneratedWorkoutPlan]
    @Query private var sessions: [AdaptiveWorkoutSession]
    @Query private var setEntries: [AdaptiveSetEntry]
    @Query private var exercises: [Exercise]
    @Query private var feedback: [ComplexFeedback]
    @Query private var overrides: [AdaptiveOverrideEvent]
    @Query private var exportDiagnostics: [ExportDiagnostic]

    let session: AdaptiveWorkoutSession

    private var plan: GeneratedWorkoutPlan? {
        plans.first(where: { $0.id == session.generatedPlanId })
    }

    private var exportDiagnostic: ExportDiagnostic? {
        exportDiagnostics.first { $0.sessionId == session.id && $0.sessionKind == .adaptive }
    }

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Date") { Text(session.finishedAt ?? session.createdAt, style: .date) }
                LabeledContent("Workout kind", value: "Adaptive")
                LabeledContent("Export status", value: session.exportStatus.displayName)
                if let exportDiagnostic {
                    Text(exportDiagnostic.detail)
                        .font(.caption)
                        .foregroundStyle(exportDiagnostic.status == .failed ? .red : .secondary)
                    LabeledContent("File", value: exportDiagnostic.filename)
                }
            }

            if let plan {
                ForEach(plan.complexes.sorted(by: { $0.position < $1.position })) { complex in
                    Section {
                        ForEach(complex.exercises.sorted(by: { $0.position < $1.position })) { snapshot in
                            let rows = entries(for: snapshot, session: session)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(exercises.first(where: { $0.id == rows.first?.exerciseId })?.name ?? snapshot.exerciseName)
                                    .font(.headline)
                                ForEach(rows) { row in
                                    Text("Set \(row.setIndex): \(WeightFormatting.normalized(row.weight), format: WeightFormatting.style) x \(row.reps)")
                                        .foregroundStyle(.secondary)
                                }
                                let comparison = comparisonFor(snapshot: snapshot, complex: complex)
                                Text(comparison.label.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !comparison.previous.isEmpty {
                                    Text("Previous: \(formatted(comparison.previous))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Current: \(formatted(comparison.current))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        let savedRating = feedback
                            .filter { $0.generatedPlanId == plan.id && $0.plannedComplexId == complex.id }
                            .max(by: { $0.createdAt < $1.createdAt })?.rating
                        if let rating = savedRating {
                            LabeledContent("Volume feedback", value: rating.displayName)
                        } else {
                            LabeledContent("Volume feedback", value: "Missing")
                        }
                    } header: {
                        Text(complex.name)
                    }
                }
            }
        }
        .navigationTitle("Adaptive Session")
    }

    private func entries(
        for snapshot: PlannedExerciseSnapshot,
        session: AdaptiveWorkoutSession
    ) -> [AdaptiveSetEntry] {
        setEntries
            .filter {
                $0.adaptiveSessionId == session.id
                    && $0.occurrenceId == snapshot.occurrenceId
                    && $0.isLocked
                    && $0.reps > 0
            }
            .sorted { $0.setIndex < $1.setIndex }
    }

    private func comparisonFor(
        snapshot: PlannedExerciseSnapshot,
        complex: PlannedComplexSnapshot
    ) -> RepeatPerformanceResult {
        let currentRows = entries(for: snapshot, session: session)
        let current = PerformanceOccurrence(
            exerciseId: currentRows.first?.exerciseId ?? snapshot.exerciseId,
            complexDefinitionId: complex.sourceDefinitionId,
            componentPosition: snapshot.position,
            isCompleted: session.status == .completed,
            isSubstitution: isSubstitution(planId: session.generatedPlanId, occurrenceId: snapshot.occurrenceId),
            sets: currentRows.map { .init(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps, isLocked: $0.isLocked) }
        )
        let priorCandidates = sessions
            .filter { $0.status == .completed && ($0.finishedAt ?? $0.createdAt) < (session.finishedAt ?? session.createdAt) }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        for priorSession in priorCandidates {
            guard let priorPlan = plans.first(where: { $0.id == priorSession.generatedPlanId }),
                  let priorComplex = priorPlan.complexes.first(where: { $0.sourceDefinitionId == complex.sourceDefinitionId }),
                  let priorSnapshot = priorComplex.exercises.first(where: { $0.position == snapshot.position }),
                  priorSnapshot.exerciseId == snapshot.exerciseId else { continue }
            let rows = entries(for: priorSnapshot, session: priorSession)
            let previous = PerformanceOccurrence(
                exerciseId: rows.first?.exerciseId ?? priorSnapshot.exerciseId,
                complexDefinitionId: priorComplex.sourceDefinitionId,
                componentPosition: priorSnapshot.position,
                isCompleted: true,
                isSubstitution: isSubstitution(planId: priorPlan.id, occurrenceId: priorSnapshot.occurrenceId),
                sets: rows.map { .init(setIndex: $0.setIndex, weight: $0.weight, reps: $0.reps, isLocked: $0.isLocked) }
            )
            return RepeatPerformanceService.compare(previous: previous, current: current)
        }
        return RepeatPerformanceService.compare(previous: nil, current: current)
    }

    private func isSubstitution(planId: UUID, occurrenceId: UUID) -> Bool {
        overrides.contains {
            $0.generatedPlanId == planId
                && $0.occurrenceId == occurrenceId
                && $0.kind == .substituteExercise
        }
    }

    private func formatted(_ rows: [ComparableSetRow]) -> String {
        rows.map { "\(WeightFormatting.normalized($0.weight)) x \($0.reps)" }.joined(separator: ", ")
    }
}

private struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var exercises: [Exercise]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var templates: [CycleTemplate]
    @Query private var setEntries: [SetEntry]
    @Query private var adHocFeedback: [AdHocExerciseFeedback]
    @Query private var exportDiagnostics: [ExportDiagnostic]

    let session: Session
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Date") {
                    Text(session.finishedAt ?? session.createdAt, style: .date)
                }
                LabeledContent("Cycle") {
                    Text(cycleName)
                }
                LabeledContent("Day") {
                    Text(dayLabel)
                }
                LabeledContent("Export Status") {
                    Text(session.exportStatus.displayName)
                }
                if let exportDiagnostic {
                    Text(exportDiagnostic.detail)
                        .font(.caption)
                        .foregroundStyle(exportDiagnostic.status == .failed ? .red : .secondary)
                    LabeledContent("File", value: exportDiagnostic.filename)
                }
            }

            ForEach(groupedExercises, id: \.exercise.id) { group in
                Section(group.exercise.name) {
                    ForEach(group.sets) { set in
                        HStack {
                            Text("Set \(set.setIndex)")
                            Spacer()
                            Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) x \(set.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let rating = feedbackRating(for: group.exercise.id) {
                        LabeledContent("Volume feedback", value: rating.displayName)
                    }
                }
            }

            if session.exportStatus != .success {
                Section {
                    Button("Retry Export") {
                        retryExport()
                    }
                }
            }
        }
        .navigationTitle("Session Detail")
        .alert("Export Error", isPresented: .constant(exportError != nil), actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "Unknown error")
        })
    }

    private var cycleName: String {
        OpenLiftStateResolver.cycleName(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private var exportDiagnostic: ExportDiagnostic? {
        exportDiagnostics.first { $0.sessionId == session.id && $0.sessionKind == .fixed }
    }

    private var dayLabel: String {
        OpenLiftStateResolver.dayLabel(
            for: session,
            activeCycles: activeCycles,
            templates: templates
        )
    }

    private var groupedExercises: [(exercise: Exercise, sets: [SetEntry])] {
        let sessionSets = setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked }
        let grouped = Dictionary(grouping: sessionSets, by: { $0.exerciseId })
        return grouped.compactMap { exerciseId, sets in
            guard let exercise = exercises.first(where: { $0.id == exerciseId }) else { return nil }
            return (exercise: exercise, sets: sets.sorted { $0.setIndex < $1.setIndex })
        }
        .sorted { $0.exercise.name < $1.exercise.name }
    }

    private func feedbackRating(for exerciseId: UUID) -> ComplexFeedbackRating? {
        adHocFeedback
            .filter { $0.sessionId == session.id && $0.exerciseId == exerciseId }
            .max(by: { $0.createdAt < $1.createdAt })?
            .rating
    }

    private func retryExport() {
        do {
            _ = try SessionExportService.exportAndTrack(
                session: session,
                cycleName: cycleName,
                exercises: exercises,
                setEntries: setEntries.filter { $0.sessionId == session.id && $0.reps > 0 && $0.isLocked },
                requireICloudMirror: true,
                modelContext: modelContext
            )
            try modelContext.save()
        } catch {
            session.exportStatus = .failed
            exportError = error.localizedDescription
        }
    }
}

#Preview {
    HistoryView()
}

private struct ExportedSessionSummary: Identifiable {
    let id: String
    let date: Date
    let cycleName: String
    let cycleDayIndex: Int
    let exerciseCount: Int
    let exercises: [SessionExportService.ExportExercise]

    var dayLabel: String {
        "Day \(cycleDayIndex + 1)"
    }

    static func loadAll() -> [ExportedSessionSummary] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        if let iCloudRoot = SessionExportService.iCloudContainerURL()?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(iCloudRoot)
        }

        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenLift/exports", isDirectory: true) {
            directories.append(docs)
        }

        var results: [ExportedSessionSummary] = []

        for dir in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in urls where fileURL.pathExtension == "json" && fileURL.lastPathComponent.hasPrefix("workout-") {
                guard let data = try? Data(contentsOf: fileURL),
                      let payload = SessionExportService.decodeExportPayload(data: data, fileURL: fileURL),
                      let date = SessionExportService.parseExportDate(payload.date) else { continue }

                results.append(
                    ExportedSessionSummary(
                        id: payload.session_id,
                        date: date,
                        cycleName: payload.cycle_name,
                        cycleDayIndex: payload.cycle_day_index,
                        exerciseCount: payload.exercises.count,
                        exercises: payload.exercises
                    )
                )
            }
        }

        // Keep newest unique sessions if file mirrors exist in iCloud and local docs.
        let deduped = Dictionary(grouping: results, by: \.id).compactMap { _, grouped in
            grouped.max(by: { $0.date < $1.date })
        }

        return deduped.sorted { $0.date > $1.date }
    }
}

private struct ExportedSessionRowView: View {
    let session: ExportedSessionSummary

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date, style: .date)
                    .font(.headline)
                Text(session.cycleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(session.dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(session.exerciseCount) exercises")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExportedSessionDetailView: View {
    let session: ExportedSessionSummary

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Date") {
                    Text(session.date, style: .date)
                }
                LabeledContent("Cycle") {
                    Text(session.cycleName)
                }
                LabeledContent("Day") {
                    Text(session.dayLabel)
                }
            }

            ForEach(session.exercises, id: \.exercise_name) { exercise in
                Section(exercise.exercise_name) {
                    ForEach(exercise.sets, id: \.set_index) { set in
                        HStack {
                            Text("Set \(set.set_index)")
                            Spacer()
                            Text("\(WeightFormatting.normalized(set.weight), format: WeightFormatting.style) x \(set.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let raw = exercise.volume_feedback,
                       let rating = ComplexFeedbackRating(rawValue: raw) {
                        LabeledContent("Volume feedback", value: rating.displayName)
                    }
                }
            }
        }
        .navigationTitle("Session Detail")
    }
}
