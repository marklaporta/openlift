import Foundation
import SwiftData
import SwiftUI

struct ResistanceProfileValue: Codable, Equatable, Hashable, Sendable {
    let resistanceSource: ResistanceSource
    let chainType: VOLTRAChainType?
    let chainPercent: Int?
    let eccentricPercent: Int?

    static let weightStack = ResistanceProfileValue(
        resistanceSource: .weightStack,
        chainType: nil,
        chainPercent: nil,
        eccentricPercent: nil
    )

    static func voltra(
        chainType: VOLTRAChainType,
        chainPercent: Int,
        eccentricPercent: Int
    ) -> ResistanceProfileValue {
        ResistanceProfileValue(
            resistanceSource: .voltra,
            chainType: chainType,
            chainPercent: chainType == .none ? 0 : chainPercent,
            eccentricPercent: eccentricPercent
        )
    }

    var isComplete: Bool {
        switch resistanceSource {
        case .weightStack:
            return chainType == nil && chainPercent == nil && eccentricPercent == nil
        case .voltra:
            guard let chainType, let chainPercent, let eccentricPercent,
                  (0...100).contains(chainPercent),
                  (0...100).contains(eccentricPercent) else { return false }
            return chainType == .none ? chainPercent == 0 : true
        }
    }

    var displayName: String {
        switch resistanceSource {
        case .weightStack:
            return "Cable · Weight Stack"
        case .voltra:
            guard let chainType, let chainPercent, let eccentricPercent else {
                return "VOLTRA · Incomplete Profile"
            }
            let chain = chainType == .none
                ? "No Chains"
                : "\(chainType.displayName) \(chainPercent)%"
            return "VOLTRA · \(chain) · Eccentric \(eccentricPercent)%"
        }
    }
}

struct CableResistanceProfileControl: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let workoutKind: ResistanceProfileWorkoutKind
    let sessionId: UUID
    let exerciseId: UUID
    let occurrenceId: UUID?
    let profile: ExerciseResistanceProfile?
    let profiles: [ExerciseResistanceProfile]
    let isCompletedOccurrence: Bool
    let onError: (String) -> Void

    @State private var isEditing = false
    @State private var source: ResistanceSource
    @State private var chainType: VOLTRAChainType
    @State private var chainPercent: Int
    @State private var eccentricPercent: Int
    @State private var pendingFrozenSave = false

    init(
        workoutKind: ResistanceProfileWorkoutKind,
        sessionId: UUID,
        exerciseId: UUID,
        occurrenceId: UUID?,
        profile: ExerciseResistanceProfile?,
        profiles: [ExerciseResistanceProfile],
        isCompletedOccurrence: Bool = false,
        onError: @escaping (String) -> Void
    ) {
        self.workoutKind = workoutKind
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.occurrenceId = occurrenceId
        self.profile = profile
        self.profiles = profiles
        self.isCompletedOccurrence = isCompletedOccurrence
        self.onError = onError
        let initial = ResistanceProfileService.value(profile)
            ?? ResistanceProfileService.lastUsedValue(exerciseId: exerciseId, profiles: profiles)
            ?? .weightStack
        _source = State(initialValue: initial.resistanceSource)
        _chainType = State(initialValue: initial.chainType ?? .inverseChains)
        _chainPercent = State(initialValue: initial.chainPercent ?? 0)
        _eccentricPercent = State(initialValue: initial.eccentricPercent ?? 0)
    }

    var body: some View {
        Button {
            isEditing = true
        } label: {
            Label(
                ResistanceProfileService.value(profile)?.displayName ?? "Set Cable Resistance",
                systemImage: profile == nil ? "questionmark.circle" : "cable.connector"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(profile == nil ? .orange : .secondary)
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                Form {
                    Section("Resistance Source") {
                        Picker("Source", selection: $source) {
                            Text("Weight Stack").tag(ResistanceSource.weightStack)
                            Text("VOLTRA").tag(ResistanceSource.voltra)
                        }
                        .pickerStyle(.segmented)
                    }
                    if source == .voltra {
                        Section("VOLTRA Percentage Profile") {
                            Picker("Chain mode", selection: $chainType) {
                                ForEach(VOLTRAChainType.allCases, id: \.self) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            if chainType != .none {
                                Stepper("Chain: \(chainPercent)%", value: $chainPercent, in: 0...100, step: 5)
                            }
                            Stepper("Eccentric: \(eccentricPercent)%", value: $eccentricPercent, in: 0...100, step: 5)
                        }
                    }
                    Section {
                        Text(draftValue.displayName)
                            .foregroundStyle(.secondary)
                    } footer: {
                        if profile?.frozenAt != nil {
                            Text("This profile is frozen with the performed occurrence. Saving requires confirmation and corrects every set in this occurrence.")
                        } else if profile == nil && isCompletedOccurrence {
                            Text("This occurrence already has performed sets. Saving requires confirmation and records an occurrence-wide correction.")
                        }
                    }
                }
                .navigationTitle("Cable Resistance")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if (profile?.frozenAt != nil
                                && ResistanceProfileService.value(profile) != draftValue)
                                || (profile == nil && isCompletedOccurrence) {
                                pendingFrozenSave = true
                            } else {
                                save(confirmed: false)
                            }
                        }
                    }
                }
                .alert("Correct Entire Occurrence?", isPresented: $pendingFrozenSave) {
                    Button("Correct Profile", role: .destructive) { save(confirmed: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All performed sets in this exercise occurrence will be treated as \(draftValue.displayName).")
                }
            }
        }
    }

    private var draftValue: ResistanceProfileValue {
        source == .weightStack
            ? .weightStack
            : .voltra(
                chainType: chainType,
                chainPercent: chainPercent,
                eccentricPercent: eccentricPercent
            )
    }

    private func save(confirmed: Bool) {
        do {
            if let profile {
                try ResistanceProfileService.update(
                    profile,
                    to: draftValue,
                    confirmedOccurrenceWideCorrection: confirmed,
                    modelContext: modelContext
                )
            } else {
                if isCompletedOccurrence {
                    _ = try ResistanceProfileService.createPerformedOccurrence(
                        workoutKind: workoutKind,
                        sessionId: sessionId,
                        exerciseId: exerciseId,
                        occurrenceId: occurrenceId,
                        value: draftValue,
                        profiles: profiles,
                        confirmedOccurrenceWideCorrection: confirmed,
                        modelContext: modelContext
                    )
                } else {
                    _ = try ResistanceProfileService.create(
                        workoutKind: workoutKind,
                        sessionId: sessionId,
                        exerciseId: exerciseId,
                        occurrenceId: occurrenceId,
                        value: draftValue,
                        profiles: profiles,
                        modelContext: modelContext
                    )
                    try modelContext.save()
                }
            }
            isEditing = false
        } catch {
            onError(error.localizedDescription)
        }
    }
}

