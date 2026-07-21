import SwiftData

enum TrainingModeService {
    static let activeModeKey = "active-training-mode"

    static func resolvedMode(preferences: [TrainingPreference]) -> TrainingMode {
        guard let storedValue = preferences.first(where: { $0.key == activeModeKey })?.modeRawValue,
              let mode = TrainingMode(rawValue: storedValue) else {
            return .rotation
        }
        return mode
    }

    @discardableResult
    static func setMode(
        _ mode: TrainingMode,
        preferences: [TrainingPreference],
        modelContext: ModelContext
    ) throws -> TrainingPreference {
        let matchingPreferences = preferences.filter { $0.key == activeModeKey }
        let preference: TrainingPreference

        if let existing = matchingPreferences.first {
            preference = existing
            preference.modeRawValue = mode.rawValue
            for duplicate in matchingPreferences.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            preference = TrainingPreference(modeRawValue: mode.rawValue)
            modelContext.insert(preference)
        }

        try modelContext.save()
        return preference
    }
}
