# SwiftData migration safety

OpenLift's pre-Adaptive model is declared as `OpenLiftSchemaV1` with schema
version `1.0.0`. The additive `OpenLiftSchemaV2` adds only
`TrainingPreference`. `OpenLiftSchemaV3` adds Adaptive-owned records for the
versioned profile/complex library, readiness, frozen plan snapshots, occurrence
links, feedback, and override events. Neither version alters a legacy entity.
Missing preference rows resolve to Fixed Cycle. `OpenLiftSchemaMigrationPlan` is the only migration
plan used to open the production store. The v1 declaration uses the existing
model types and therefore preserves the entity identities and checksum of stores
created by the former unversioned `Schema([...])` call.

## Startup failure contract

The app attempts to open the persistent store once. If SwiftData rejects the
store or migration, OpenLift does not move, rename, delete, recreate, or retry
against the persistent URL. It renders a blocking error view from an isolated
in-memory container and reports the preserved store path and backup guidance.
Normal tabs and background export retries are unavailable in that state.

## Synthetic v1 fixture

`MigrationSafetyTests` creates a repo-independent temporary v1 store containing
every current entity: exercises, a template/day/slot, rotation pool/index, an
active cycle, draft and completed sessions, locked and unlocked sets, export
statuses, and a session slot override. It copies that store before opening the
copy through the versioned schema and checks every row and key state.

The test also reopens the untouched source with the legacy unversioned schema to
prove rollback compatibility. A separate unsupported-version test deliberately
causes migration-plan rejection, compares SHA-256 manifests for the available
SQLite store files before and after (excluding transient shared-memory locks),
checks the actionable startup issue, and then reopens the preserved fixture with
the legacy schema.

No app container, personal export, or training data is used by these tests.

## Schema boundary after G0

V2 and V3 intentionally do not optionalize Rotation's required cycle metadata.
Adaptive persistence uses explicit parallel records, including
`GeneratedWorkoutPlan` and `AdaptiveSetOccurrenceLink`. Adaptive must never be
represented by fake cycle IDs or sentinel day indices.

## Current synthetic-gate evidence

- Baseline commit `14878dca` passed on an iPhone 17 simulator running iOS 26.4.1:
  40 tests passed and the opt-in real-device iCloud test was skipped.
- The Milestone 0 branch passed on the same simulator: 47 tests passed and the
  same opt-in iCloud test was skipped.
- The final suite includes unversioned-store recognition, full entity readback,
  rollback readback, deliberate migration failure with unchanged file hashes,
  a Rotation finish/next-draft smoke, and ad hoc exercise creation.
- After schema V2 and the explicit mode boundary, the full suite passed 51 tests;
  the separately opt-in real-device iCloud export smoke was the only skipped test.

This closes G0 for synthetic development. A read-only copy of the device app
container, local Documents mirror, and iCloud Drive mirror was subsequently
backed up on the development Mac and archive/store integrity was verified. No
candidate app was installed and the live container was not mutated.

Before accepting schema V3, an opt-in simulator test copied the backed-up device
store trio into simulator Documents, made separate legacy-readback and migration
working copies, and compared counts for every V1 entity after migration. The V3
copy matched all legacy counts, every new Adaptive entity was empty, missing
mode resolved to Fixed Cycle, and the
simulator-local supplied copy's file manifest was unchanged. The archived source
and live device store were never opened by the migration test.
