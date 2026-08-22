import Foundation
import SwiftData

/// The schema shipped before Adaptive programming was introduced.
///
/// These are intentionally the existing model types so an unversioned OpenLift
/// store retains the same entity identities and schema checksum when it is first
/// opened with an explicit migration plan.
enum OpenLiftSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        Exercise.self,
        CycleSlot.self,
        CycleDay.self,
        RotationPoolEntry.self,
        RotationPool.self,
        CycleTemplate.self,
        RotationIndex.self,
        ActiveCycleInstance.self,
        Session.self,
        SetEntry.self,
        SessionSlotOverride.self
    ]
}

/// Adds the selected programming mode without changing any legacy entity.
/// A missing preference row is intentionally interpreted as Fixed Cycle.
enum OpenLiftSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV1.models + [
        TrainingPreference.self
    ]
}

/// Adds the versioned Adaptive configuration domain as parallel records. The
/// Rotation session and cycle entities remain byte-for-byte unchanged.
enum OpenLiftSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    /// Frozen at the V3 shape because V11 makes eagerness systemic and leaves
    /// the per-muscle value only for legacy rows.
    @Model
    final class AdaptiveReadinessResponse {
        @Attribute(.unique) var id: UUID
        var muscle: MuscleGroup
        var soreness: SorenessLevel
        var connectiveTissuePain: ConnectiveTissuePainLevel
        var eagerness: EagernessLevel

        init(
            id: UUID = UUID(),
            muscle: MuscleGroup,
            soreness: SorenessLevel,
            connectiveTissuePain: ConnectiveTissuePainLevel,
            eagerness: EagernessLevel
        ) {
            self.id = id
            self.muscle = muscle
            self.soreness = soreness
            self.connectiveTissuePain = connectiveTissuePain
            self.eagerness = eagerness
        }
    }

    @Model
    final class DailyReadinessCheck {
        @Attribute(.unique) var id: UUID
        var localDateKey: String
        var timeZoneIdentifier: String
        var revision: Int
        var createdAt: Date
        var adaptiveProgramId: UUID
        var adaptiveProgramVersion: Int
        @Relationship(deleteRule: .cascade) var responses: [AdaptiveReadinessResponse]

        init(
            id: UUID = UUID(),
            localDateKey: String,
            timeZoneIdentifier: String,
            revision: Int,
            createdAt: Date = .now,
            adaptiveProgramId: UUID,
            adaptiveProgramVersion: Int,
            responses: [AdaptiveReadinessResponse]
        ) {
            self.id = id
            self.localDateKey = localDateKey
            self.timeZoneIdentifier = timeZoneIdentifier
            self.revision = revision
            self.createdAt = createdAt
            self.adaptiveProgramId = adaptiveProgramId
            self.adaptiveProgramVersion = adaptiveProgramVersion
            self.responses = responses
        }
    }

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV2.models + [
        AdaptiveMuscleRule.self,
        AdaptiveComplexComponent.self,
        AdaptiveExerciseComplex.self,
        AdaptiveProgram.self,
        OpenLiftSchemaV3.AdaptiveReadinessResponse.self,
        OpenLiftSchemaV3.DailyReadinessCheck.self,
        PlannedExerciseSnapshot.self,
        PlannedComplexSnapshot.self,
        GeneratedWorkoutPlan.self,
        AdaptiveWorkoutSession.self,
        AdaptiveSetEntry.self,
        AdaptiveSetOccurrenceLink.self,
        ComplexFeedback.self,
        AdHocExerciseFeedback.self,
        AdaptiveOverrideEvent.self
    ]
}

/// Adds per-muscle exercise continuity and rotation preferences without
/// changing any V3 entity or workout-history record.
enum OpenLiftSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV3.models + [
        AdaptiveExerciseSelectionPreference.self
    ]
}

/// Adds durable iCloud export diagnostics without changing workout entities.
enum OpenLiftSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV4.models + [
        ExportDiagnostic.self
    ]
}

/// Adds explicit exposure-count preferences and per-proposal design state as
/// parallel records. Existing AdaptiveProgram and workout entities are unchanged.
enum OpenLiftSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV5.models + [
        AdaptiveWorkoutSizePreference.self,
        AdaptivePlanDesignState.self
    ]
}

/// Adds the set-rate controller as parallel configuration and anchor records.
/// Existing program graphs, sessions, set rows, and export snapshots are not
/// modified by this migration.
enum OpenLiftSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV6.models + [
        AdaptiveMuscleVolumeTarget.self,
        AdaptiveWorkoutCapacityPreference.self,
        AdaptiveMuscleVolumeAnchor.self
    ]
}

/// Replaces weekly target/debt planning with editable per-exposure doses and
/// recovery clocks. V7 records remain in the schema as inert compatibility
/// data; no completed session or set entity is rewritten.
enum OpenLiftSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV7.models + [
        AdaptiveMuscleExposureConfiguration.self
    ]
}

