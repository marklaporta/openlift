import SwiftUI
import Charts
import SwiftData

struct MovementHistoryPerformance: Identifiable {
    let id: String
    let sessionID: String
    let date: Date
    let exerciseID: UUID?
    let name: String
    let workout: String
    let context: String
    let progressionKey: String?
    let profile: ResistanceProfileValue?
    let sets: [HistoryExerciseSet]
    var hasAmbiguousEvidence = false

    struct Setup: Hashable {
        let progressionKey: String?
        let profile: ResistanceProfileValue?
        let ambiguousOccurrence: String?
    }
    var setup: Setup { Setup(progressionKey: progressionKey, profile: profile, ambiguousOccurrence: hasAmbiguousEvidence ? id : nil) }
}

struct MovementHistory: Identifiable {
    let id: String
    let exerciseID: UUID?
    let name: String
    let searchNames: [String]
    let usesResistanceProfiles: Bool
    let performances: [MovementHistoryPerformance]
    var workoutCount: Int { Set(performances.map(\.sessionID)).count }
    var isGripper: Bool { GripperLoadPresentation.applies(exerciseId: exerciseID, name: name) }
    var setups: [MovementHistoryPerformance.Setup] {
        var seen = Set<MovementHistoryPerformance.Setup>()
        return performances.map(\.setup).filter { seen.insert($0).inserted }
    }
}