struct CableResistanceProfileDraftControl: View {
    @Binding var value: ResistanceProfileValue?
    @State private var isEditing = false
    @State private var source: ResistanceSource = .weightStack
    @State private var chainType: VOLTRAChainType = .inverseChains
    @State private var chainPercent = 0
    @State private var eccentricPercent = 0

    var body: some View {
        Button {
            if let value {
                source = value.resistanceSource
                chainType = value.chainType ?? .inverseChains
                chainPercent = value.chainPercent ?? 0
                eccentricPercent = value.eccentricPercent ?? 0
            }
            isEditing = true
        } label: {
            Label(
                value?.displayName ?? "Set Cable Resistance",
                systemImage: value == nil ? "questionmark.circle" : "cable.connector"
            )
            .font(.caption)
        }
        .foregroundStyle(value == nil ? .orange : .secondary)
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                Form {
                    Picker("Source", selection: $source) {
                        Text("Weight Stack").tag(ResistanceSource.weightStack)
                        Text("VOLTRA").tag(ResistanceSource.voltra)
                    }
                    .pickerStyle(.segmented)
                    if source == .voltra {
                        Picker("Chain mode", selection: $chainType) {
                            ForEach(VOLTRAChainType.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        if chainType != .none {
                            Stepper("Chain: \(chainPercent)%", value: $chainPercent, in: 0...100, step: 5)
                        }
                        Stepper("Eccentric: \(eccentricPercent)%", value: $eccentricPercent, in: 0...100, step: 5)
                    }
                    Text(draftValue.displayName).foregroundStyle(.secondary)
                }
                .navigationTitle("Cable Resistance")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            value = draftValue
                            isEditing = false
                        }
                    }
                }
            }
        }
    }

    private var draftValue: ResistanceProfileValue {
        source == .weightStack
            ? .weightStack
            : .voltra(
                chainType: chainType,
                chainPercent: chainPercent,
                eccentricPercent: eccentricPercent
            )
    }
}

enum ResistanceProfileComparison: String, Codable, Equatable, Sendable {
    case exact
    case different
    case unknown

    static func compare(
        current: ResistanceProfileValue?,
        historical: ResistanceProfileValue?
    ) -> ResistanceProfileComparison {
        guard let current, current.isComplete,
              let historical, historical.isComplete else { return .unknown }
        return current == historical ? .exact : .different
    }
}

enum ResistanceProfileError: LocalizedError, Equatable {
    case incomplete
    case invalidOccurrenceIdentity
    case duplicateOccurrence
    case frozenConfirmationRequired
    case profileRequiredBeforeLock
    case emptyManifest
    case auditCountMismatch(expected: Int, actual: Int)
    case manifestMismatch
    case conflictingExistingProfile