private let currentSetEntryModel = SetEntry.self
private let currentAdaptiveSetEntryModel = AdaptiveSetEntry.self

/// Adds Fixed Cycle readiness audit records, occurrence-only skip provenance,
/// and immutable ordered occurrence snapshots as parallel entities. No shipped
/// V1-V8 entity is altered.
enum OpenLiftSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    /// Frozen copies preserve the schema checksum shipped in V9 now that the
    /// live V10 models carry `lockedAt`.
    @Model
    final class SetEntry {
        @Attribute(.unique) var id: UUID
        var sessionId: UUID
        var exerciseId: UUID
        var setIndex: Int
        var weight: Double
        var reps: Int
        var isLocked: Bool = false

        init(
            id: UUID = UUID(),
            sessionId: UUID,
            exerciseId: UUID,
            setIndex: Int,
            weight: Double,
            reps: Int,
            isLocked: Bool = false
        ) {
            self.id = id
            self.sessionId = sessionId
            self.exerciseId = exerciseId
            self.setIndex = setIndex
            self.weight = weight
            self.reps = reps
            self.isLocked = isLocked
        }
    }

    @Model
    final class AdaptiveSetEntry {
        @Attribute(.unique) var id: UUID
        var adaptiveSessionId: UUID
        var occurrenceId: UUID
        var exerciseId: UUID
        var setIndex: Int
        var weight: Double
        var reps: Int
        var isLocked: Bool

        init(
            id: UUID = UUID(),
            adaptiveSessionId: UUID,
            occurrenceId: UUID,
            exerciseId: UUID,
            setIndex: Int,
            weight: Double = 0,
            reps: Int = 0,
            isLocked: Bool = false
        ) {
            self.id = id
            self.adaptiveSessionId = adaptiveSessionId
            self.occurrenceId = occurrenceId
            self.exerciseId = exerciseId
            self.setIndex = setIndex
            self.weight = weight
            self.reps = reps
            self.isLocked = isLocked
        }
    }

    /// Frozen at the V9 shape because V11 adds systemic eagerness and makes the
    /// per-muscle eagerness value optional for newly written observations.
    @Model
    final class FixedCycleReadinessObservation {
        @Attribute(.unique) var id: UUID
        var sessionId: UUID
        var localDateKey: String
        var timeZoneIdentifier: String
        var revision: Int
        var createdAt: Date
        @Relationship(deleteRule: .cascade) var responses: [FixedCycleReadinessResponse]

        init(
            id: UUID = UUID(),
            sessionId: UUID,
            localDateKey: String,
            timeZoneIdentifier: String,
            revision: Int,
            createdAt: Date = .now,
            responses: [FixedCycleReadinessResponse]
        ) {
            self.id = id
            self.sessionId = sessionId
            self.localDateKey = localDateKey
            self.timeZoneIdentifier = timeZoneIdentifier
            self.revision = revision
            self.createdAt = createdAt
            self.responses = responses
        }
    }

    @Model
    final class FixedCycleReadinessResponse {
        @Attribute(.unique) var id: UUID
        var muscle: MuscleGroup
        var soreness: SorenessLevel
        var connectiveTissuePain: ConnectiveTissuePainLevel
        var eagerness: EagernessLevel

        init(
            id: UUID = UUID(),
            muscle: MuscleGroup,
            soreness: SorenessLevel,
            connectiveTissuePain: ConnectiveTissuePainLevel,
            eagerness: EagernessLevel
        ) {
            self.id = id
            self.muscle = muscle
            self.soreness = soreness
            self.connectiveTissuePain = connectiveTissuePain
            self.eagerness = eagerness
        }
    }

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV8.models.filter {
        ObjectIdentifier($0) != ObjectIdentifier(currentSetEntryModel)
            && ObjectIdentifier($0) != ObjectIdentifier(currentAdaptiveSetEntryModel)
    } + [
        SetEntry.self,
        AdaptiveSetEntry.self,
        OpenLiftSchemaV9.FixedCycleReadinessObservation.self,
        OpenLiftSchemaV9.FixedCycleReadinessResponse.self,
        FixedCycleOccurrenceOverride.self,
        FixedCycleExerciseSnapshot.self
    ]
}

/// Adds an optional completion timestamp to Fixed Cycle and Adaptive set rows.
/// Existing rows intentionally migrate with no completion timestamp.
enum OpenLiftSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV9.models.filter {
        ObjectIdentifier($0) != ObjectIdentifier(OpenLiftSchemaV9.SetEntry.self)
            && ObjectIdentifier($0) != ObjectIdentifier(OpenLiftSchemaV9.AdaptiveSetEntry.self)
    } + [
        SetEntry.self,
        AdaptiveSetEntry.self
    ]
}

