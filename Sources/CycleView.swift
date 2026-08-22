import SwiftUI
import SwiftData
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct CycleView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var templates: [CycleTemplate]
    @Query private var activeCycles: [ActiveCycleInstance]
    @Query private var sessions: [Session]
    @Query private var setEntries: [SetEntry]
    @Query private var clusterPointers: [FixedCycleClusterPointer]
    @Query private var fixedCycleSessionContexts: [FixedCycleSessionContext]
    @Query private var progressionOccurrences: [FixedCycleProgressionOccurrence]
    @Query private var trainingPreferences: [TrainingPreference]
    @Query private var adaptivePrograms: [AdaptiveProgram]
    @Query private var workoutSizePreferences: [AdaptiveWorkoutSizePreference]
    @Query private var capacityPreferences: [AdaptiveWorkoutCapacityPreference]

    @State private var presentingNewTemplate = false
    @State private var editingTemplate: CycleTemplate?
    @State private var errorMessage: String?
    @State private var pendingMutation: PendingCycleMutation?
    @State private var publishedCycles: [PublishedCycleFile] = []
    @State private var refreshTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    @State private var debugTapCount: Int = 0
    @State private var debugUnlocked: Bool = false
    @State private var debugSnapshotText: String?
    @State private var presentingNewAdaptiveProgram = false
    @State private var editingAdaptiveProgram: AdaptiveProgram?
    @State private var presentingExerciseSelection = false

    private var activeTemplate: CycleTemplate? {
        OpenLiftStateResolver.activeTemplate(
            activeCycles: activeCycles,
            templates: templates,
            sessions: sessions,
            latestExport: nil,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:))
        )
    }

    private var trainingMode: TrainingMode {
        TrainingModeService.resolvedMode(preferences: trainingPreferences)
    }

    private var activeAdaptiveProgram: AdaptiveProgram? {
        AdaptiveProgramService.activeProgram(from: adaptivePrograms)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Programming", selection: trainingModeBinding) {
                        ForEach(TrainingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Training Mode")
                }

                if trainingMode == .adaptive {
                    adaptiveProgrammingSections
                } else {

                Section {
                    if let activeTemplate {
                        Text(activeTemplate.name)
                    } else {
                        Text("No active cycle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Active Cycle")
                }
                .onTapGesture {
                    debugTapCount += 1
                    if debugTapCount >= 7 {
                        debugUnlocked = true
                        debugTapCount = 0
                    }
                }

                Section("Templates") {
                    if templates.isEmpty {
                        Text("No templates yet")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(templates, id: \.id) { template in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(template.name)
                                    .font(.headline)
                                Spacer()
                                if activeTemplate?.id == template.id {
                                    Text("Active")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.green.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }

                            Text("\(template.days.count) day(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Edit") {
                                    editingTemplate = template
                                }
                                .buttonStyle(.bordered)
                                .disabled(FixedCycleClusterProgramService.isProgramTemplate(template))

                                Button("Clone") {
                                    pendingMutation = .clone(templateId: template.id, name: template.name)
                                }
                                .buttonStyle(.bordered)
                                .disabled(FixedCycleClusterProgramService.isProgramTemplate(template))

                                Button("Activate") {
                                    pendingMutation = .activate(templateId: template.id, name: template.name)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteTemplates)
                }

                Section("Published Cycles (iCloud)") {
                    if publishedCycles.isEmpty {
                        Text("No published cycles")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(publishedCycles) { published in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(published.name)
                                .font(.headline)
                            if let modifiedAt = published.modifiedAt {
                                Text(modifiedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Button("Import") {
                                    pendingMutation = .importCycle(published, activateAfterImport: false)
                                }
                                .buttonStyle(.bordered)

                                Button("Import + Activate") {
                                    pendingMutation = .importCycle(published, activateAfterImport: true)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                }

#if DEBUG
                if debugUnlocked {
                    Section("Debug") {
                        Button("Copy Bootstrap Snapshot") {
                            let snapshot = BootstrapDataService.buildDebugSnapshot(
                                exercises: exercises,
                                templates: templates,
                                activeCycles: activeCycles,
                                sessions: sessions,
                                latestExportCycleDayIndex: BootstrapDataService.latestExportSummary()?.cycle_day_index
                            )
                            debugSnapshotText = snapshot.summary
#if canImport(UIKit)
                            UIPasteboard.general.string = snapshot.summary
#endif
                        }
                        if let debugSnapshotText {
                            Text(debugSnapshotText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
#endif
            }
            .navigationTitle("Cycle")
            .toolbar {
                if trainingMode == .rotation {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Refresh") {
                            reloadPublishedCycles(surfacingErrors: true)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if trainingMode == .adaptive {
                            presentingNewAdaptiveProgram = true
                        } else {
                            presentingNewTemplate = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(trainingMode == .adaptive ? "New Adaptive Profile" : "New Cycle Template")
                }
            }
            .sheet(isPresented: $presentingNewTemplate) {
                TemplateEditorView(existingTemplate: nil)
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditorView(existingTemplate: template)
            }
            .sheet(isPresented: $presentingNewAdaptiveProgram) {
                AdaptiveProgramEditorView(existingProgram: nil)
            }
            .sheet(item: $editingAdaptiveProgram) { program in
                AdaptiveProgramEditorView(existingProgram: program)
            }
            .sheet(isPresented: $presentingExerciseSelection) {
                AdaptiveExerciseSelectionEditorView()
            }
            .alert("Cycle Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "Unknown error")
            })
            .alert(
                pendingMutation?.title ?? "Confirm Change",
                isPresented: Binding(
                    get: { pendingMutation != nil },
                    set: { if !$0 { pendingMutation = nil } }
                )
            ) {
                if let pendingMutation {
                    Button(pendingMutation.confirmationLabel, role: pendingMutation.role) {
                        confirm(pendingMutation)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingMutation = nil
                }
            } message: {
                if let pendingMutation {
                    Text(pendingMutation.message)
                }
            }
            .onReceive(refreshTimer) { _ in
                if trainingMode == .rotation {
                    reloadPublishedCycles()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                if trainingMode == .rotation {
                    reloadPublishedCycles()
                }
            }
            .task {
                if trainingMode == .rotation { reloadPublishedCycles() }
            }
        }
    }

    private var trainingModeBinding: Binding<TrainingMode> {
        Binding(
            get: { trainingMode },
            set: { newMode in
                guard newMode != trainingMode else { return }
                pendingMutation = .switchMode(newMode)
            }
        )
    }

    @ViewBuilder
    private var adaptiveProgrammingSections: some View {
        Section("Adaptive Profile") {
            if let program = activeAdaptiveProgram {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(program.name)
                            .font(.headline)
                        Spacer()
                    }
                    Text(
                        "Up to \(AdaptiveVolumeControllerService.capacity(for: program, preferences: capacityPreferences).maxMuscleGroupCount) muscle groups · \(AdaptiveVolumeControllerService.capacity(for: program, preferences: capacityPreferences).maxExerciseCount) exercises · \(AdaptiveVolumeControllerService.capacity(for: program, preferences: capacityPreferences).maxWorkingSetCount) sets"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !program.isReviewedForUse {
                        Label("Review required", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Button("Edit Profile and Complexes") {
                    editingAdaptiveProgram = program
                }
                .accessibilityIdentifier("adaptive.editProfile")
            } else {
                Button("Create Adaptive Profile") {
                    presentingNewAdaptiveProgram = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("adaptive.createProfile")
            }
        }

        Section("Exercise Selection") {
            Button("Exercise Selection & Equipment") {
                presentingExerciseSelection = true
            }
            .accessibilityIdentifier("adaptive.exerciseSelection")
        }

    }

    private func ensureExerciseCatalog() throws -> [Exercise] {
        try BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
    }

    /// Passive refreshes stay silent. iCloud Drive being unavailable is an ordinary
    /// condition, and this runs on a repeating timer as well as on appear and on
    /// foreground — surfacing it put a modal error in front of the tab over and over.
    /// The last known list is kept rather than blanked. Only an explicit Refresh
    /// reports the failure, because there the user asked.
    private func reloadPublishedCycles(surfacingErrors: Bool = false) {
        do {
            publishedCycles = try PublishedCycleService.listPublishedCycles()
        } catch {
            if surfacingErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPublishedCycle(_ published: PublishedCycleFile, activateAfterImport: Bool) {
        do {
            // Ensure seeded library is persisted before validating external references.
            let currentExercises = try ensureExerciseCatalog()

            let draft = try PublishedCycleService.parseTemplate(at: published.url, exercises: currentExercises)
            guard draft.name.caseInsensitiveCompare(
                FixedCycleClusterProgramService.templateName
            ) != .orderedSame else {
                throw BootstrapDataService.ClusteredProgramRolloutError.existingTemplateConflict
            }
            if let existing = templates.first(where: { $0.name.caseInsensitiveCompare(draft.name) == .orderedSame }) {
                guard !FixedCycleClusterProgramService.isProgramTemplate(existing) else {
                    throw BootstrapDataService.ClusteredProgramRolloutError.existingTemplateConflict
                }
                if !activateAfterImport, existing.id == activeTemplate?.id {
                    errorMessage = "This cycle is active. Use Import + Activate to replace it."
                    return
                }
                let oldDays = existing.days
                let oldPools = existing.rotationPools

                existing.name = draft.name
                existing.days = draft.days
                existing.rotationPools = draft.rotationPools

                for day in oldDays { modelContext.delete(day) }
                for pool in oldPools { modelContext.delete(pool) }

                if activateAfterImport {
                    activate(template: existing)
                } else {
                    try modelContext.save()
                }
            } else {
                let template = CycleTemplate(name: draft.name, days: draft.days, rotationPools: draft.rotationPools)
                modelContext.insert(template)
                if activateAfterImport {
                    activate(template: template)
                } else {
                    try modelContext.save()
                }
            }
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func activate(template: CycleTemplate) {
        do {
            if template.name.caseInsensitiveCompare(
                FixedCycleClusterProgramService.templateName
            ) == .orderedSame,
               !FixedCycleClusterProgramService.isProgramTemplate(template) {
                throw BootstrapDataService.ClusteredProgramRolloutError.existingTemplateConflict
            }
            // Ensure the next Workout load uses this template immediately.
            let draftSessions = sessions.filter { $0.status == .draft }
            let draftIDs = Set(draftSessions.map(\.id))
            guard !progressionOccurrences.contains(where: {
                draftIDs.contains($0.sessionId)
            }) else {
                throw FixedCycleWorkoutError.completedClusterDraftCannotBeDiscarded
            }
            let cleanup = FixedCycleClusterProgramService.activationCleanupPlan(
                existingCycles: activeCycles,
                pointers: clusterPointers,
                contexts: fixedCycleSessionContexts,
                sessions: sessions
            )
            for draft in draftSessions {
                for entry in setEntries where entry.sessionId == draft.id {
                    modelContext.delete(entry)
                }
                modelContext.delete(draft)
            }
            for context in fixedCycleSessionContexts where cleanup.contextIDs.contains(context.id) {
                modelContext.delete(context)
            }

            // Keep exactly one active cycle instance to avoid stale pointer selection.
            for pointer in clusterPointers where cleanup.pointerIDs.contains(pointer.id) {
                modelContext.delete(pointer)
            }
            for existing in activeCycles {
                modelContext.delete(existing)
            }

            let rotationIndices = [RotationIndex(key: RotationPoolKey.quadsCompound.rawValue, value: 0)]
            let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0, rotationIndices: rotationIndices)
            try cycle.validate(template: template)
            modelContext.insert(cycle)
            if FixedCycleClusterProgramService.isProgramTemplate(template) {
                for pointer in FixedCycleClusterProgramService.makeRotationStates(
                    cycleInstanceId: cycle.id,
                    templateId: template.id
                ) {
                    modelContext.insert(pointer)
                }
            }
            try modelContext.save()
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func clone(template: CycleTemplate) {
        let dayCopies = template.days.map { day in
            CycleDay(
                label: day.label,
                slots: day.slots.map {
                    CycleSlot(position: $0.position, muscle: $0.muscle, exerciseId: $0.exerciseId, defaultSetCount: $0.defaultSetCount)
                },
                position: day.position
            )
        }

        let poolCopies = template.rotationPools.map { pool in
            RotationPool(key: pool.key, entries: pool.entries.map { RotationPoolEntry(exerciseId: $0.exerciseId) })
        }

        let clone = CycleTemplate(name: "\(template.name) Copy", days: dayCopies, rotationPools: poolCopies)
        modelContext.insert(clone)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        let requested = offsets.compactMap { templates.indices.contains($0) ? templates[$0] : nil }
        guard !requested.isEmpty else { return }
        if requested.contains(where: { $0.id == activeTemplate?.id }) {
            errorMessage = "Cannot delete the active template. Activate another template first."
            return
        }
        pendingMutation = .deleteTemplates(
            ids: requested.map(\.id),
            names: requested.map(\.name)
        )
    }

    private func confirm(_ mutation: PendingCycleMutation) {
        pendingMutation = nil
        switch mutation {
        case .switchMode(let mode):
            do {
                _ = try TrainingModeService.setMode(
                    mode,
                    preferences: trainingPreferences,
                    modelContext: modelContext
                )
            } catch {
                modelContext.rollback()
                errorMessage = error.localizedDescription
            }
        case .activate(let templateId, _):
            guard let template = templates.first(where: { $0.id == templateId }) else { return }
            activate(template: template)
        case .clone(let templateId, _):
            guard let template = templates.first(where: { $0.id == templateId }) else { return }
            clone(template: template)
        case .importCycle(let published, let activateAfterImport):
            importPublishedCycle(published, activateAfterImport: activateAfterImport)
        case .deleteTemplates(let ids, _):
            let requestedIds = Set(ids)
            for template in templates where requestedIds.contains(template.id) {
                modelContext.delete(template)
            }
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum PendingCycleMutation {
    case switchMode(TrainingMode)
    case activate(templateId: UUID, name: String)
    case clone(templateId: UUID, name: String)
    case importCycle(PublishedCycleFile, activateAfterImport: Bool)
    case deleteTemplates(ids: [UUID], names: [String])

    var title: String {
        switch self {
        case .switchMode:
            return "Change Training Mode?"
        case .activate:
            return "Reset Fixed Cycle?"
        case .clone:
            return "Clone Template?"
        case .importCycle(_, let activateAfterImport):
            return activateAfterImport ? "Import and Activate?" : "Import Cycle?"
        case .deleteTemplates:
            return "Delete Template?"
        }
    }

    var confirmationLabel: String {
        switch self {
        case .switchMode(let mode):
            return "Use \(mode.displayName)"
        case .activate(_, let name):
            return "Activate \(name)"
        case .clone:
            return "Create Copy"
        case .importCycle(_, let activateAfterImport):
            return activateAfterImport ? "Import and Activate" : "Import"
        case .deleteTemplates(_, let names):
            return names.count == 1 ? "Delete \(names[0])" : "Delete \(names.count) Templates"
        }
    }

    var message: String {
        switch self {
        case .switchMode(let mode):
            return "Workout will use \(mode.displayName). Progress in the other mode remains saved."
        case .activate(_, let name):
            return "\(name) will restart at day 1 and replace any in-progress Fixed Cycle draft."
        case .clone(_, let name):
            return "Creates \(name) Copy without activating it."
        case .importCycle(let published, let activateAfterImport):
            if activateAfterImport {
                return "Imports \(published.name), restarts it at day 1, and replaces any in-progress Fixed Cycle draft."
            }
            return "Imports \(published.name). A same-named template will be replaced."
        case .deleteTemplates(_, let names):
            return names.count == 1
                ? "Deletes \(names[0])."
                : "Deletes \(names.count) templates."
        }
    }

    var role: ButtonRole? {
        switch self {
        case .activate, .importCycle(_, true), .deleteTemplates:
            return .destructive
        default:
            return nil
        }
    }
}

private struct AdaptiveExerciseSelectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var preferences: [AdaptiveExerciseSelectionPreference]
    @State private var drafts: [MuscleGroup: ExerciseSelectionDraft] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                    DisclosureGroup {
                        Picker("Selection policy", selection: modeBinding(for: muscle)) {
                            ForEach(AdaptiveExerciseSelectionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Text(selectionModeHelp(draft(for: muscle).mode))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if draft(for: muscle).mode == .pinned {
                            Picker("Foundation exercise", selection: pinnedBinding(for: muscle)) {
                                Text("Choose exercise").tag(Optional<UUID>.none)
                                ForEach(compoundExercises(for: muscle), id: \.id) { exercise in
                                    Text("\(exercise.name) · Compound").tag(Optional(exercise.id))
                                }
                            }
                            Text("Other available exercises")
                                .font(.subheadline.weight(.semibold))
                            ForEach(activeExercises(for: muscle), id: \.id) { exercise in
                                Toggle(isOn: eligibilityBinding(exercise: exercise, muscle: muscle)) {
                                    exerciseAvailabilityLabel(exercise)
                                }
                                .disabled(draft(for: muscle).pinnedExerciseId == exercise.id)
                            }
                        } else {
                            Text("Available with current equipment")
                                .font(.subheadline.weight(.semibold))
                            ForEach(activeExercises(for: muscle), id: \.id) { exercise in
                                Toggle(isOn: eligibilityBinding(exercise: exercise, muscle: muscle)) {
                                    exerciseAvailabilityLabel(exercise)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(muscle.displayName)
                            Spacer()
                            Text(draft(for: muscle).mode.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Exercise Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if drafts.isEmpty { loadDrafts() }
            }
            .alert(
                "Cannot Save Exercise Selection",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func preference(for muscle: MuscleGroup) -> AdaptiveExerciseSelectionPreference? {
        preferences.first { $0.muscle == muscle }
    }

    private func selectionModeHelp(_ mode: AdaptiveExerciseSelectionMode) -> String {
        switch mode {
        case .repeatLast: "Reuse the latest available exercise."
        case .rotateRecent: "Choose a different available exercise than last time."
        case .pinned: "Always use the selected foundation exercise."
        }
    }

    private func activeExercises(for muscle: MuscleGroup) -> [Exercise] {
        exercises
            .filter {
                $0.isActive
                    && $0.primaryMuscle == muscle
                    && !AdaptiveExposureControllerService.isReverseHyper($0)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func compoundExercises(for muscle: MuscleGroup) -> [Exercise] {
        activeExercises(for: muscle).filter { $0.type == .compound }
    }

    private func exerciseAvailabilityLabel(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name)
            Text(exercise.type == .compound ? "Compound · hard/core" : "Isolation · accessory")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func draft(for muscle: MuscleGroup) -> ExerciseSelectionDraft {
        drafts[muscle] ?? ExerciseSelectionDraft(
            mode: .repeatLast,
            pinnedExerciseId: nil,
            eligibleExerciseIds: Set(activeExercises(for: muscle).map(\.id))
        )
    }

    private func modeBinding(for muscle: MuscleGroup) -> Binding<AdaptiveExerciseSelectionMode> {
        Binding(
            get: { draft(for: muscle).mode },
            set: { mode in
                var value = draft(for: muscle)
                value.mode = mode
                if mode == .pinned, value.pinnedExerciseId == nil {
                    value.pinnedExerciseId = compoundExercises(for: muscle).first?.id
                    if let pinnedExerciseId = value.pinnedExerciseId {
                        value.eligibleExerciseIds.insert(pinnedExerciseId)
                    }
                }
                drafts[muscle] = value
            }
        )
    }

    private func pinnedBinding(for muscle: MuscleGroup) -> Binding<UUID?> {
        Binding(
            get: { draft(for: muscle).pinnedExerciseId },
            set: { exerciseId in
                var value = draft(for: muscle)
                value.pinnedExerciseId = exerciseId
                if let exerciseId {
                    value.eligibleExerciseIds.insert(exerciseId)
                }
                drafts[muscle] = value
            }
        )
    }

    private func eligibilityBinding(exercise: Exercise, muscle: MuscleGroup) -> Binding<Bool> {
        Binding(
            get: { draft(for: muscle).eligibleExerciseIds.contains(exercise.id) },
            set: { isEligible in
                var value = draft(for: muscle)
                if !isEligible, value.mode == .pinned, value.pinnedExerciseId == exercise.id {
                    return
                }
                if isEligible {
                    value.eligibleExerciseIds.insert(exercise.id)
                } else {
                    value.eligibleExerciseIds.remove(exercise.id)
                }
                drafts[muscle] = value
            }
        )
    }

    private func loadDrafts() {
        drafts = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { muscle in
            if let preference = preference(for: muscle) {
                return (
                    muscle,
                    ExerciseSelectionDraft(
                        mode: preference.mode,
                        pinnedExerciseId: preference.pinnedExerciseId,
                        eligibleExerciseIds: Set(preference.eligibleExerciseIds)
                    )
                )
            }
            return (
                muscle,
                ExerciseSelectionDraft(
                    mode: .repeatLast,
                    pinnedExerciseId: nil,
                    eligibleExerciseIds: Set(activeExercises(for: muscle).map(\.id))
                )
            )
        })
    }

    private func save() {
        do {
            for muscle in MuscleGroup.allCases {
                let value = draft(for: muscle)
                let savedPreference: AdaptiveExerciseSelectionPreference
                if let existing = preference(for: muscle) {
                    savedPreference = existing
                } else {
                    savedPreference = AdaptiveExerciseSelectionPreference(muscle: muscle, mode: value.mode)
                    modelContext.insert(savedPreference)
                }
                savedPreference.mode = value.mode
                savedPreference.pinnedExerciseId = value.pinnedExerciseId
                savedPreference.eligibleExerciseIds = value.eligibleExerciseIds.sorted {
                    $0.uuidString < $1.uuidString
                }
            }
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExerciseSelectionDraft {
    var mode: AdaptiveExerciseSelectionMode
    var pinnedExerciseId: UUID?
    var eligibleExerciseIds: Set<UUID>
}

private struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var sessions: [Session]

    let existingTemplate: CycleTemplate?

    @State private var draft = TemplateDraft.newTemplate
    @State private var errorMessage: String?
    @State private var pendingRemoval: TemplateRemovalRequest?

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name", text: $draft.name)
                }

                Section("Days") {
                    ForEach(Array(draft.days.enumerated()), id: \.element.id) { dayIndex, day in
                        DayEditorSection(
                            day: day,
                            exercises: exercises,
                            onLabelChanged: { draft.days[dayIndex].label = $0 },
                            onDuplicate: { duplicateDay(dayIndex) },
                            onDelete: { deleteDay(dayIndex) },
                            onAddSlot: { addSlot(dayIndex) },
                            onMoveSlotUp: { moveSlot(dayIndex: dayIndex, slotIndex: $0, delta: -1) },
                            onMoveSlotDown: { moveSlot(dayIndex: dayIndex, slotIndex: $0, delta: 1) },
                            onDeleteSlot: {
                                pendingRemoval = .exercise(
                                    TemplateSlotRemovalRequest(
                                        dayIndex: dayIndex,
                                        slotIndex: $0,
                                        dayLabel: day.label,
                                        exerciseName: exerciseName(
                                            dayIndex: dayIndex,
                                            slotIndex: $0
                                        )
                                    )
                                )
                            },
                            onDeleteMuscle: {
                                pendingRemoval = .muscle(
                                    dayIndex: dayIndex,
                                    dayLabel: day.label,
                                    muscle: $0
                                )
                            },
                            onMuscleChanged: { slotIndex, muscle in
                                draft.days[dayIndex].slots[slotIndex].muscle = muscle
                                if let firstMatch = exercises.first(where: { $0.primaryMuscle == muscle })?.id {
                                    draft.days[dayIndex].slots[slotIndex].exerciseId = firstMatch
                                }
                            },
                            onExerciseChanged: { slotIndex, exerciseId in
                                draft.days[dayIndex].slots[slotIndex].exerciseId = exerciseId
                            },
                            onSetCountChanged: { slotIndex, count in
                                draft.days[dayIndex].slots[slotIndex].defaultSetCount = count
                            }
                        )
                    }

                    Button("Add Day") {
                        addDay()
                    }
                }

                weeklyEstimateSection
            }
            .navigationTitle(existingTemplate == nil ? "New Template" : "Edit Template")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if let existingTemplate {
                    draft = TemplateDraft(existing: existingTemplate)
                } else {
                    draft = TemplateDraft.newTemplate
                    if draft.days.first?.slots.first?.exerciseId == nil {
                        draft.days[0].slots[0].exerciseId = exercises.first(where: { $0.primaryMuscle == .chest })?.id ?? exercises.first?.id
                    }
                }
            }
            .alert("Cycle Validation", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "Unknown error")
            })
            .confirmationDialog(
                pendingRemoval?.title ?? "Remove from Future Workouts?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let request = pendingRemoval {
                    Button(
                        request.confirmationLabel,
                        role: .destructive
                    ) {
                        switch request {
                        case .exercise(let slot):
                            deleteSlot(
                                dayIndex: slot.dayIndex,
                                slotIndex: slot.slotIndex
                            )
                        case .muscle(let dayIndex, _, let muscle):
                            deleteMuscle(dayIndex: dayIndex, muscle: muscle)
                        }
                        pendingRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingRemoval = nil
                }
            } message: {
                Text("This edits only the named template day. Completed history and the exercise catalog are preserved.")
            }
        }
    }

    private var weeklyEstimateSection: some View {
        Section("Weekly Volume Estimate") {
            let last30 = sessions.filter { ($0.finishedAt ?? $0.createdAt) >= Date().addingTimeInterval(-30 * 24 * 60 * 60) }
            let avgSessionsPerWeek = (Double(last30.count) / 30.0) * 7.0
            let cycleLength = max(draft.days.count, 1)
            let totals = totalSetsPerMuscle()

            ForEach(MuscleGroup.allCases, id: \.rawValue) { muscle in
                let total = totals[muscle, default: 0]
                let weekly = Double(total) * (avgSessionsPerWeek / Double(cycleLength))
                HStack {
                    Text(muscle.rawValue)
                    Spacer()
                    Text(weekly, format: .number.precision(.fractionLength(1)))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func totalSetsPerMuscle() -> [MuscleGroup: Int] {
        var totals: [MuscleGroup: Int] = [:]
        for day in draft.days {
            for slot in day.slots {
                totals[slot.muscle, default: 0] += slot.defaultSetCount
            }
        }
        return totals
    }

    private func addDay() {
        draft.days.append(TemplateDraftDay(label: "Day \(draft.days.count + 1)", slots: []))
    }

    private func duplicateDay(_ index: Int) {
        guard draft.days.indices.contains(index) else { return }
        var copy = draft.days[index]
        copy.id = UUID()
        copy.label = "\(copy.label) Copy"
        copy.slots = copy.slots.map {
            var s = $0
            s.id = UUID()
            return s
        }
        draft.days.insert(copy, at: index + 1)
    }

    private func deleteDay(_ index: Int) {
        guard draft.days.indices.contains(index) else { return }
        draft.days.remove(at: index)
        if draft.days.isEmpty {
            addDay()
        }
    }

    private func addSlot(_ dayIndex: Int) {
        guard draft.days.indices.contains(dayIndex) else { return }
        let defaultMuscle = MuscleGroup.chest
        let defaultExercise = exercises.first(where: { $0.primaryMuscle == defaultMuscle })?.id ?? exercises.first?.id
        draft.days[dayIndex].slots.append(
            TemplateDraftSlot(muscle: defaultMuscle, exerciseId: defaultExercise, defaultSetCount: 3)
        )
    }

    private func deleteSlot(dayIndex: Int, slotIndex: Int) {
        guard draft.days.indices.contains(dayIndex) else { return }
        guard draft.days[dayIndex].slots.indices.contains(slotIndex) else { return }
        draft.days[dayIndex].slots.remove(at: slotIndex)
    }

    private func exerciseName(dayIndex: Int, slotIndex: Int) -> String {
        guard draft.days.indices.contains(dayIndex),
              draft.days[dayIndex].slots.indices.contains(slotIndex),
              let exerciseId = draft.days[dayIndex].slots[slotIndex].exerciseId else {
            return "Exercise"
        }
        return exercises.first(where: { $0.id == exerciseId })?.name ?? "Exercise"
    }

    private func deleteMuscle(dayIndex: Int, muscle: MuscleGroup) {
        guard draft.days.indices.contains(dayIndex) else { return }
        draft.days[dayIndex].slots.removeAll { $0.muscle == muscle }
    }

    private func moveSlot(dayIndex: Int, slotIndex: Int, delta: Int) {
        guard draft.days.indices.contains(dayIndex) else { return }
        let newIndex = slotIndex + delta
        guard draft.days[dayIndex].slots.indices.contains(slotIndex) else { return }
        guard draft.days[dayIndex].slots.indices.contains(newIndex) else { return }

        let value = draft.days[dayIndex].slots.remove(at: slotIndex)
        draft.days[dayIndex].slots.insert(value, at: newIndex)
    }

    private func save() {
        do {
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OpenLiftValidationError.emptyName(entity: "CycleTemplate")
            }

            let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

            let dayModels: [CycleDay] = try draft.days.enumerated().map { dayIndex, day in
                if day.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw OpenLiftValidationError.emptyDayLabel
                }

                let slots: [CycleSlot] = try day.slots.enumerated().map { index, slot in
                    guard let exerciseId = slot.exerciseId else {
                        throw OpenLiftValidationError.exerciseNotFound(exerciseId: UUID())
                    }
                    return CycleSlot(position: index, muscle: slot.muscle, exerciseId: exerciseId, defaultSetCount: slot.defaultSetCount)
                }
                return CycleDay(label: day.label, slots: slots, position: dayIndex)
            }

            let quadsCompoundIds = Set(dayModels
                .flatMap(\.slots)
                .compactMap { slot -> UUID? in
                    guard let exercise = exercisesById[slot.exerciseId] else { return nil }
                    return (slot.muscle == .quads && exercise.type == .compound) ? slot.exerciseId : nil
                })

            let rotationPools: [RotationPool]
            if quadsCompoundIds.isEmpty {
                rotationPools = []
            } else {
                rotationPools = [
                    RotationPool(
                        key: RotationPoolKey.quadsCompound.rawValue,
                        entries: quadsCompoundIds.map { RotationPoolEntry(exerciseId: $0) }
                    )
                ]
            }

            let validationTemplate = CycleTemplate(name: draft.name, days: dayModels, rotationPools: rotationPools)
            try validationTemplate.validate(exercisesById: exercisesById)

            if let existingTemplate {
                let oldDays = existingTemplate.days
                let oldPools = existingTemplate.rotationPools

                existingTemplate.name = draft.name
                existingTemplate.days = dayModels
                existingTemplate.rotationPools = rotationPools

                for oldDay in oldDays { modelContext.delete(oldDay) }
                for oldPool in oldPools { modelContext.delete(oldPool) }
            } else {
                modelContext.insert(CycleTemplate(name: draft.name, days: dayModels, rotationPools: rotationPools))
            }

            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct DayEditorSection: View {
    let day: TemplateDraftDay
    let exercises: [Exercise]
    let onLabelChanged: (String) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onAddSlot: () -> Void
    let onMoveSlotUp: (Int) -> Void
    let onMoveSlotDown: (Int) -> Void
    let onDeleteSlot: (Int) -> Void
    let onDeleteMuscle: (MuscleGroup) -> Void
    let onMuscleChanged: (Int, MuscleGroup) -> Void
    let onExerciseChanged: (Int, UUID?) -> Void
    let onSetCountChanged: (Int, Int) -> Void

    var body: some View {
        Section {
            TextField("Day Label", text: Binding(get: { day.label }, set: onLabelChanged))

            ForEach(Array(day.slots.enumerated()), id: \.element.id) { slotIndex, slot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Muscle", selection: Binding(
                            get: { slot.muscle },
                            set: { onMuscleChanged(slotIndex, $0) }
                        )) {
                            ForEach(MuscleGroup.allCases, id: \.rawValue) { muscle in
                                Text(muscle.rawValue).tag(muscle)
                            }
                        }

                        Button(action: { onMoveSlotUp(slotIndex) }) {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)

                        Button(action: { onMoveSlotDown(slotIndex) }) {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive, action: { onDeleteSlot(slotIndex) }) {
                            Label("Remove from Future \(day.label)", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }

                    Picker("Exercise", selection: Binding(
                        get: { slot.exerciseId },
                        set: { onExerciseChanged(slotIndex, $0) }
                    )) {
                        Text("Select").tag(Optional<UUID>.none)
                        ForEach(exercises.filter { $0.primaryMuscle == slot.muscle }, id: \.id) { exercise in
                            Text(exercise.name).tag(Optional(exercise.id))
                        }
                    }

                    Stepper("Sets: \(slot.defaultSetCount)", value: Binding(
                        get: { slot.defaultSetCount },
                        set: { onSetCountChanged(slotIndex, min(max($0, 1), 3)) }
                    ), in: 1...3)
                }
            }

            Button("Add Muscle Slot", action: onAddSlot)
            let configuredMuscles = Set(day.slots.map(\.muscle))
            if !configuredMuscles.isEmpty {
                Menu("Remove Muscle Group from Future \(day.label) Workouts") {
                    ForEach(
                        MuscleGroup.allCases.filter { configuredMuscles.contains($0) },
                        id: \.self
                    ) { muscle in
                        Button(
                            "Remove \(muscle.displayName) from Future \(day.label)",
                            role: .destructive
                        ) {
                            onDeleteMuscle(muscle)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(day.label)
                Spacer()
                Button("Duplicate", action: onDuplicate)
                    .font(.caption)
                Button("Delete", role: .destructive, action: onDelete)
                    .font(.caption)
            }
        }
    }
}

private struct TemplateDraft {
    var name: String
    var days: [TemplateDraftDay]

    static let newTemplate = TemplateDraft(
        name: "New Cycle",
        days: [TemplateDraftDay(label: "Day 1", slots: [TemplateDraftSlot(muscle: .chest, exerciseId: nil, defaultSetCount: 3)])]
    )

    init(name: String, days: [TemplateDraftDay]) {
        self.name = name
        self.days = days
    }

    init(existing: CycleTemplate) {
        self.name = existing.name
        self.days = CycleOrdering.sortedDays(existing.days).map { day in
            TemplateDraftDay(
                label: day.label,
                slots: day.slots.sorted(by: { $0.position < $1.position }).map { slot in
                    TemplateDraftSlot(muscle: slot.muscle, exerciseId: slot.exerciseId, defaultSetCount: slot.defaultSetCount)
                }
            )
        }
    }
}

private struct TemplateSlotRemovalRequest {
    let dayIndex: Int
    let slotIndex: Int
    let dayLabel: String
    let exerciseName: String
}

private enum TemplateRemovalRequest {
    case exercise(TemplateSlotRemovalRequest)
    case muscle(dayIndex: Int, dayLabel: String, muscle: MuscleGroup)

    var title: String {
        switch self {
        case .exercise(let request):
            return "Remove \(request.exerciseName) from future \(request.dayLabel) workouts?"
        case .muscle(_, let dayLabel, let muscle):
            return "Remove \(muscle.displayName) from future \(dayLabel) workouts?"
        }
    }

    var confirmationLabel: String {
        switch self {
        case .exercise(let request):
            return "Remove from Future \(request.dayLabel)"
        case .muscle(_, let dayLabel, _):
            return "Remove Muscle from Future \(dayLabel)"
        }
    }
}

private struct TemplateDraftDay: Identifiable {
    var id = UUID()
    var label: String
    var slots: [TemplateDraftSlot]
}

private struct TemplateDraftSlot: Identifiable {
    var id = UUID()
    var muscle: MuscleGroup
    var exerciseId: UUID?
    var defaultSetCount: Int
}

#Preview {
    CycleView()
}