    var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Choose a complete cable resistance profile."
        case .invalidOccurrenceIdentity:
            return "The resistance profile does not identify one performed exercise occurrence."
        case .duplicateOccurrence:
            return "More than one resistance profile exists for this exercise occurrence."
        case .frozenConfirmationRequired:
            return "This occurrence already has performed sets. Confirm an occurrence-wide correction before changing its resistance profile."
        case .profileRequiredBeforeLock:
            return "Choose Weight Stack or a complete VOLTRA profile before locking the first cable set."
        case .emptyManifest:
            return "Historical resistance repair is disabled until an exact reviewed manifest is supplied."
        case .auditCountMismatch(let expected, let actual):
            return "Historical audit found \(actual) candidate occurrences; expected exactly \(expected)."
        case .manifestMismatch:
            return "The historical manifest does not exactly match the audited occurrence keys and set counts."
        case .conflictingExistingProfile:
            return "An audited occurrence already has a different resistance profile."
        }
    }
}

enum ResistanceProfileService {
    static func value(_ profile: ExerciseResistanceProfile?) -> ResistanceProfileValue? {
        guard let profile else { return nil }
        let value = ResistanceProfileValue(
            resistanceSource: profile.resistanceSource,
            chainType: profile.chainType,
            chainPercent: profile.chainPercent,
            eccentricPercent: profile.eccentricPercent
        )
        return value.isComplete ? value : nil
    }

    static func profile(
        workoutKind: ResistanceProfileWorkoutKind,
        sessionId: UUID,
        exerciseId: UUID,
        occurrenceId: UUID?,
        in profiles: [ExerciseResistanceProfile]
    ) throws -> ExerciseResistanceProfile? {
        let matches = profiles.filter {
            $0.workoutKind == workoutKind
                && $0.sessionId == sessionId
                && $0.exerciseId == exerciseId
                && $0.occurrenceId == occurrenceId
        }
        guard matches.count <= 1 else { throw ResistanceProfileError.duplicateOccurrence }
        return matches.first
    }

    /// Exercise-specific history wins. The global cable fallback intentionally
    /// carries Mark's usually-stable VOLTRA setting across movements while
    /// still making a per-occurrence copy that can later be corrected.
    static func lastUsedValue(
        exerciseId: UUID,
        profiles: [ExerciseResistanceProfile]
    ) -> ResistanceProfileValue? {
        let complete = profiles.filter { value($0) != nil }
        let preferred = complete.filter { $0.exerciseId == exerciseId }
        return value((preferred.isEmpty ? complete : preferred).max {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        })
    }

