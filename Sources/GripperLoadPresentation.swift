import SwiftUI
import SwiftData

/// Legacy ordinals are only a compatibility adapter for editing and prefill.
/// V16 persists equipment model tokens and exports explicitly tagged identities.
enum GripperLoadPresentation {
    static let exerciseId = UUID(uuidString: "1D00E4BA-2F06-4903-A769-22E4BAC789DB")!
    static let models: [(value: Double, label: String)] = [(1, "G"), (2, "T"), (3, "1")]
    static let semanticEncoding = "coc_model_identity_v2"
    static func legacyValue(_ token: String) -> Double? { models.first { $0.label == token }?.value }
    static let exportEncoding = "coc_model_ordinal_v1:1=G,2=T,3=1;not_weight"

    static func applies(exerciseId: UUID? = nil, name: String? = nil) -> Bool {
        if exerciseId == self.exerciseId { return true }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["captain of crush", "captains of crush", "coc gripper"].contains(name)
    }

    static func isGripper(_ exerciseID: UUID, in context: ModelContext?) -> Bool {
        guard let context else { return false }
        let descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == exerciseID })
        return (try? context.fetch(descriptor).first).map { applies(exerciseId: $0.id, name: $0.name) } ?? false
    }

    static func validatePayload(model: String?, encoding: String?, numericWeight: Double) throws {
        if model != nil || encoding != nil {
            guard let model, legacyValue(model) != nil, encoding == semanticEncoding, numericWeight == 0 else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid or unsupported gripper model identity"))
            }
        }
    }

    static func modelLabel(_ storedValue: Double) -> String? {
        models.first { $0.value == storedValue }?.label
    }

    static func load(_ value: Double, exerciseId: UUID? = nil, name: String? = nil) -> String {
        guard applies(exerciseId: exerciseId, name: name) else {
            return WeightFormatting.normalized(value).formatted(WeightFormatting.style)
        }
        if let label = modelLabel(value) { return "Model \(label)" }
        // Never round a legacy ordinal into a known model or relabel it as pounds.
        return "Unknown model (legacy \(value.formatted(.number.precision(.fractionLength(0...16)))))"
    }

    static func set(_ weight: Double, reps: Int, exerciseId: UUID? = nil, name: String? = nil, separator: String = "×") -> String {
        "\(load(weight, exerciseId: exerciseId, name: name)) \(separator) \(reps)"
    }
}

struct GripperModelPicker: View {
    @Binding var value: Double

    var body: some View {
        Picker("Model", selection: Binding(
            get: { value },
            set: { selected in
                // The unknown/empty row is a display fallback, never a conversion.
                guard GripperLoadPresentation.modelLabel(selected) != nil else { return }
                value = selected
            }
        )) {
            if GripperLoadPresentation.modelLabel(value) == nil {
                Text(value == 0 ? "Choose" : "Unknown (\(value.formatted()))").tag(value)
            }
            ForEach(GripperLoadPresentation.models, id: \.value) { model in
                Text(model.label).tag(model.value)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 82)
        .accessibilityLabel("Gripper model")
        .accessibilityValue(GripperLoadPresentation.modelLabel(value) ?? (value == 0 ? "Choose" : "Unknown \(value.formatted())"))
    }
}

/// Explicit historical rewrite, independent of all program/catalog activations.
enum GripperModelStorage {
    static let marker = "openlift.gripper-model-identities.v2"
    struct Result { let didApply: Bool; let converted: Int; let unknown: Int; let backupURL: URL? }

    @MainActor
    static func migrate(modelContext: ModelContext, backupDirectory: URL? = nil,
        snapshot: (URL, URL) throws -> Void = StoreBackupService.snapshot
    ) throws -> Result {
        guard !modelContext.hasChanges else { throw BootstrapDataService.ClusterRevisionError.pendingChanges }
        if try modelContext.fetch(FetchDescriptor<TrainingPreference>()).contains(where: { $0.key == marker }) {
            return Result(didApply: false, converted: 0, unknown: 0, backupURL: nil)
        }
        guard !(try modelContext.fetch(FetchDescriptor<Session>())).contains(where: { $0.status == .draft }),
              !(try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())).contains(where: { $0.status == .draft }) else {
            throw BootstrapDataService.ClusterRevisionError.draftHasWork
        }
        guard let storeURL = modelContext.container.configurations.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path) else { throw BootstrapDataService.SeatedShrugBackupError.persistentStoreRequired }
        let directory = try backupDirectory ?? FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenLift/revision-backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("before-gripper-model-identities-\(UUID().uuidString).sqlite")
        try snapshot(storeURL, backup)
        guard StoreBackupService.isValidSnapshot(at: backup) else { throw BootstrapDataService.SeatedShrugBackupError.verificationFailed }
        var converted = 0, unknown = 0
        do {
            let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
            let ids = Set(exercises.filter { GripperLoadPresentation.applies(exerciseId: $0.id, name: $0.name) }.map(\.id)).union([GripperLoadPresentation.exerciseId])
            for row in try modelContext.fetch(FetchDescriptor<SetEntry>()) where ids.contains(row.exerciseId) && row.gripperModel == nil {
                if let token = GripperLoadPresentation.modelLabel(row.numericWeight) {
                    row.gripperModel = token; row.numericWeight = 0; converted += 1
                } else { unknown += 1 }
            }
            for row in try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>()) where ids.contains(row.exerciseId) && row.gripperModel == nil {
                if let token = GripperLoadPresentation.modelLabel(row.numericWeight) {
                    row.gripperModel = token; row.numericWeight = 0; converted += 1
                } else { unknown += 1 }
            }
            modelContext.insert(TrainingPreference(key: marker, modeRawValue: GripperLoadPresentation.semanticEncoding))
            try modelContext.save()
            return Result(didApply: true, converted: converted, unknown: unknown, backupURL: backup)
        } catch { modelContext.rollback(); throw error }
    }
}
