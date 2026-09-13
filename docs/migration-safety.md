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

V13 is also additive. It adds exactly two parallel Fixed Cycle entities:
mutable `ClusterRotationState` and immutable `ClusterOccurrenceRecord`.
Opening a V12 store under V13 preserves all legacy rows and creates neither
record. Schema migration never assigns a legacy workout to a new progression
identity and never activates the clustered program.

V14 is additive as well. It adds `ClusterExercisePreference` and
`ClusterExerciseOccurrenceOverride` as parallel overlay entities. Opening a V13
store preserves rotation state and occurrence history and creates no inferred
substitutions. The persistent key is exact program version + canonical template
day position + slot position; it is deliberately not a progression key.

V15 adds nullable `chainPounds` and `eccentricPounds` fields to the live
`ExerciseResistanceProfile`. V12–V14 use a frozen copy of the shipped profile
class, preserving their schema checksums. The lightweight V14→V15 migration
preserves all existing percentages/identities/timestamps, leaving new pound
fields nil. There is no profile backfill or percentage conversion. Completed
cluster snapshots and legacy session/set models remain unchanged. The real-store
scratch gate additionally compares every profile and all cluster pointers and
immutable occurrence evidence across migration.

The clustered architecture has no persisted draft-context or sub-rotation
entity. One `ClusterRotationState` owns each whole cluster. A completed cluster's
`ClusterOccurrenceRecord` freezes its structural step, stable progression keys,
performed/skipped status, and resistance profiles while leaving legacy
`Session` and `SetEntry` shapes untouched.

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

## Clustered Hypertrophy one-time rollout

`BootstrapDataService.prepareClusteredProgramRollout` is a separate explicit,
backup-gated operation. Merely installing or launching a V14 build performs only
the additive schema migration. The clustered template is created and selected
only when the app launches with
`OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT`.

Before invoking it against a real store, close OpenLift and make a verified copy
of `default.store` together with any `default.store-wal` and
`default.store-shm` sidecars. The rollout always refuses locked Fixed Cycle
work and any locked or entered Adaptive draft. Unlocked, nonzero Fixed Cycle
prefill rows may be retired only when that backup has been verified and the app
also launches with `OPENLIFT_CLUSTERED_DRAFT_BACKUP_CONFIRMED`; without that
second argument, the rollout fails without mutation. The rollout then:

1. refuses locked Fixed Cycle work, locked or entered Adaptive drafts, unconfirmed
   nonzero Fixed Cycle drafts, and any conflicting same-name template or
   partial pointer state;
2. creates or reuses the exact versioned `Clustered Hypertrophy v1` template;
3. creates one active cycle and three independent zero-based cluster pointers,
   unless a complete export-recovered pointer set already exists;
4. switches to Fixed Cycle without rewriting completed history or assigning
   progression keys to legacy sessions; and
5. writes a durable marker containing the template and cycle identities.

Template/catalog insertion, cycle selection, pointer creation, and marker
creation are one transaction. Confirmed unlocked Fixed Cycle draft/autofill
retirement occurs in that same transaction. Any validation error rolls all of
them back.
Re-running the flag after success validates the marker and three-pointer state
and returns without rewinding. Rollout is intentionally fail-closed if the
marker exists but its referenced state is incomplete.

After rollout, all three states must resolve to position zero and a normal
argument-free relaunch must preserve the marker, template, cycle, and states.
The pre-rollout backup and completed-history counts are the recovery baseline.
No fake occurrence is created by activation; the first occurrence appears only
after the user intentionally completes a cluster.

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

## August 16 Pull A completion-date repair