    @MainActor
    @discardableResult
    static func create(
        workoutKind: ResistanceProfileWorkoutKind,
        sessionId: UUID,
        exerciseId: UUID,
        occurrenceId: UUID? = nil,
        value: ResistanceProfileValue,
        profiles: [ExerciseResistanceProfile],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> ExerciseResistanceProfile {
        guard value.isComplete else { throw ResistanceProfileError.incomplete }
        guard (workoutKind == .adaptive) == (occurrenceId != nil) else {
            throw ResistanceProfileError.invalidOccurrenceIdentity
        }
        if let existing = try profile(
            workoutKind: workoutKind,
            sessionId: sessionId,
            exerciseId: exerciseId,
            occurrenceId: occurrenceId,
            in: profiles
        ) {
            return existing
        }
        let profile = ExerciseResistanceProfile(
            workoutKind: workoutKind,
            sessionId: sessionId,
            exerciseId: exerciseId,
            occurrenceId: occurrenceId,
            resistanceSource: value.resistanceSource,
            chainType: value.chainType,
            chainPercent: value.chainPercent,
            eccentricPercent: value.eccentricPercent,
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(profile)
        return profile
    }

    @MainActor
    @discardableResult
    static func createPerformedOccurrence(
        workoutKind: ResistanceProfileWorkoutKind,
        sessionId: UUID,
        exerciseId: UUID,
        occurrenceId: UUID? = nil,
        value: ResistanceProfileValue,
        profiles: [ExerciseResistanceProfile],
        confirmedOccurrenceWideCorrection: Bool,
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> ExerciseResistanceProfile {
        guard confirmedOccurrenceWideCorrection else {
            throw ResistanceProfileError.frozenConfirmationRequired
        }
        let profile = try create(
            workoutKind: workoutKind,
            sessionId: sessionId,
            exerciseId: exerciseId,
            occurrenceId: occurrenceId,
            value: value,
            profiles: profiles,
            modelContext: modelContext,
            now: now
        )
        profile.frozenAt = now
        profile.updatedAt = now
        try markExportPending(for: profile, modelContext: modelContext)
        try modelContext.save()
        SessionExportService.scheduleBackgroundExportRetry()
        return profile
    }

    @MainActor
    static func update(
        _ profile: ExerciseResistanceProfile,
        to value: ResistanceProfileValue,
        confirmedOccurrenceWideCorrection: Bool,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard value.isComplete else { throw ResistanceProfileError.incomplete }
        guard Self.value(profile) != value else { return }
        guard profile.frozenAt == nil || confirmedOccurrenceWideCorrection else {
            throw ResistanceProfileError.frozenConfirmationRequired
        }

        switch profile.workoutKind {
        case .fixed, .adHoc:
            for entry in try modelContext.fetch(FetchDescriptor<SetEntry>())
            where entry.sessionId == profile.sessionId
                && entry.exerciseId == profile.exerciseId
                && !entry.isLocked {
                entry.weight = 0
                entry.reps = 0
            }
        case .adaptive:
            for entry in try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>())
            where entry.adaptiveSessionId == profile.sessionId
                && entry.occurrenceId == profile.occurrenceId
                && !entry.isLocked {
                entry.weight = 0
                entry.reps = 0
            }
        }

        profile.resistanceSource = value.resistanceSource
        profile.chainType = value.chainType
        profile.chainPercent = value.chainPercent
        profile.eccentricPercent = value.eccentricPercent
        profile.updatedAt = now
        if profile.frozenAt != nil {
            try markExportPending(for: profile, modelContext: modelContext)
        }
        try modelContext.save()
        if profile.frozenAt != nil {
            SessionExportService.scheduleBackgroundExportRetry()
        }
    }

    @MainActor
    static func freezeBeforeLock(
        _ profile: ExerciseResistanceProfile?,
        modelContext: ModelContext,
        now: Date = .now
    ) throws {
        guard let profile, value(profile) != nil else {
            throw ResistanceProfileError.profileRequiredBeforeLock
        }
        if profile.frozenAt == nil {
            profile.frozenAt = now
            profile.updatedAt = now
            try modelContext.save()
        }
    }

    @MainActor
    private static func markExportPending(
        for profile: ExerciseResistanceProfile,
        modelContext: ModelContext
    ) throws {
        switch profile.workoutKind {
        case .fixed, .adHoc:
            try modelContext.fetch(FetchDescriptor<Session>())
                .first(where: { $0.id == profile.sessionId })?
                .exportStatus = .pending
        case .adaptive:
            try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
                .first(where: { $0.id == profile.sessionId })?
                .exportStatus = .pending
        }
    }
}

struct ResistanceProfilePayload: Codable, Equatable, Sendable {
    let resistance_source: String
    let chain_type: String?
    let chain_percent: Int?
    let eccentric_percent: Int?

    init(_ value: ResistanceProfileValue) {
        resistance_source = value.resistanceSource.rawValue
        chain_type = value.chainType?.rawValue
        chain_percent = value.chainPercent
        eccentric_percent = value.eccentricPercent
    }

    var value: ResistanceProfileValue? {
        guard let source = ResistanceSource(rawValue: resistance_source) else { return nil }
        let decoded = ResistanceProfileValue(
            resistanceSource: source,
            chainType: chain_type.flatMap(VOLTRAChainType.init(rawValue:)),
            chainPercent: chain_percent,
            eccentricPercent: eccentric_percent
        )
        return decoded.isComplete ? decoded : nil
    }
}

enum HistoricalResistanceProfileMigration {
    static let expectedCandidateCount = 24
    static let latPulldownExerciseId = UUID(uuidString: "54214942-679D-4CBB-9B27-F78601897BA2")!
    static let preAugust3SessionPrefixes = [
        "8DC5D239", "0DADB7CE", "476348F2", "86B9C09E", "9814E290",
        "D21627D8", "78F895B2", "08476AD8", "887431EA"
    ]
    static let august3SessionId = UUID(uuidString: "FF0623F5-92DF-484A-857F-A4FEFC540AD9")!
    static let latPulldownSessionIds: Set<UUID> = [
        UUID(uuidString: "0DADB7CE-573E-477E-8838-E6D69A27ED3C")!,
        UUID(uuidString: "D21627D8-34D5-4044-990A-6B7C036E230F")!,
        UUID(uuidString: "08476AD8-9550-4A33-94DF-55B12E6161F2")!,
        UUID(uuidString: "FBE13920-FF2C-437F-8A38-C09CF1409C09")!,
        UUID(uuidString: "317EE106-323C-405B-A110-260870F22993")!
    ]
    static let latestLatPulldownSessionId = UUID(uuidString: "317EE106-323C-405B-A110-260870F22993")!

    struct OccurrenceKey: Codable, Equatable, Hashable, Sendable {
        let workoutKind: ResistanceProfileWorkoutKind
        let sessionId: UUID
        let exerciseId: UUID
        let occurrenceId: UUID?
    }

    struct Candidate: Codable, Equatable, Sendable {
        let key: OccurrenceKey
        let exerciseName: String
        let performedSetCount: Int
        let intendedProfile: ResistanceProfileValue
    }

    struct AuditReport: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let generatedAt: Date
        let expectedCandidateCount: Int
        let candidates: [Candidate]
        let isExactExpectedCount: Bool
    }

    struct ManifestEntry: Codable, Equatable, Sendable {
        let key: OccurrenceKey
        let exerciseName: String
        let expectedPerformedSetCount: Int
        let profile: ResistanceProfileValue
    }

    struct ApplicationResult: Equatable, Sendable {
        enum Status: String, Equatable, Sendable {
            case applied
            case alreadyApplied = "already_applied"
        }

        let status: Status
        let auditedCandidateCount: Int
        let createdProfileCount: Int
        let repairedSessionCount: Int
        let repairedSessionIds: Set<UUID>
    }

    /// Frozen from the reviewed device audits on 2026-08-04. Do not add an
    /// occurrence here without a separately reviewed device audit.
    static let reviewedManifest: [ManifestEntry] = [
        manifestEntry(.adaptive, "08476AD8-9550-4A33-94DF-55B12E6161F2", "87A21249-FE4B-4C3E-8F5B-E02944C57263", "ED4C9952-8F7D-42A1-9928-8FF5265463D8", "Chest Supported Cable Row", 3),
        manifestEntry(.adaptive, "0DADB7CE-573E-477E-8838-E6D69A27ED3C", "17BC2F9D-F0A2-4604-AA41-33ADD79ED16B", "D9C9805E-A95A-45F8-B674-7A1FCF639626", "Overhead Single-Arm Cable Extension", 2),
        manifestEntry(.adaptive, "476348F2-D693-40B6-8761-866676A20676", "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3", "0EE78BC6-6514-40C9-A401-FE0A7DD6CFB6", "Cable Lateral Raise", 2),
        manifestEntry(.adaptive, "78F895B2-10DE-4AAA-AD74-97AB243C52E1", "81739325-64CA-4686-B2D5-72A310832DA0", "1BCE6A23-AD9B-4C60-BF5F-AA6CCFCD170E", "Cable Crossover Lateral Raise", 3),
        manifestEntry(.adaptive, "78F895B2-10DE-4AAA-AD74-97AB243C52E1", "742E75C7-9F97-4F1A-AB41-896B10402731", "E4217C1E-A0D6-43F2-B70B-2BFE08B12DF5", "Cable Preacher Curl", 3),
        manifestEntry(.adaptive, "86B9C09E-B52A-4864-B715-D5745CED523A", "17BC2F9D-F0A2-4604-AA41-33ADD79ED16B", "30E35887-912A-4C45-BBCE-9160C3EEB284", "Overhead Single-Arm Cable Extension", 2),
        manifestEntry(.adaptive, "86B9C09E-B52A-4864-B715-D5745CED523A", "27FC2511-A469-438D-8E46-6C6D99B30F42", "9DA39594-9DAB-4E10-8521-5A008A642F4F", "Lat Prayer", 2),
        manifestEntry(.adaptive, "86B9C09E-B52A-4864-B715-D5745CED523A", "87A21249-FE4B-4C3E-8F5B-E02944C57263", "CDBB2B7B-B081-436A-8DF1-AE2733008295", "Chest Supported Cable Row", 2),
        manifestEntry(.fixed, "887431EA-2E20-45A3-A3FD-B1B65383961C", "17BC2F9D-F0A2-4604-AA41-33ADD79ED16B", nil, "Overhead Single-Arm Cable Extension", 3),
        manifestEntry(.fixed, "887431EA-2E20-45A3-A3FD-B1B65383961C", "31714E52-46E3-4080-8403-222537D68E10", nil, "Incline Cable Flye", 3),
        manifestEntry(.fixed, "887431EA-2E20-45A3-A3FD-B1B65383961C", "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3", nil, "Cable Lateral Raise", 3),
        manifestEntry(.adHoc, "8DC5D239-F5FB-4E0F-B181-DF1F8EA5B52B", "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3", nil, "Cable Lateral Raise", 1),
        manifestEntry(.adHoc, "8DC5D239-F5FB-4E0F-B181-DF1F8EA5B52B", "E27608C0-2EFD-436C-A01E-BAF327F44055", nil, "Bayesian Curl", 1),
        manifestEntry(.adaptive, "9814E290-49A9-480C-B654-85B7D61F05CF", "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3", "9604D053-19FF-4BB7-BF2F-A3C5410AC49D", "Cable Lateral Raise", 3),
        manifestEntry(.adaptive, "9814E290-49A9-480C-B654-85B7D61F05CF", "E27608C0-2EFD-436C-A01E-BAF327F44055", "BB3F4A65-F304-4667-8B2E-3329572DD1F5", "Bayesian Curl", 3),
        manifestEntry(.adaptive, "D21627D8-34D5-4044-990A-6B7C036E230F", "87A21249-FE4B-4C3E-8F5B-E02944C57263", "E5347F42-3AC1-4817-ABFE-34A858DD921B", "Chest Supported Cable Row", 3),
        manifestEntry(.adaptive, "D21627D8-34D5-4044-990A-6B7C036E230F", "8C24C3C7-EB71-4523-BA0C-BB22B1F8CE7D", "F47ABA45-6FB0-40F3-90F4-433851F29B3D", "Cable Pushdown", 4),
        manifestEntry(.fixed, "FF0623F5-92DF-484A-857F-A4FEFC540AD9", "8C24C3C7-EB71-4523-BA0C-BB22B1F8CE7D", nil, "Cable Pushdown", 3, chainPercent: 70, eccentricPercent: 30),
        manifestEntry(.fixed, "FF0623F5-92DF-484A-857F-A4FEFC540AD9", "C7CAFFE5-CBF9-44B3-94BA-DE29FD8F94E3", nil, "Cable Lateral Raise", 3, chainPercent: 70, eccentricPercent: 30),
        manifestEntry(.adaptive, "0DADB7CE-573E-477E-8838-E6D69A27ED3C", "54214942-679D-4CBB-9B27-F78601897BA2", "E7045F23-F2CC-4295-B2BC-AEEEC19F72B4", "Lat Pulldown", 2),
        manifestEntry(.adaptive, "D21627D8-34D5-4044-990A-6B7C036E230F", "54214942-679D-4CBB-9B27-F78601897BA2", "4AACD4E1-DB9F-4BB4-B918-E51415CE3D95", "Lat Pulldown", 3),
        manifestEntry(.adaptive, "08476AD8-9550-4A33-94DF-55B12E6161F2", "54214942-679D-4CBB-9B27-F78601897BA2", "F77E334D-C843-45C1-84AD-68762C87DA4D", "Lat Pulldown", 3),
        manifestEntry(.fixed, "FBE13920-FF2C-437F-8A38-C09CF1409C09", "54214942-679D-4CBB-9B27-F78601897BA2", nil, "Lat Pulldown", 3),
        manifestEntry(.fixed, "317EE106-323C-405B-A110-260870F22993", "54214942-679D-4CBB-9B27-F78601897BA2", nil, "Lat Pulldown", 3, chainPercent: 30, eccentricPercent: 70)
    ]

    private static func manifestEntry(
        _ workoutKind: ResistanceProfileWorkoutKind,
        _ sessionId: String,
        _ exerciseId: String,
        _ occurrenceId: String?,
        _ exerciseName: String,
        _ expectedPerformedSetCount: Int,
        chainPercent: Int = 25,
        eccentricPercent: Int = 25
    ) -> ManifestEntry {
        ManifestEntry(
            key: OccurrenceKey(
                workoutKind: workoutKind,
                sessionId: UUID(uuidString: sessionId)!,
                exerciseId: UUID(uuidString: exerciseId)!,
                occurrenceId: occurrenceId.flatMap(UUID.init(uuidString:))
            ),
            exerciseName: exerciseName,
            expectedPerformedSetCount: expectedPerformedSetCount,
            profile: .voltra(
                chainType: .inverseChains,
                chainPercent: chainPercent,
                eccentricPercent: eccentricPercent
            )
        )
    }

    static func audit(
        sessions: [Session],
        setEntries: [SetEntry],
        adaptiveSessions: [AdaptiveWorkoutSession],
        adaptiveSetEntries: [AdaptiveSetEntry],
        exercises: [Exercise],
        now: Date = .now
    ) -> AuditReport {
        let exerciseById = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        func intended(_ id: UUID) -> ResistanceProfileValue {
            id == latestLatPulldownSessionId
                ? .voltra(chainType: .inverseChains, chainPercent: 30, eccentricPercent: 70)
                : id == august3SessionId
                ? .voltra(chainType: .inverseChains, chainPercent: 70, eccentricPercent: 30)
                : .voltra(chainType: .inverseChains, chainPercent: 25, eccentricPercent: 25)
        }
        func selected(_ id: UUID) -> Bool {
            id == august3SessionId
                || preAugust3SessionPrefixes.contains { id.uuidString.hasPrefix($0) }
        }

        var candidates: [Candidate] = []
        for session in sessions where session.status == .completed
            && (selected(session.id) || latPulldownSessionIds.contains(session.id)) {
            let grouped = Dictionary(grouping: setEntries.filter {
                $0.sessionId == session.id && $0.isLocked && $0.reps > 0
            }, by: \SetEntry.exerciseId)
            for (exerciseId, rows) in grouped {
                guard let exercise = exerciseById[exerciseId],
                      Set(rows.map(\.setIndex)) == Set(1...rows.count),
                      (selected(session.id) && exercise.equipment == .cable
                        || latPulldownSessionIds.contains(session.id)
                            && exerciseId == latPulldownExerciseId) else { continue }
                candidates.append(
                    Candidate(
                        key: OccurrenceKey(
                            workoutKind: session.dayLabelSnapshot == "Off-Schedule" ? .adHoc : .fixed,
                            sessionId: session.id,
                            exerciseId: exerciseId,
                            occurrenceId: nil
                        ),
                        exerciseName: exercise.name,
                        performedSetCount: rows.count,
                        intendedProfile: intended(session.id)
                    )
                )
            }
        }
        for session in adaptiveSessions where session.status == .completed
            && (selected(session.id) || latPulldownSessionIds.contains(session.id)) {
            let grouped = Dictionary(grouping: adaptiveSetEntries.filter {
                $0.adaptiveSessionId == session.id && $0.isLocked && $0.reps > 0
            }, by: \AdaptiveSetEntry.occurrenceId)
            for (occurrenceId, rows) in grouped {
                guard let exerciseId = rows.first?.exerciseId,
                      rows.allSatisfy({ $0.exerciseId == exerciseId }),
                      Set(rows.map(\.setIndex)) == Set(1...rows.count),
                      let exercise = exerciseById[exerciseId],
                      (selected(session.id) && exercise.equipment == .cable
                        || latPulldownSessionIds.contains(session.id)
                            && exerciseId == latPulldownExerciseId) else { continue }
                candidates.append(
                    Candidate(
                        key: OccurrenceKey(
                            workoutKind: .adaptive,
                            sessionId: session.id,
                            exerciseId: exerciseId,
                            occurrenceId: occurrenceId
                        ),
                        exerciseName: exercise.name,
                        performedSetCount: rows.count,
                        intendedProfile: intended(session.id)
                    )
                )
            }
        }
        candidates.sort {
            let left = "\($0.key.sessionId.uuidString)|\($0.key.occurrenceId?.uuidString ?? "")|\($0.key.exerciseId.uuidString)"
            let right = "\($1.key.sessionId.uuidString)|\($1.key.occurrenceId?.uuidString ?? "")|\($1.key.exerciseId.uuidString)"
            return left < right
        }
        return AuditReport(
            schemaVersion: 1,
            generatedAt: now,
            expectedCandidateCount: expectedCandidateCount,
            candidates: candidates,
            isExactExpectedCount: candidates.count == expectedCandidateCount
        )
    }

    /// This is deliberately separate from `audit`: tests and callers can inspect
    /// the report without touching iCloud. The app may explicitly publish the
    /// read-only result to the same durable mirror used for exports.
    @discardableResult
    static func writeAuditReport(
        _ report: AuditReport,
        environment: SessionExportService.ExportEnvironment = .live()
    ) throws -> SessionExportService.ExportWriteOutcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try SessionExportService.writeExportData(
            data: try encoder.encode(report),
            relativeSubdirectory: "audits",
            filename: "voltra-resistance-profile-audit.json",
            requireICloudMirror: true,
            environment: environment
        )
    }