enum MovementHistoryService {
    /// Read-only projection. A clustered completion requires performed snapshot evidence;
    /// legacy sessions without that metadata retain their locked, positive-rep rows.
    static func movements(
        sessions: [Session], setEntries: [SetEntry],
        adaptiveSessions: [AdaptiveWorkoutSession], adaptiveSetEntries: [AdaptiveSetEntry],
        exercises: [Exercise], occurrences: [ClusterOccurrenceRecord] = [],
        profiles: [ExerciseResistanceProfile] = [], exports: [ExportedSessionSummary] = []
    ) -> [MovementHistory] {
        let catalog = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fixedRows = Dictionary(grouping: setEntries.filter { $0.isLocked && $0.reps > 0 }, by: \.sessionId)
        let adaptiveRows = Dictionary(grouping: adaptiveSetEntries.filter { $0.isLocked && $0.reps > 0 }, by: \.adaptiveSessionId)
        let snapshots = Dictionary(grouping: occurrences, by: \.sessionId)
        var performances: [MovementHistoryPerformance] = []
        func profile(_ session: UUID, _ exercise: UUID, _ occurrence: UUID? = nil) -> ResistanceProfileValue? {
            let matches = profiles.filter { $0.sessionId == session && $0.exerciseId == exercise && $0.occurrenceId == occurrence }
            // Ambiguous profiles must never become an arbitrary comparison setup.
            let values = Set(matches.compactMap { ResistanceProfileService.value($0) })
            return values.count == 1 ? values.first : nil
        }
        for entry in HistoryTimelineService.entries(sessions: sessions.filter {
            $0.status == .completed || $0.finishedAt != nil || $0.exportStatus == .success
        }, adaptiveSessions: adaptiveSessions.filter { $0.status == .completed }, exports: exports) {
            switch entry {
            case .rotation(let session):
                let groups = Dictionary(grouping: fixedRows[session.id] ?? [], by: \.exerciseId)
                let records = snapshots[session.id] ?? []
                for (exerciseID, rows) in groups {
                    let evidence = records.flatMap { record in record.exerciseSnapshots.map { (record, $0) } }
                        .filter { $0.1.exerciseId == exerciseID && $0.1.completionStatus == .performed }
                    // No fallback from a skipped/unbacked clustered row into legacy history.
                    guard records.isEmpty || !evidence.isEmpty else { continue }
                    // Fixed sets have only session + exercise identity. Do not duplicate the
                    // same rows if malformed evidence associates them with several snapshots.
                    let snapshot = evidence.count == 1 ? evidence.first : nil
                    let name = snapshot?.1.exerciseName ?? catalog[exerciseID]?.name ?? "Unknown movement"
                    performances.append(.init(id: "\(entry.id)-\(exerciseID)", sessionID: entry.id, date: entry.date,
                        exerciseID: exerciseID, name: name,
                        workout: session.cycleNameSnapshot ?? "Workout",
                        context: evidence.count > 1 ? "Mixed progression tracks" : (snapshot?.0.dayLabel ?? session.dayLabelSnapshot ?? "Workout"),
                        progressionKey: snapshot?.1.progressionKey,
                        profile: evidence.count > 1 ? nil : (snapshot.map { $0.1.resistanceProfile } ?? profile(session.id, exerciseID)),
                        sets: rows.sorted { $0.setIndex < $1.setIndex }.map { .init(weight: $0.weight, reps: $0.reps, setIndex: $0.setIndex) },
                        hasAmbiguousEvidence: evidence.count > 1))
                }
            case .adaptive(let session):
                let groups = Dictionary(grouping: adaptiveRows[session.id] ?? [], by: \.occurrenceId)
                for (occurrenceID, rows) in groups {
                    for (exerciseID, exerciseRows) in Dictionary(grouping: rows, by: \.exerciseId) {
                        performances.append(.init(id: "\(entry.id)-\(occurrenceID)-\(exerciseID)", sessionID: entry.id, date: entry.date,
                            exerciseID: exerciseID, name: catalog[exerciseID]?.name ?? "Unknown movement",
                            workout: "Adaptive Floating", context: "Adaptive",
                            progressionKey: nil, profile: profile(session.id, exerciseID, occurrenceID),
                            sets: exerciseRows.sorted { $0.setIndex < $1.setIndex }.map { .init(weight: $0.weight, reps: $0.reps, setIndex: $0.setIndex) }))
                    }
                }
            case .exported(let session):
                for (index, exercise) in session.exercises.enumerated() {
                    let rows = exercise.sets.filter { $0.reps > 0 }.sorted { $0.set_index < $1.set_index }
                    guard !rows.isEmpty else { continue }
                    let evidence = (session.clusterOccurrences ?? []).flatMap(\.exercises).filter {
                        $0.exercise_id.lowercased() == exercise.exercise_id?.lowercased()
                            && $0.completion_status == ClusterExerciseCompletionStatus.performed.rawValue
                    }
                    guard session.clusterOccurrences?.isEmpty != false || !evidence.isEmpty else { continue }
                    let snapshot = evidence.count == 1 ? evidence.first : nil
                    performances.append(.init(id: "\(entry.id)-\(index)", sessionID: entry.id, date: entry.date,
                        exerciseID: exercise.exercise_id.flatMap(UUID.init(uuidString:)), name: exercise.exercise_name,
                        workout: session.cycleName, context: evidence.count > 1 ? "Mixed progression tracks" : session.dayLabel,
                        progressionKey: snapshot?.progression_key,
                        profile: evidence.count > 1 ? nil : (snapshot.map { $0.resistance_profile?.value } ?? exercise.resistance_profile?.value),
                        sets: rows.map { .init(weight: $0.weight, reps: $0.reps, setIndex: $0.set_index) },
                        hasAmbiguousEvidence: evidence.count > 1))
                }
            }
        }
        func canonical(_ performance: MovementHistoryPerformance) -> Exercise? {
            if let id = performance.exerciseID,
               id != CSDBRowIdentity.canonicalID && !CSDBRowIdentity.legacyIDs.contains(id) { return nil }
            return CSDBRowIdentity.resolve(id: performance.exerciseID, name: performance.name, exercises: exercises)
        }
        func identity(_ performance: MovementHistoryPerformance) -> String {
            if let canonical = canonical(performance) {
                return canonical.id.uuidString
            }
            // Do not conflate equal labels belonging to distinct durable exercise IDs.
            return performance.exerciseID?.uuidString
                ?? CompactExerciseName.resolve(performance.name, in: exercises)?.id.uuidString
                ?? "name:\(performance.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        }
        return Dictionary(grouping: performances, by: identity).map { id, history in
            let sorted = history.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            let latest = sorted[0]
            let canonical = canonical(latest)
            let resolvedID = UUID(uuidString: id) ?? latest.exerciseID
            let name = canonical?.name ?? resolvedID.flatMap { catalog[$0]?.name } ?? latest.name
            let aliases = canonical == nil ? [] : CSDBRowIdentity.names
            return MovementHistory(id: id, exerciseID: canonical?.id ?? resolvedID, name: name,
                searchNames: Array(Set(history.map(\.name) + [name] + aliases)),
                usesResistanceProfiles: resolvedID.flatMap { catalog[$0]?.equipment.supportsResistanceProfile } ?? history.contains(where: { $0.profile != nil }),
                performances: sorted)
        }.sorted { $0.performances[0].date == $1.performances[0].date
            ? nameOrder($0, $1) : $0.performances[0].date > $1.performances[0].date }
    }

    private static func nameOrder(_ lhs: MovementHistory, _ rhs: MovementHistory) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    static func matching(_ movements: [MovementHistory], query: String, alphabetical: Bool = false) -> [MovementHistory] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = movements.filter { movement in
            terms.allSatisfy { term in movement.searchNames.contains {
                $0.localizedStandardContains(term) || CompactExerciseName.expanded($0).localizedStandardContains(CompactExerciseName.expanded(term))
            } }
        }
        return alphabetical ? filtered.sorted(by: nameOrder) : filtered
    }
}

