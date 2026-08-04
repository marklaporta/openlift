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

Later schemas remain additive: V4 adds exercise-selection preferences, V5 adds
export diagnostics, V6 adds workout-size/design state, and V7 adds parallel
per-version volume targets, workout capacity, and lineage volume anchors.
V8 adds parallel per-muscle exposure configuration. The V7 and V8 lightweight
migrations do not alter legacy sessions, completed Adaptive snapshots, volume
rows, or export records. Exposure-controller rows are initialized only after
the store opens successfully and no open Adaptive plan would be invalidated.
V9 adds only parallel Fixed Cycle readiness-response, occurrence-skip, and
ordered completed-occurrence snapshot entities. No shipped V1-V8 entity shape
or checksum is modified.

V10 adds optional set-lock timestamps and V11 moves eagerness to the systemic
readiness record using frozen historical model copies. V12 is additive again:
it adds only `ExerciseResistanceProfile`. Opening a V11 store under V12 must
preserve every exercise/session/set and create zero profile rows, so legacy
cable settings remain unknown. The Sherwick audit and reviewed-manifest repair
are separate from schema migration and never run as a migration stage.

The reviewed Sherwick repair runs only after the V12 store opens successfully.
Its frozen manifest contains the exact 19 occurrences from the reviewed
2026-08-04 device audit. Each launch recomputes the source audit and requires an
exact match on schema/count, occurrence keys, exercise names, performed-set
counts, and resistance values. It preflights every existing profile before
inserting any missing rows, so a conflicting row or audit drift fails closed
without a partial repair. Only sessions receiving a newly inserted profile are
marked export-pending. Once every exact row exists, the repair is a no-op and
does not repeatedly dirty completed-session exports.

## Push/Pull A/B one-time rollout

`BootstrapDataService.preparePushPullABRollout` is an explicit migration
operation, not normal bootstrap seeding. Before invoking it against a real
store, quiesce OpenLift and make a verified copy of the SQLite store together
with its `-wal` and `-shm` sidecars under the procedure below. The operation:

1. refuses any active Fixed Cycle or Adaptive draft containing locked, entered,
   or nonzero work;
2. preserves completed history and the old template;
3. retires only an empty old draft;
4. creates or reuses the Push/Pull A/B template without overwriting a
   previously edited copy;
5. selects Fixed Cycle and Push A for the initial workout; and
6. writes a durable rollout marker referencing the created template.

The marker is checked before any pointer mutation. Re-running the operation
after success cannot rewind the pointer even if the user later selects Adaptive.
The command-line launch argument is
`OPENLIFT_PREPARE_PUSH_PULL_ROLLOUT`; it must be used only after backup and
live-state inspection. If entered drafts were explicitly preserved in that
backup, `OPENLIFT_ARCHIVED_PUSH_PULL_DRAFTS_CONFIRMED` authorizes the rollout
to retire unlocked Fixed Cycle draft rows and preserve locked Adaptive work as
a completed session while dropping only its editable autofill rows. Locked
Fixed Cycle work and malformed Adaptive drafts still block. Merely launching
or upgrading the app never runs either path.

## July 27 Adaptive Incline Curl one-time repair

`BootstrapDataService.repairJuly27AdaptiveInclineCurl` is an explicit,
idempotent live-data repair for the completed `2026-07-27` Adaptive session
`08476AD8-9550-4A33-94DF-55B12E6161F2` and Incline Curl exercise
`96C071BF-05E2-467C-8357-CFE375C5C162`, archived by the Push/Pull rollout. It
runs only when both
`OPENLIFT_REPAIR_2026_07_27_ADAPTIVE_INCLINE_CURL` and
`OPENLIFT_2026_07_27_ADAPTIVE_INCLINE_CURL_BACKUP_CONFIRMED` are supplied.
The second argument may be supplied only after OpenLift is quiesced and a
verified copy of the SQLite store plus its `-wal` and `-shm` sidecars exists.

The repair additionally requires the durable Push/Pull rollout marker, Fixed
Cycle mode, and the marked cycle still pointing at Push A. It refuses ambiguous
July 27 sessions, ambiguous Incline Curl occurrences, or any entry shape other
than the known single locked `20 lb × 13` set (or the exact repaired state).
It inserts locked sets 2 and 3 at `20 lb × 9` and `20 lb × 7`, preserves every
other row and all Fixed Cycle state, writes a durable repair marker, and marks
the completed Adaptive session export pending. Startup immediately invokes the
Adaptive exporter for that repaired session only, so the canonical session
export is replaced with the corrected payload without touching unrelated
pending export metadata. Before writing the canonical filename, the retry also
replaces every valid local or iCloud Adaptive export copy whose payload carries
that exact session ID; this prevents recovery from selecting one of the older
single-set fallback files. Filenames are preserved and unrelated or malformed
files are not changed. Re-running the two arguments validates the marker and
repaired state without adding or changing sets, while still allowing a pending
export retry to finish.

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
