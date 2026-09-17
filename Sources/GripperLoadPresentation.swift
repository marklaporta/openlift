import SwiftUI

/// CoC history stores model ordinals, not pounds. Keep this encoding stable for
/// existing sets, repeat-last prefills, and old exports; labels are presentation.
enum GripperLoadPresentation {
    static let exerciseId = UUID(uuidString: "1D00E4BA-2F06-4903-A769-22E4BAC789DB")!
    static let models: [(value: Double, label: String)] = [(1, "G"), (2, "T"), (3, "1")]
    static let exportEncoding = "coc_model_ordinal_v1:1=G,2=T,3=1;not_weight"

    static func applies(exerciseId: UUID? = nil, name: String? = nil) -> Bool {
        if exerciseId == self.exerciseId { return true }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["captain of crush", "captains of crush", "coc gripper"].contains(name)
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