/// V11 makes readiness eagerness systemic.
enum OpenLiftSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV10.models.filter {
        ObjectIdentifier($0) != ObjectIdentifier(OpenLiftSchemaV3.AdaptiveReadinessResponse.self)
            && ObjectIdentifier($0) != ObjectIdentifier(OpenLiftSchemaV3.DailyReadinessCheck.self)
            && ObjectIdentifier($0)
                != ObjectIdentifier(OpenLiftSchemaV9.FixedCycleReadinessObservation.self)
            && ObjectIdentifier($0)
                != ObjectIdentifier(OpenLiftSchemaV9.FixedCycleReadinessResponse.self)
    } + [
        AdaptiveReadinessResponse.self,
        DailyReadinessCheck.self,
        FixedCycleReadinessObservation.self,
        FixedCycleReadinessResponse.self
    ]
}

/// Adds occurrence-level cable resistance metadata as a parallel model. No
/// existing exercise, session, or set entity is changed, so legacy cable work
/// remains explicitly unknown until an exact occurrence is audited/backfilled.
enum OpenLiftSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV11.models + [
        ExerciseResistanceProfile.self
    ]
}

/// Adds cycle-owned versioned cluster pointers, frozen draft contexts, and
/// immutable progression occurrences as parallel entities. No V1-V12 shape
/// changes and migration never guesses an identity for legacy history.
enum OpenLiftSchemaV13: VersionedSchema {
    static let versionIdentifier = Schema.Version(13, 0, 0)

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV12.models + [
        FixedCycleClusterPointer.self,
        FixedCycleSessionContext.self,
        FixedCycleProgressionOccurrence.self
    ]
}

enum OpenLiftSchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        OpenLiftSchemaV1.self,
        OpenLiftSchemaV2.self,
        OpenLiftSchemaV3.self,
        OpenLiftSchemaV4.self,
        OpenLiftSchemaV5.self,
        OpenLiftSchemaV6.self,
        OpenLiftSchemaV7.self,
        OpenLiftSchemaV8.self,
        OpenLiftSchemaV9.self,
        OpenLiftSchemaV10.self,
        OpenLiftSchemaV11.self,
        OpenLiftSchemaV12.self,
        OpenLiftSchemaV13.self
    ]

    static let stages: [MigrationStage] = [
        .lightweight(
            fromVersion: OpenLiftSchemaV1.self,
            toVersion: OpenLiftSchemaV2.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV2.self,
            toVersion: OpenLiftSchemaV3.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV3.self,
            toVersion: OpenLiftSchemaV4.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV4.self,
            toVersion: OpenLiftSchemaV5.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV5.self,
            toVersion: OpenLiftSchemaV6.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV6.self,
            toVersion: OpenLiftSchemaV7.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV7.self,
            toVersion: OpenLiftSchemaV8.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV8.self,
            toVersion: OpenLiftSchemaV9.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV9.self,
            toVersion: OpenLiftSchemaV10.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV10.self,
            toVersion: OpenLiftSchemaV11.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV11.self,
            toVersion: OpenLiftSchemaV12.self
        ),
        .lightweight(
            fromVersion: OpenLiftSchemaV12.self,
            toVersion: OpenLiftSchemaV13.self
        )
    ]
}

struct OpenLiftStoreStartupIssue: Equatable {
    let storeURL: URL
    let underlyingDescription: String

    var userMessage: String {
        """
        OpenLift could not open its workout database. The existing store was left in place at \(storeURL.path).

        Quit OpenLift and preserve a backup of that file before changing the app or its data. Technical detail: \(underlyingDescription)
        """
    }
}

struct OpenLiftContainerStartup {
    let container: ModelContainer
    let issue: OpenLiftStoreStartupIssue?
}

enum OpenLiftModelContainerFactory {
    static func makePersistent(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configuration: ModelConfiguration
    ) -> OpenLiftContainerStartup {
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: migrationPlan,
                configurations: [configuration]
            )
            return OpenLiftContainerStartup(container: container, issue: nil)
        } catch {
            let issue = OpenLiftStoreStartupIssue(
                storeURL: configuration.url,
                underlyingDescription: error.localizedDescription
            )

            // This isolated container exists only so SwiftUI can render the
            // blocking failure view. RootTabView and all data mutation paths
            // remain unavailable while `issue` is non-nil.
            let failureViewConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )

            do {
                let container = try ModelContainer(
                    for: schema,
                    configurations: [failureViewConfiguration]
                )
                return OpenLiftContainerStartup(container: container, issue: issue)
            } catch {
                fatalError("Failed to create isolated startup-failure container: \(error)")
            }
        }
    }

    static func makeInMemory(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory model container: \(error)")
        }
    }
}
