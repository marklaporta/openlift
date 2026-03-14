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

    @State private var presentingNewTemplate = false
    @State private var editingTemplate: CycleTemplate?
    @State private var errorMessage: String?
    @State private var pendingActivationTemplate: CycleTemplate?
    @State private var showingActivationConfirmation = false
    @State private var publishedCycles: [PublishedCycleFile] = []
    @State private var lastPublishedRefreshAt: Date?
    @State private var lastPublishedCount: Int = 0
    @State private var refreshTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    @State private var debugTapCount: Int = 0
    @State private var debugUnlocked: Bool = false
    @State private var debugSnapshotText: String?

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let activeTemplate {
                        Text(activeTemplate.name)
                    } else {
                        Text("No active cycle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Active Cycle")
                } footer: {
                    if debugUnlocked {
                        Text("Debug tools unlocked")
                            .font(.caption2)
                    } else {
                        Text(" ")
                            .font(.caption2)
                    }
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

                                Button("Clone") {
                                    clone(template: template)
                                }
                                .buttonStyle(.bordered)

                                Button("Activate") {
                                    requestActivation(of: template)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteTemplates)
                }

                Section("Published Cycles (iCloud)") {
                    if let lastPublishedRefreshAt {
                        Text("Last refresh: \(lastPublishedRefreshAt.formatted(date: .abbreviated, time: .standard)) • \(lastPublishedCount) file(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if publishedCycles.isEmpty {
                        Text("No published cycle files found in iCloud Drive/OpenLift/cycles")
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
                                    importPublishedCycle(published, activateAfterImport: false)
                                }
                                .buttonStyle(.bordered)

                                Button("Import + Activate") {
                                    importPublishedCycle(published, activateAfterImport: true)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        reloadPublishedCycles()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentingNewTemplate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $presentingNewTemplate) {
                TemplateEditorView(existingTemplate: nil)
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditorView(existingTemplate: template)
            }
            .alert("Cycle Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "Unknown error")
            })
            .confirmationDialog(
                "Replace Active Cycle?",
                isPresented: $showingActivationConfirmation,
                titleVisibility: .visible
            ) {
                if let pendingActivationTemplate {
                    Button("Activate \(pendingActivationTemplate.name)", role: .destructive) {
                        activate(template: pendingActivationTemplate)
                        self.pendingActivationTemplate = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingActivationTemplate = nil
                }
            } message: {
                if let activeTemplate {
                    Text("This will replace '\(activeTemplate.name)' and discard its in-progress session state.")
                }
            }
            .onReceive(refreshTimer) { _ in
                reloadPublishedCycles()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                reloadPublishedCycles()
            }
            .task {
                do {
                    let currentExercises = try ensureExerciseCatalog()
                    _ = try BootstrapDataService.importPreferredPublishedTemplateIfNeeded(
                        modelContext: modelContext,
                        existingTemplates: templates,
                        exercises: currentExercises
                    )
                    reloadPublishedCycles()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func ensureExerciseCatalog() throws -> [Exercise] {
        try BootstrapDataService.ensureExerciseCatalog(modelContext: modelContext)
    }

    private func reloadPublishedCycles() {
        do {
            publishedCycles = try PublishedCycleService.listPublishedCycles()
            lastPublishedCount = publishedCycles.count
            lastPublishedRefreshAt = .now
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPublishedCycle(_ published: PublishedCycleFile, activateAfterImport: Bool) {
        do {
            // Ensure seeded library is persisted before validating external references.
            let currentExercises = try ensureExerciseCatalog()

            let draft = try PublishedCycleService.parseTemplate(at: published.url, exercises: currentExercises)
            if let existing = templates.first(where: { $0.name.caseInsensitiveCompare(draft.name) == .orderedSame }) {
                let oldDays = existing.days
                let oldPools = existing.rotationPools

                existing.name = draft.name
                existing.days = draft.days
                existing.rotationPools = draft.rotationPools

                for day in oldDays { modelContext.delete(day) }
                for pool in oldPools { modelContext.delete(pool) }

                try modelContext.save()

                if activateAfterImport {
                    requestActivation(of: existing)
                }
            } else {
                let template = CycleTemplate(name: draft.name, days: draft.days, rotationPools: draft.rotationPools)
                modelContext.insert(template)
                try modelContext.save()

                if activateAfterImport {
                    requestActivation(of: template)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestActivation(of template: CycleTemplate) {
        if shouldConfirmActivation(of: template) {
            pendingActivationTemplate = template
            showingActivationConfirmation = true
            return
        }
        activate(template: template)
    }

    private func shouldConfirmActivation(of template: CycleTemplate) -> Bool {
        let activeCycle = OpenLiftStateResolver.activeCycle(
            activeCycles: activeCycles,
            templates: templates,
            sessions: sessions,
            latestExport: nil,
            preferredTemplateId: UserDefaults.standard.string(forKey: "openlift.lastActivatedTemplateId")
                .flatMap(UUID.init(uuidString:))
        )
        return shouldConfirmActivation(
            activeTemplateId: activeCycle?.templateId,
            requestedTemplateId: template.id
        )
    }

    fileprivate func shouldConfirmActivation(
        activeTemplateId: UUID?,
        requestedTemplateId: UUID
    ) -> Bool {
        guard let activeTemplateId else { return false }
        return activeTemplateId != requestedTemplateId
    }

    private func activate(template: CycleTemplate) {
        do {
            // Ensure the next Workout load uses this template immediately.
            let draftSessions = sessions.filter { $0.status == .draft }
            for draft in draftSessions {
                for entry in setEntries where entry.sessionId == draft.id {
                    modelContext.delete(entry)
                }
                modelContext.delete(draft)
            }

            // Keep exactly one active cycle instance to avoid stale pointer selection.
            for existing in activeCycles {
                modelContext.delete(existing)
            }

            let rotationIndices = [RotationIndex(key: RotationPoolKey.quadsCompound.rawValue, value: 0)]
            let cycle = ActiveCycleInstance(templateId: template.id, currentDayIndex: 0, rotationIndices: rotationIndices)
            try cycle.validate(template: template)
            modelContext.insert(cycle)
            UserDefaults.standard.set(template.id.uuidString, forKey: "openlift.lastActivatedTemplateId")
            UserDefaults.standard.set(template.name, forKey: "openlift.lastActivatedTemplateName")

            try modelContext.save()
        } catch {
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
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            let template = templates[index]
            if activeTemplate?.id == template.id {
                errorMessage = "Cannot delete the active template. Activate another template first."
                continue
            }
            modelContext.delete(template)
        }

        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var exercises: [Exercise]
    @Query private var sessions: [Session]

    let existingTemplate: CycleTemplate?

    @State private var draft = TemplateDraft.newTemplate
    @State private var errorMessage: String?

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
                            onDeleteSlot: { deleteSlot(dayIndex: dayIndex, slotIndex: $0) },
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
            Text("Informational only")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                            Image(systemName: "trash")
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
