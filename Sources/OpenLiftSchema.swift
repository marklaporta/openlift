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

    static let models: [any PersistentModel.Type] = OpenLiftSchemaV2.models + [
        AdaptiveMuscleRule.self,
        AdaptiveComplexComponent.self,
        AdaptiveExerciseComplex.self,
        AdaptiveProgram.self,
        AdaptiveReadinessResponse.self,
        DailyReadinessCheck.self,
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

enum OpenLiftSchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        OpenLiftSchemaV1.self,
        OpenLiftSchemaV2.self,
        OpenLiftSchemaV3.self,
        OpenLiftSchemaV4.self,
        OpenLiftSchemaV5.self
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