TestFlight builds after the reviewed August 17 late submission run a narrow,
idempotent startup repair for Fixed Cycle session
`46A246F9-1B51-47D7-BCC0-C754ECBD9C59`. The phone's direct export and iCloud
mirror established the exact template, cycle, session, 12 locked sets, and
already-advanced Push A pointer before implementation. The repair requires that
entire manifest and the original August 17 completion timestamp, then changes
only `finishedAt` to the last captured August 16 set timestamp, marks that one
session export pending, and writes a durable marker. Startup re-exports only the
target session. Any pointer, session, or set drift fails closed; unrelated
stores silently skip the absent target. The repair never moves the cycle
pointer, changes a set, or manufactures a draft.

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

## Current migration gates

The maintained suite covers unversioned-store recognition, every additive schema
stage through V15, full legacy-entity readback, rollback readback, deliberate
migration failure with unchanged file hashes, clustered rollout idempotency,
three-state hydration, immutable occurrence recovery, progression-key isolation,
and completed-cluster export filtering. The real-store migration helper works on
a scratch copy and verifies that its supplied backup remains unchanged.

Do not encode transient simulator versions or historical test totals here. The
authoritative gate is the current green result from:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```

For a verified store backup, run [`test-real-store-migration.sh`](../scripts/test-real-store-migration.sh)
against the backup archive or directory. The script stages a separate working
copy and never opens the source store in place.

### Explicit September 2026 program revision

After a verified, quiesced store backup and scratch-copy verification, launch the
updated app once with both arguments:

```text
OPENLIFT_REVISE_CLUSTERED_PROGRAM_2026_09_06
OPENLIFT_CLUSTERED_REVISION_BACKUP_CONFIRMED
```

This is a content transaction, not an automatic schema migration. It requires one
recognized v1 cycle with exactly three valid pointers and no fixed/adaptive
drafts. Any preflight/save failure rolls back. It preserves absolute pointer
values (reviewed store: 12/12/11), archives v1 state, creates v2 state, and records
an idempotence marker. Repeating the operation verifies the resulting state and
does not reapply the revision. The revision itself does not alter the schema; the current schema plan also includes V15 resistance units.

Success logs `OPENLIFT_CLUSTERED_REVISION_RESULT`. A name-only correction for the
reviewed Sept 5 safety-bar session is re-exported after commit and reports
`OPENLIFT_SAFETY_BAR_RENAME_EXPORT_RESULT`; export failure does not undo an already
committed content transaction and remains retryable.

Service-only copied-store verification (no export or network calls): stage a
**copy** under the test host's `Documents/OpenLiftCopiedRevisionStore`, or supply
`OPENLIFT_REAL_DEVICE_STORE_DIRECTORY`, then run:

```bash
xcodebuild test -scheme OpenLift \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OpenLiftTests/MigrationSafetyTests/testCopiedRealStoreSeptember2026RevisionWhenOptedIn
```

The test makes another scratch copy before SwiftData opens it, compares all set
values and frozen occurrence content (allowing only the requested target name),
checks the safety-bar UUID, next pointers and pairings, confirms idempotence, and
verifies that the supplied copy's manifest is unchanged. Never stage the sole
backup or a live store for testing.

V4 export recovery recognizes both program versions, reconstructs missing v2
template metadata, and maintains continuous occurrence evidence across the
revision. Durable preferences are authoritative independently per version; an
old v1 retry cannot delete current v2 preferences. Recovered pointers and frozen
occurrences attach to matching-version templates. Safety-bar naming aliases
resolve to one catalog identity during recovery.

## Seated shrug content revision (v3)

`BootstrapDataService.prepareSeatedShrugClusterRevision` revises an active v2
program to v3 without changing the V15 SwiftData schema or any completed
history. It adds two starting shrug rows only at Cluster 3 A/C/E, preserves all
existing slot doses and substitution identities, and copies the three active
v2 raw pointers exactly. Archived v1/v2 state is retained. The operation refuses
pending model changes, any Fixed/Adaptive draft, incomplete pointers, and
conflicting v3 state; failure rolls the transaction back.

### On-device activation

After finishing the current workout, open **Cycle → Add Seated Dumbbell Shrugs**.
The action is available only for an active v2 program and is disabled while any
Fixed/Adaptive draft exists. It never discards a draft or manufactures a skipped
workout to make the revision eligible.

The user-tapped path creates a fresh, uniquely named `VACUUM INTO` snapshot in
`Documents/OpenLift/revision-backups`, outside daily snapshot pruning, and checks
the actual `PRAGMA quick_check` result before applying. It does not reuse today's
daily backup, which may predate recent work. SQLite consolidates committed WAL
contents into this consistent single file; separate sidecars are not needed.
The main-actor operation has no suspension between snapshot and application.
Pending model changes and drafts are refused before creating a backup; backup
failure prevents application. A verified snapshot is retained if later program
validation refuses the change. Repeated successful application creates no new
backup. Ordinary launch still never applies the revision.

The copied V15-store test opens a copy of the generated snapshot to verify its
pre-revision session/set values, frozen occurrences, profiles, overrides and
archived pointers against the source. This verified consolidated snapshot is the
on-device equivalent of a consistent store-and-sidecar backup for this content
revision; it does not introduce automatic full-store restoration.

### Developer launch route

After closing OpenLift and verifying a backup of `default.store` plus present
`-wal`/`-shm` sidecars, launch with both:

- `OPENLIFT_ADD_CLUSTERED_SHRUGS_2026_09_08`
- `OPENLIFT_CLUSTERED_SHRUGS_BACKUP_CONFIRMED`

Successful application prints `OPENLIFT_CLUSTERED_SHRUGS_RESULT` and
`OPENLIFT_CLUSTERED_SHRUGS_AUDIT`. The audit must report v3, the unchanged three
raw pointers, `shrugPositions=9,11,13`, and `shrugRows=2,2,2`. The durable marker
`clustered-program-revision-2026-09-08-v3` makes a repeated application validate
and return `applied=false`, even after subsequent workouts advance the pointers.
Do not combine this with the older v1-to-v2 revision flag.

`OPENLIFT_AUDIT_CLUSTERED_SHRUGS` invokes the read-only audit separately. Ordinary
argument-free launch does not revise the program. Audit again after an ordinary
relaunch to verify persistence; the audit itself creates no drafts or exports.

Before live application, stage a verified copy in the test host's
`Documents/OpenLiftCopiedShrugRevisionStore` and run
`MigrationSafetyTests/testCopiedRealStoreSeatedShrugRevisionWhenOptedIn`.
The test opens another scratch copy, checks all historical sets, snapshots,
profiles and old pointers, verifies new placement and copied substitutions,
checks idempotence, and verifies the supplied source manifest is unchanged.

Schema-v4 JSON recovery supports program versions 1–3 and reconstructs each
missing versioned template needed by frozen history. Preferences and pointers
stay in their original version namespaces; older v2 retries cannot downgrade an
active v3 template. Shrug occurrences preserve their new shared progression key
and literal performed rows through export and hydration.

## September 8 exercise setup-note import

`ExerciseSetupNotesMigration` reuses `Exercise.notes` and the existing
`TrainingPreference` marker model; no schema change. The startup import requires
all four reviewed exercise IDs and exact canonical names, a clean context, and a
fresh integrity-checked consolidated backup. Notes and completion marker commit
atomically. Existing nonblank notes win; edits and clears after completion
survive relaunch and full-store restoration without reseeding.

For an opt-in real-store check, copy a verified `default.store` and its matching
`-wal`/`-shm` sidecars into the owned test simulator app's
`Documents/OpenLiftCopiedSetupNotesStore` (never replace its live store), then run:

```bash
python3 scripts/test.py unit ExerciseSetupNotesMigrationTests/testCopiedRealStoreSetupNotesWhenOptedIn
```

The test creates another disposable copy before opening it, verifies the fresh
backup's complete logical rows, and compares every unrelated entity/relationship
table before and after import, including sessions, sets and rotation state.
Only the four notes, completion marker and Core Data bookkeeping may change.
It also verifies the staged source hashes and no-op repeat launch. Without a
staged fixture this test skips; fixture-only checks run with
`python3 scripts/test.py unit ExerciseSetupNotesMigrationTests ExerciseNotesTests`.

## September 8 v3 squat placement swap

`applyClusterSquatSwapWithFreshBackup` requires a clean, draft-free v3 store and
verifies a fresh consolidated snapshot before atomically writing only the two
D/F leg preferences. Unsupported template contents or unrelated substitutions
on either target slot fail closed. An already-applied pair is a no-op. There is
no schema change, new version, history rewrite or normal-startup activation.

The Cycle button and explicit `OPENLIFT_SWAP_CLUSTERED_SQUATS_2026_09_08` launch
argument call the same backup-gated operation. The read-only
`OPENLIFT_AUDIT_CLUSTERED_SQUAT_SWAP` argument reports all A–F effective leg names,
progression keys and prescribed rows alongside v3 pointers and shrug placement.

Stage a verified v3 store and matching sidecars in the owned simulator app's
`Documents/OpenLiftCopiedSquatSwapStore`, then run
`ClusterSquatSwapTests/testCopiedRealStoreSquatSwapWhenOptedIn`. The test opens
another disposable copy, preserving the supplied backup. Focused tests verify
backup failure, pending edits/drafts, idempotence, untouched templates/history/
profiles/pointers/notes, and same-exercise progression across the swap.

## Third side-delt content revision (v4)

After finishing any pending workout, use **Cycle → Add Third Side-Delt Movement**.
`applySideDeltRevisionWithFreshBackup` synchronously creates a unique, integrity-
checked consolidated `VACUUM INTO` backup in `Documents/OpenLift/revision-backups`
before `prepareSideDeltClusterRevision` changes an active v3 program to v4.
Installation and ordinary startup do not apply this revision. Pending changes,
Fixed/Adaptive drafts, incomplete state, conflicting destinations or ambiguous
shoulder substitutions fail closed without removing work. Repeated activation
validates the marker/state and is a no-op, without another backup.

The explicit `OPENLIFT_ADD_CLUSTERED_SIDE_DELT_2026_09_12` launch argument uses
the same fresh-backup activation path as the button, including draft protection.
It does not accept a flag that bypasses the snapshot.

Existing templates, pointers, preferences, exercise notes, profiles, sessions,
sets, and completed occurrences remain intact. New versioned state copies the
three raw pointers; the active cycle keeps its UUID and legacy day pointer.
Non-shoulder slots retain exact-slot substitutions and fallback doses. Shoulder
preferences move with their original exercise identities; inconsistent effective
substitutions across the old identity's three occurrences block activation.
Fallback dose follows its most recently scheduled old slot, while actual
qualifying effort remains the authority for literal rows and prefill. The new
movement inherits no substitution, working load, reps or prior-performance cue.

JSON recovery supports versions 1–4, restores v4's three shoulder identities,
and does not downgrade v4 when older history is retried. No SwiftData schema
version changes. `OPENLIFT_AUDIT_CLUSTERED_SIDE_DELT` is read-only and prints the
active version, raw pointers, A–F canonical side-delt names and revision marker.

Stage a verified consolidated copy as `default.store` in the owned test app's
`Documents/OpenLiftCopiedSideDeltStore`, then run:

```bash
python3 scripts/test.py unit SideDeltRevisionTests
python3 scripts/test.py ui SideDeltRevisionUITests
```

The opt-in real-store test mutates only a second disposable copy, verifies the
fresh backup against all pre-revision logical rows, checks unchanged history and
archived state, all surviving slot/progression mappings, idempotence and cold
reopen, and verifies source hashes. UI tests exercise the actual activation
button/draft blocker, persistent relaunch, and two blank new-exercise rows with
the per-side logging note.
