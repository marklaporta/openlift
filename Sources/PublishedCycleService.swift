import Foundation

struct PublishedCycleFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let modifiedAt: Date?
}

struct PublishedCycleTemplateDraft {
    let name: String
    let days: [CycleDay]
    let rotationPools: [RotationPool]
}

enum PublishedCycleService {
    private static let infoPlistContainerKey = "OpenLiftICloudContainerIdentifier"
    enum PublishedCycleError: LocalizedError {
        case folderUnavailable
        case invalidFile(String)
        case unknownExerciseReference(String)
        case invalidExerciseId(String)

        var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                return "Could not access the OpenLift cycles folder in iCloud Drive."
            case .invalidFile(let message):
                return "Invalid cycle JSON: \(message)"
            case .unknownExerciseReference(let ref):
                return "Cycle references an unknown exercise: \(ref)"
            case .invalidExerciseId(let value):
                return "Invalid exerciseId UUID: \(value)"
            }
        }
    }

    static func cyclesFolderURL() throws -> URL {
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) {
            let folder = iCloudURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("OpenLift", isDirectory: true)
                .appendingPathComponent("cycles", isDirectory: true)
            try ensureDirectory(at: folder)
            return folder
        }
        throw PublishedCycleError.folderUnavailable
    }

    private static var containerIdentifier: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistContainerKey) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "iCloud.com.example.openlift"
        }
        return value
    }

    static func listPublishedCycles() throws -> [PublishedCycleFile] {
        let folder = try cyclesFolderURL()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                return values.isRegularFile == true
            }
            .map { url in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                return PublishedCycleFile(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
    }

    static func parseTemplate(at url: URL, exercises: [Exercise]) throws -> PublishedCycleTemplateDraft {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(PublishedCycleDocument.self, from: data)

        if doc.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PublishedCycleError.invalidFile("name is required")
        }
        if doc.days.isEmpty {
            throw PublishedCycleError.invalidFile("days must not be empty")
        }

        let exercisesById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let exercisesByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name.lowercased(), $0) })
        let exercisesByCanonicalName = Dictionary(uniqueKeysWithValues: exercises.map { (canonicalizeName($0.name), $0) })

        let days = try doc.days.enumerated().map { dayIndex, dayDoc in
            let slots = try dayDoc.slots.enumerated().map { index, slotDoc in
                let exercise = try resolveExercise(
                    slotDoc: slotDoc,
                    byId: exercisesById,
                    byName: exercisesByName,
                    byCanonicalName: exercisesByCanonicalName
                )
                return CycleSlot(
                    position: index,
                    muscle: slotDoc.muscle,
                    exerciseId: exercise.id,
                    defaultSetCount: slotDoc.defaultSetCount
                )
            }
            return CycleDay(label: dayDoc.label, slots: slots, position: dayIndex)
        }

        let quadsCompoundIds = Set(days
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

        return PublishedCycleTemplateDraft(name: doc.name, days: days, rotationPools: rotationPools)
    }

    private static func resolveExercise(
        slotDoc: PublishedCycleDocument.PublishedCycleSlot,
        byId: [UUID: Exercise],
        byName: [String: Exercise],
        byCanonicalName: [String: Exercise]
    ) throws -> Exercise {
        if let idText = slotDoc.exerciseId {
            guard let uuid = UUID(uuidString: idText) else {
                throw PublishedCycleError.invalidExerciseId(idText)
            }
            guard let exercise = byId[uuid] else {
                throw PublishedCycleError.unknownExerciseReference(idText)
            }
            return exercise
        }

        if let name = slotDoc.exerciseName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let exercise = byName[name.lowercased()] {
                return exercise
            }

            let canonical = canonicalizeName(name)
            if let exactCanonical = byCanonicalName[canonical] {
                return exactCanonical
            }

            for alias in aliasCandidates(for: canonical) {
                if let aliasMatch = byCanonicalName[alias] {
                    return aliasMatch
                }
            }

            let fuzzy = byCanonicalName.filter { key, _ in
                key.contains(canonical) || canonical.contains(key)
            }
            if fuzzy.count == 1, let only = fuzzy.first?.value {
                return only
            }

            throw PublishedCycleError.unknownExerciseReference(name)
        }

        throw PublishedCycleError.invalidFile("slot must include exerciseId or exerciseName")
    }

    private static func canonicalizeName(_ name: String) -> String {
        let lowered = name.lowercased()
        let normalizedTypos = lowered
            .replacingOccurrences(of: "dumbell", with: "dumbbell")
            .replacingOccurrences(of: "db", with: "dumbbell")
            .replacingOccurrences(of: "ez-bar", with: "ez bar")
            .replacingOccurrences(of: "ezbar", with: "ez bar")
            .replacingOccurrences(of: "single arm", with: "single-arm")
            .replacingOccurrences(of: "stiff leg", with: "stiff-leg")
        return normalizedTypos.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "" }
            .joined()
    }

    private static func aliasCandidates(for canonical: String) -> [String] {
        switch canonical {
        case "legpress":
            return ["45degreelegpress", "machinelegpress"]
        case "stifflegdeadlift":
            return ["stiffleggedeadlift", "sldl", "romaniandeadlift"]
        case "singlearmdumbbellrow":
            return ["singlearmdumbellrow", "onedumbbellrow", "singlearmdbrow"]
        case "dumbbellpreachercurl":
            return ["dumbellpreachercurl", "dbpreachercurl"]
        case "overheadezbarextension":
            return ["overheadezextension", "ezbaroverheadextension"]
        default:
            return []
        }
    }

    private static func ensureDirectory(at folder: URL) throws {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return
            }

            // Auto-heal invalid state where a file exists at the expected folder path.
            let backup = folder.deletingLastPathComponent()
                .appendingPathComponent("\(folder.lastPathComponent)-conflict-\(Int(Date().timeIntervalSince1970)).json")
            try fm.moveItem(at: folder, to: backup)
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

}

private struct PublishedCycleDocument: Decodable {
    let name: String
    let days: [PublishedCycleDay]

    struct PublishedCycleDay: Decodable {
        let label: String
        let slots: [PublishedCycleSlot]
    }

    struct PublishedCycleSlot: Decodable {
        let muscle: MuscleGroup
        let exerciseId: String?
        let exerciseName: String?
        let defaultSetCount: Int
    }
}