    @MainActor
    static func runAtStartup(
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> ApplicationResult {
        let existingProfiles = try modelContext.fetch(FetchDescriptor<ExerciseResistanceProfile>())
        if let complete = try alreadyAppliedResult(existingProfiles: existingProfiles) {
            return complete
        }
        let report = audit(
            sessions: try modelContext.fetch(FetchDescriptor<Session>()),
            setEntries: try modelContext.fetch(FetchDescriptor<SetEntry>()),
            adaptiveSessions: try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>()),
            adaptiveSetEntries: try modelContext.fetch(FetchDescriptor<AdaptiveSetEntry>()),
            exercises: try modelContext.fetch(FetchDescriptor<Exercise>()),
            now: now
        )
        return try applyReviewedManifest(
            audit: report,
            existingProfiles: existingProfiles,
            modelContext: modelContext,
            now: now
        )
    }

    private static func alreadyAppliedResult(
        existingProfiles: [ExerciseResistanceProfile]
    ) throws -> ApplicationResult? {
        for item in reviewedManifest {
            guard let existing = try ResistanceProfileService.profile(
                workoutKind: item.key.workoutKind,
                sessionId: item.key.sessionId,
                exerciseId: item.key.exerciseId,
                occurrenceId: item.key.occurrenceId,
                in: existingProfiles
            ) else { return nil }
            guard ResistanceProfileService.value(existing) == item.profile else {
                throw ResistanceProfileError.conflictingExistingProfile
            }
        }
        return ApplicationResult(
            status: .alreadyApplied,
            auditedCandidateCount: expectedCandidateCount,
            createdProfileCount: 0,
            repairedSessionCount: 0,
            repairedSessionIds: []
        )
    }

