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

/// Display-only load–rep estimate, normalized within contiguous comparable setups.
/// Build before filtering so A → B → A never reconnects A across a profile change.
enum MovementPerformanceIndex {
    struct Point: Identifiable {
        let id: String
        let performanceID: String
        let date: Date
        let setup: MovementHistoryPerformance.Setup
        let segment: Int
        let series: String
        let setNumber: Int
        let value: Double
        let weight: Double
        let reps: Int
        let loadChanged: Bool
    }

    static func score(weight: Double, reps: Int) -> Double? {
        guard weight.isFinite, weight > 0, reps > 0 else { return nil }
        let value = weight * (1 + Double(reps) / 30)
        return value.isFinite ? value : nil
    }

    static func points(for movement: MovementHistory) -> [Point] {
        guard !movement.isGripper else { return [] }
        let history = movement.performances.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var result: [Point] = []
        var previousSetup: MovementHistoryPerformance.Setup?
        var baseline: Double?
        var previousLoad: Double?
        var segment = 0
        var lastSeen: [Int: Int] = [:]
        var runs: [Int: Int] = [:]
        for (position, performance) in history.enumerated() {
            let numbered = performance.sets.enumerated().map { ($0.element.setIndex ?? ($0.offset + 1), $0.element) }
            let firstSets = numbered.filter { $0.0 == 1 }
            let comparable = !performance.hasAmbiguousEvidence
                && (!movement.usesResistanceProfiles || performance.profile?.isComplete == true)
                && (performance.profile == nil || performance.profile?.isComplete == true)
            guard comparable, firstSets.count == 1,
                  let firstScore = score(weight: firstSets[0].1.weight, reps: firstSets[0].1.reps) else {
                previousSetup = nil; baseline = nil; previousLoad = nil
                continue
            }
            if previousSetup != performance.setup || baseline == nil {
                segment += 1
                baseline = firstScore
                previousLoad = nil
                lastSeen = [:]; runs = [:]
            }
            let counts = Dictionary(grouping: numbered, by: { $0.0 })
            for (number, set) in numbered {
                guard number > 0, counts[number]?.count == 1,
                      let score = score(weight: set.weight, reps: set.reps) else { continue }
                let value = 100 * (score / baseline!)
                guard value.isFinite else { continue }
                // A missing/invalid set position breaks only that position's line.
                if lastSeen[number] != position - 1 { runs[number, default: 0] += 1 }
                result.append(Point(id: "\(performance.id)-\(number)", performanceID: performance.id,
                    date: performance.date, setup: performance.setup, segment: segment,
                    series: "\(segment)-\(number)-\(runs[number, default: 0])", setNumber: number,
                    value: value, weight: set.weight, reps: set.reps,
                    loadChanged: number == 1 && previousLoad.map { $0 != set.weight } == true))
                lastSeen[number] = position
            }
            previousSetup = performance.setup
            previousLoad = firstSets[0].1.weight
        }
        return result
    }
}

struct MovementPerformanceChart: View {
    let points: [MovementPerformanceIndex.Point]
    private var positions: [Int] { Array(Set(points.map(\.setNumber))).sorted() }
    private var starts: [MovementPerformanceIndex.Point] {
        var seen = Set<Int>()
        return points.filter { $0.setNumber == 1 && seen.insert($0.segment).inserted }
    }
    private func color(_ number: Int) -> Color {
        let colors: [Color] = [.cyan, .purple, .orange, .green, .pink, .indigo]
        return colors[(number - 1) % colors.count]
    }
    private var summary: String {
        guard let last = points.last(where: { $0.setNumber == 1 }) else { return "" }
        let delta = last.value - 100
        return "First set: \(last.value.formatted(.number.precision(.fractionLength(1)))) · \(delta >= 0 ? "+" : "")\(delta.formatted(.number.precision(.fractionLength(1))))% this segment"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary).font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
                .accessibilityIdentifier("history.index.summary")
            Chart {
                RuleMark(y: .value("Baseline", 100))
                    .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 4]))
                ForEach(Array(starts.dropFirst())) { point in
                    RuleMark(x: .value("New segment", point.date))
                        .foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 4]))
                }
                ForEach(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Index", point.value),
                        series: .value("Set segment", point.series))
                        .foregroundStyle(color(point.setNumber).opacity(point.setNumber == 1 ? 1 : 0.65))
                        .lineStyle(StrokeStyle(lineWidth: point.setNumber == 1 ? 3 : 1.5))
                    PointMark(x: .value("Date", point.date), y: .value("Index", point.value))
                        .foregroundStyle(color(point.setNumber).opacity(point.setNumber == 1 ? 1 : 0.7))
                        .symbolSize(point.setNumber == 1 ? 40 : 20)
                        .accessibilityLabel("\(point.date.formatted(date: .abbreviated, time: .omitted)), set \(point.setNumber)")
                        .accessibilityValue("Index \(point.value.formatted(.number.precision(.fractionLength(1)))), \(point.weight.formatted()) pounds, \(point.reps) reps")
                    if point.loadChanged {
                        PointMark(x: .value("Date", point.date), y: .value("Index", point.value))
                            .symbol(.diamond).symbolSize(65).foregroundStyle(.yellow)
                            .accessibilityLabel("First-set load changed to \(point.weight.formatted()) pounds")
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("index")
            .chartXScale(range: .plotDimension(padding: 30))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()); AxisGridLine()
            } }
            .frame(height: 185)
            .accessibilityIdentifier("history.index.chart")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legend }
                VStack(alignment: .leading, spacing: 4) { legend }
            }
            Text("Load × (1 + reps ÷ 30), relative to the segment’s starting first set = 100. A trend estimate, not measured 1RM.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Setup changes reset the baseline and break the lines. Exact weights and reps are below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var legend: some View {
        ForEach(positions, id: \.self) { number in
            HStack(spacing: 5) {
                Circle().fill(color(number)).frame(width: 6, height: 6)
                Text("Set \(number)").foregroundStyle(color(number)).fixedSize()
            }.font(.caption)
        }
        HStack(spacing: 5) {
            Image(systemName: "diamond.fill").font(.system(size: 8))
            Text("Load change").fixedSize()
        }.foregroundStyle(.yellow).font(.caption)
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
    private var indexPoints: [MovementPerformanceIndex.Point] {
        let all = MovementPerformanceIndex.points(for: movement)
        guard selectedSetup >= 0, movement.setups.indices.contains(selectedSetup) else { return all }
        return all.filter { $0.setup == movement.setups[selectedSetup] }
    }

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
            Section("Estimated 1RM · performance index") {
                if !indexPoints.isEmpty {
                    MovementPerformanceChart(points: indexPoints)
                } else {
                    Text(movement.isGripper
                        ? "Gripper models are categorical. Compare the model and reps in your sets below."
                        : "No comparable index yet. A recorded positive load, first set, and known resistance setup are needed; exact sets are below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