struct MovementHistoryRow: View {
    let movement: MovementHistory
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(movement.name).font(.headline)
            if let latest = movement.performances.first {
                Text(latest.sets.map { GripperLoadPresentation.set($0.weight, reps: $0.reps,
                    exerciseId: movement.exerciseID, name: movement.name) }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text("\(movement.workoutCount) workout\(movement.workoutCount == 1 ? "" : "s")")
                    Spacer()
                    Text(latest.date, format: .dateTime.month(.abbreviated).day())
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct MovementHistoryDetailView: View {
    let movement: MovementHistory
    @State private var selectedSetup = 0
    @State private var showReps = false

    private var performances: [MovementHistoryPerformance] {
        if selectedSetup < 0 { return movement.performances }
        guard movement.setups.indices.contains(selectedSetup) else { return [] }
        return movement.performances.filter { $0.setup == movement.setups[selectedSetup] }
    }
    private func setupLabel(_ index: Int) -> String {
        let setup = movement.setups[index]
        let performance = movement.performances.first { $0.setup == setup }!
        let prefix = movement.setups.count > 1 ? "\(index + 1). " : ""
        return prefix + performance.context + (setup.profile.map { " · " + $0.displayName }
            ?? (movement.usesResistanceProfiles ? " · Settings not recorded" : ""))
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(movement.name).font(.title2.bold())
                    Text("\(movement.workoutCount) workouts · \(movement.performances.reduce(0) { $0 + $1.sets.count }) sets")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                if movement.setups.count > 1 {
                    Picker("Setup", selection: $selectedSetup) {
                        Text("All setups").tag(-1)
                        ForEach(movement.setups.indices, id: \.self) { index in Text(setupLabel(index)).tag(index) }
                    }.accessibilityIdentifier("history.setup")
                    Text("Showing the latest setup first. Different progression tracks and resistance settings stay separate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let profile = performances.first?.profile {
                    Text(profile.displayName).font(.subheadline).foregroundStyle(.secondary)
                } else if movement.usesResistanceProfiles {
                    Text("Resistance settings not recorded").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !movement.isGripper && selectedSetup >= 0 && performances.count > 1 {
                Section {
                    Picker("Measure", selection: $showReps) {
                        Text("Weight").tag(false)
                        Text("Reps").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("history.measure")
                    Chart {
                        ForEach(performances.reversed()) { performance in
                            ForEach(Array(performance.sets.enumerated()), id: \.offset) { _, set in
                                PointMark(x: .value("Workout", performance.date),
                                    y: .value(showReps ? "Reps" : "Weight (lb)", showReps ? Double(set.reps) : set.weight))
                                    .foregroundStyle(Color.accentColor.opacity(0.75))
                                    .accessibilityLabel(performance.date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue("\(set.weight.formatted()) pounds, \(set.reps) reps")
                            }
                        }
                    }
                    .chartYAxisLabel(showReps ? "reps" : "lb")
                    .chartXScale(range: .plotDimension(padding: 30))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()); AxisGridLine() } }
                    .frame(height: 170)
                    Text("Each dot is a completed set. Exact weights and reps are below.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Progression") }
            }
            Section("Performances · newest first") {
                ForEach(performances) { performance in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(performance.date, format: .dateTime.month(.abbreviated).day().year()).font(.headline)
                            Spacer()
                            Text("\(performance.sets.count) sets").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(performance.workout + " · " + performance.context)
                            .font(.caption).foregroundStyle(.secondary)
                        if selectedSetup < 0, let index = movement.setups.firstIndex(of: performance.setup) {
                            Text(setupLabel(index)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(performance.sets.enumerated()), id: \.offset) { index, set in
                            HStack {
                                Text("Set \(set.setIndex ?? (index + 1))").foregroundStyle(.secondary)
                                Spacer()
                                Text(GripperLoadPresentation.set(set.weight, reps: set.reps,
                                    exerciseId: movement.exerciseID, name: movement.name))
                                    .monospacedDigit().fontWeight(.medium)
                            }.font(.subheadline)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Movement History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
@MainActor
enum MovementHistoryUITestFixture {
    static func seed(in context: ModelContext) throws {
        let catalog = try BootstrapDataService.ensureExerciseCatalog(modelContext: context)
        let press = catalog.first { $0.name == "Flat DB Press" }!
        let curl = catalog.first { $0.name == "Incline Curl" }!
        let cycleID = UUID()
        for index in 0..<4 {
            let date = Calendar.current.date(byAdding: .day, value: -(index * 3 + 1), to: .now)!
            let session = Session(cycleInstanceId: cycleID, cycleDayIndex: 0, cycleNameSnapshot: "Strength Training",
                dayLabelSnapshot: "Upper Body", createdAt: date, finishedAt: date, status: .completed, exportStatus: .success)
            context.insert(session)
            context.insert(try ClusterOccurrenceRecord(sessionId: session.id, cycleInstanceId: cycleID,
                templateId: UUID(), programVersionID: "fixture", clusterID: "cluster-1", absoluteStep: index,
                templateDayPosition: 0, dayLabel: index == 3 ? "Earlier setup" : "Upper Body",
                completedAt: date, exerciseSnapshots: [press, curl].map { exercise in
                    .init(position: exercise.id == press.id ? 0 : 1, exerciseId: exercise.id,
                        exerciseName: exercise.name, muscle: exercise.primaryMuscle, prescribedSetCount: 3,
                        progressionKey: exercise.id.uuidString + (index == 3 && exercise.id == press.id ? "-earlier" : "-current"),
                        resistanceProfile: nil, completionStatus: .performed)
                }))
            for (exercise, base) in [(press, 50.0), (curl, 25.0)] {
                for set in 1...3 {
                    context.insert(SetEntry(sessionId: session.id, exerciseId: exercise.id, setIndex: set,
                        weight: base - Double(index) * 2.5, reps: 13 - set + index, isLocked: true))
                }
            }
        }
        try context.save()
    }
}
#endif