    @MainActor
    @discardableResult
    static func applyReviewedManifest(
        _ manifest: [ManifestEntry] = reviewedManifest,
        audit report: AuditReport,
        existingProfiles: [ExerciseResistanceProfile],
        modelContext: ModelContext,
        now: Date = .now
    ) throws -> ApplicationResult {
        guard !manifest.isEmpty else { throw ResistanceProfileError.emptyManifest }
        guard report.schemaVersion == 1,
              report.expectedCandidateCount == expectedCandidateCount,
              report.isExactExpectedCount,
              report.candidates.count == expectedCandidateCount else {
            throw ResistanceProfileError.auditCountMismatch(
                expected: expectedCandidateCount,
                actual: report.candidates.count
            )
        }
        let manifestGroups = Dictionary(grouping: manifest, by: \.key)
        let candidateGroups = Dictionary(grouping: report.candidates, by: \.key)
        guard manifestGroups.values.allSatisfy({ $0.count == 1 }),
              candidateGroups.values.allSatisfy({ $0.count == 1 }) else {
            throw ResistanceProfileError.manifestMismatch
        }
        let manifestByKey = manifestGroups.compactMapValues(\.first)
        let candidatesByKey = candidateGroups.compactMapValues(\.first)
        guard manifestByKey.count == manifest.count,
              Set(manifestByKey.keys) == Set(candidatesByKey.keys),
              manifest.allSatisfy({ item in
                  guard let candidate = candidatesByKey[item.key] else { return false }
                  return item.exerciseName == candidate.exerciseName
                      && item.expectedPerformedSetCount == candidate.performedSetCount
                      && item.profile == candidate.intendedProfile
                      && item.profile.isComplete
              }) else { throw ResistanceProfileError.manifestMismatch }

        for item in manifest {
            if let existing = try ResistanceProfileService.profile(
                workoutKind: item.key.workoutKind,
                sessionId: item.key.sessionId,
                exerciseId: item.key.exerciseId,
                occurrenceId: item.key.occurrenceId,
                in: existingProfiles
            ) {
                guard ResistanceProfileService.value(existing) == item.profile else {
                    throw ResistanceProfileError.conflictingExistingProfile
                }
            }
        }

        let missingItems = manifest.filter { item in
            !existingProfiles.contains(where: {
                $0.workoutKind == item.key.workoutKind
                    && $0.sessionId == item.key.sessionId
                    && $0.exerciseId == item.key.exerciseId
                    && $0.occurrenceId == item.key.occurrenceId
            })
        }
        guard !missingItems.isEmpty else {
            return ApplicationResult(
                status: .alreadyApplied,
                auditedCandidateCount: report.candidates.count,
                createdProfileCount: 0,
                repairedSessionCount: 0,
                repairedSessionIds: []
            )
        }

        do {
            for item in missingItems {
                let profileNow = item.key.sessionId == latestLatPulldownSessionId
                    ? now
                    : now.addingTimeInterval(-1)
                let created = try ResistanceProfileService.create(
                    workoutKind: item.key.workoutKind,
                    sessionId: item.key.sessionId,
                    exerciseId: item.key.exerciseId,
                    occurrenceId: item.key.occurrenceId,
                    value: item.profile,
                    profiles: existingProfiles,
                    modelContext: modelContext,
                    now: profileNow
                )
                created.frozenAt = now
            }
            let repairedSessionIds = Set(missingItems.map { $0.key.sessionId })
            for session in try modelContext.fetch(FetchDescriptor<Session>())
            where repairedSessionIds.contains(session.id) && session.status == .completed {
                session.exportStatus = .pending
            }
            for session in try modelContext.fetch(FetchDescriptor<AdaptiveWorkoutSession>())
            where repairedSessionIds.contains(session.id) && session.status == .completed {
                session.exportStatus = .pending
            }
            try modelContext.save()
            return ApplicationResult(
                status: .applied,
                auditedCandidateCount: report.candidates.count,
                createdProfileCount: missingItems.count,
                repairedSessionCount: repairedSessionIds.count,
                repairedSessionIds: repairedSessionIds
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
