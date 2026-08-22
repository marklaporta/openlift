# Data And History

## Storage Model

OpenLift stores app data locally with SwiftData.

Core models live in [`Models.swift`](../Sources/Models.swift):

- `TrainingPreference`
- `Exercise`
- versioned Adaptive program, muscle-rule, complex, and component records
- versioned per-muscle exposure/cadence configuration and workout-capacity
  preferences; legacy volume-target and anchor rows remain inert for migration
  compatibility
- raw daily readiness and generated/frozen plan snapshots
- Adaptive occurrence links, complex feedback, and explicit override events
- `CycleTemplate`
- `ActiveCycleInstance`
- `Session`
- `SetEntry`
- `SessionSlotOverride`
- append-only Fixed Cycle readiness revisions and occurrence-level skip records
- V13 clustered Fixed Cycle pointers, frozen draft contexts, and immutable
  completed-cluster occurrences

## What Counts As History

The History tab primarily shows completed `Session` records plus their locked `SetEntry` values.

History is searchable by exercise name. Search results combine Rotation, ad hoc,
and Adaptive completed work into a newest-first timeline showing the workout
date and every completed set's weight and reps. Incomplete or unlocked Adaptive
rows are excluded.

Ad hoc logging remains available in either training mode. Completed locked ad
hoc sets will be load/recovery evidence for Adaptive planning. Direct sets count
toward the exercise primary muscle's set-rate target; secondary muscles receive
recovery context but no target credit. Ad hoc work is not automatically
same-complex performance evidence. Drafts and unlocked sets do not count.

Exercise effort history is shared across modes by canonical exercise identity.
Fixed Cycle first searches completed nonzero occurrences of the same stable
cycle-instance day, skipping zero-set omissions, and then falls back to the newest qualifying
Fixed Cycle, Adaptive, or ad hoc effort. Adaptive and ad hoc have no stable
cycle-day identity and use the global newest effort directly. Prefill copies
the literal completed set count, weights, and reps without conversion.

Cable effort adds one more identity gate: resistance source and the complete
raw profile must match. Different or unknown profiles are shown as reference
history but are not silently prefilled or scored against each other.

The versioned clustered program uses an explicit progression key per exercise
slot. Legs use A-F, arms use A-C, shoulders use A-B, and the alternating
calves/forearms slot uses A-F even though each cluster has only one runtime
pointer. A same-key prior occurrence is preferred; a fresh key may use legacy
global history as initial reference without retroactively relabeling it. Drafts
copy the literal qualifying row count, so manually reducing a non-leg lane from
three rows to two carries forward after that lane is completed.

Legacy Rotation `Session` and `SetEntry` shapes remain unchanged for copied-store
migration safety. Adaptive planning/execution provenance lives in parallel
records keyed by stable plan, session, set-entry, and planned-occurrence IDs.
This avoids fake cycle IDs and allows the same exercise ID to appear in more than
one planned complex without merging its occurrences.

Relevant logic:

- history UI: [`HistoryView.swift`](../Sources/HistoryView.swift)
- workout completion and export: [`WorkoutView.swift`](../Sources/WorkoutView.swift)
- export payload writing: [`SessionExportService.swift`](../Sources/SessionExportService.swift)

## Export Paths

Completed Fixed/ad-hoc exported exercises may carry optional
`resistance_profile`; Adaptive carries it on each exported occurrence. Legacy
Fixed Cycle metadata is schema v3, clustered Fixed Cycle metadata is schema v4,
and Adaptive workout export is schema v4 in its separate payload family. Older
payloads still decode, with an absent field remaining unknown. Hydration creates
a profile only from a complete valid payload.

The audit-first Sherwick migration stage wrote
`OpenLift/audits/voltra-resistance-profile-audit.json` for the ten allowlisted
session identities. It never selects by date (the Aug. 3 session was created
July 29), expects exactly 19 cable occurrences, and records exact occurrence
keys plus performed-set counts. The device report generated
`2026-08-04T11:53:19Z` was reviewed and frozen verbatim in
`HistoricalResistanceProfileMigration.reviewedManifest`: 17 occurrences use
VOLTRA inverse chains 25% / eccentric 25%, and the two Aug. 3 occurrences use
inverse chains 70% / eccentric 30%.

On startup, OpenLift recomputes the audit from SwiftData and applies the repair
only if schema version, expected count, all 19 occurrence identities, exercise
names, performed-set counts, and intended profiles exactly match the frozen
manifest. A missing/extra candidate, duplicate key, or conflicting existing
profile aborts before any insertion. Newly repaired completed sessions are
marked export-pending and immediately enter the normal export retry path. If
all 19 exact profiles already exist, startup reports `already_applied`, performs
no writes, and does not dirty or re-export those sessions again.

Completed workouts:

- `OpenLift/exports/workout-YYYYMMDD-HHMMSS.json`

Draft snapshots (one per active session, deleted automatically when the workout is finished):

- `OpenLift/exports/drafts/draft-<session-id>.json`

Write locations:

- iCloud Documents container: `Documents/OpenLift/exports`
- local app Documents: `OpenLift/exports`

The app intentionally writes to both when possible. The local Documents mirror keeps exports visible through Finder / Files app / device-container tooling even when the iCloud Documents container is slow, broken, or not materialized on a Mac.

Completed workouts only count as successfully exported after the iCloud Documents mirror is written and read back. If that mirror is unavailable, SwiftData remains the source of truth, the local Documents copy remains a rescue copy, and OpenLift retries failed/pending completed-session exports when the app opens, returns to foreground, or receives a background app-refresh slot.

## Optional Direct Export

OpenLift can also deliver the exact completed-workout JSON directly to a private
HTTPS receiver. This is an additive, best-effort transport: it does not replace
SwiftData, the local Documents copy, or the iCloud mirror, and a queue or network
failure never blocks workout completion or History.

Direct export is disabled by default. Enable it only in the gitignored
`Config/Local.xcconfig`:

```xcconfig
// $()/ preserves the second slash because xcconfig treats // as a comment.
OPENLIFT_DIRECT_EXPORT_ENDPOINT = https:/$()/private-host/openlift-export
// Optional when the tailnet/receiver already authenticates the device.
OPENLIFT_DIRECT_EXPORT_BEARER_TOKEN =
```

`OPENLIFT_DIRECT_EXPORT_ENDPOINT` must resolve to an HTTPS URL; omitting it
keeps the feature off. The bearer token is optional. When present, OpenLift
sends it as `Authorization: Bearer …`; when absent, no Authorization header is
added. Keep both real values out of tracked configuration.

After Fixed, ad hoc, or Adaptive completed-session JSON serializes, OpenLift
idempotently queues it by `session_id` under Application Support. The token is
never stored with the queued payload and neither token nor payload is logged.
Delivery uses `POST`, `Content-Type: application/json`, and the session UUID as
`Idempotency-Key`. Only a 2xx response removes an entry. Transport errors and
all other HTTP responses retain it with attempt metadata and exponential retry
backoff bounded between one minute and six hours. Delivery is attempted right
away, at app launch/foreground, and during the existing background export-retry
opportunities. iOS background scheduling is opportunistic, so launch/foreground
remains the guaranteed retry trigger.

The first enabled launch/foreground also performs a one-time local-history
backfill after the normal SwiftData export retry. It scans only the immediate
`Documents/OpenLift/exports` directory inside the app container for
`workout-*.json`; it never reads iCloud and does not descend into `drafts/` or
`readiness/`. The scan is capped at the newest 250 files and 5 MiB per file. Each file must
contain a valid UUID `session_id`; the exact original bytes are queued under
that identity. Re-enqueuing an identical payload preserves any existing retry
backoff. The completion marker is written only after the bounded scan finishes,
so a queue-write failure retries the scan on a later foreground without
affecting launch, workout completion, or History. Pending SwiftData sessions are
serialized first through the current exporter; this local mirror backfill then
covers older sessions already marked successfully exported.

## Recovery Behavior

The app can rebuild missing completed sessions from export files during bootstrap. That is why export files matter even though SwiftData is the primary store.

Rotation and ad hoc workouts remain backward-readable through the v1 JSON
shape. Ad hoc exercise entries may add the optional `volume_feedback` field;
older files decode with that field missing.

New Fixed Cycle exports add optional `fixed_cycle` metadata without changing the
legacy fields. It records template/cycle-instance/day identity, ordered planned exercises,
dated readiness revisions, occurrence-level skips and reasons, canonical
exercise IDs, and actual completed set rows. Older payloads still decode, and
hydration deduplicates the new parallel records by their stable UUIDs.
Draft recovery snapshots use the same optional metadata, so a readiness-only day
is mirrored without being promoted to a completed workout or load exposure.

Clustered schema-v4 metadata adds immutable completed-cluster occurrences and
the three explicit rotation pointers. Only clusters intentionally completed in
the session are exported. Unfinished clusters and unperformed exercises are
omitted from completed-workout exercise lists; an all-skipped completed cluster
still exports its empty occurrence as advancement evidence. Export retries use
the frozen occurrence rather than the mutable live template. Hydration restores
explicit exported pointers when present and otherwise derives a pointer only
from gap-free, non-conflicting occurrence steps.

Adaptive workouts use additive schema v2 JSON. The payload records
`workout_kind: adaptive`, the session UUID, raw readiness/version, planner
version, ordered frozen complex and component snapshots, planned occurrence
IDs, actual locked sets, overrides, and feedback. Hydration deduplicates
Adaptive work by session UUID and reconstructs parallel Adaptive records; it
never creates or advances a Rotation cycle.

History badges Rotation, Ad hoc, and Adaptive explicitly. Adaptive detail
renders frozen complex/component order and duplicate exercise occurrences
separately, including raw previous/current set rows and conservative comparison
labels.

Bootstrap and recovery logic live in:

- [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift)
- [`WorkoutView.swift`](../Sources/WorkoutView.swift)

## Importing Workout JSON

There is no dedicated Import tab. To supply an off-schedule workout or recovery
file, place its JSON in `iCloud Drive/OpenLift/exports`. OpenLift's normal
bootstrap/recovery path deduplicates it by `session_id` and adds a missing
completed history session without advancing the active cycle.

Minimal off-schedule shape:

```json
{
  "date": "2026-05-03T21:22:07Z",
  "exercises": [
    {
      "exercise_name": "Incline Dumbbell Press",
      "sets": [
        { "weight": 75, "reps": 10 },
        { "weight": 75, "reps": 9 }
      ]
    }
  ]
}
```

Optional fields are `session_id`, `cycle_name`, `cycle_day_index`, `muscle`, and
`set_index`. When `session_id` is absent, OpenLift derives a stable identifier
from the filename. Exercise names must match the local exercise catalog.

## Safe Ways To Change History

Safest:

1. use the app UI for future workouts
2. use template changes for future programming
3. use export files only as recovery inputs, not as your primary editing surface

Medium risk:

- modify or add a published cycle JSON for future use

High risk:

- directly editing SwiftData-backed user history
- directly editing export JSON that the app may later hydrate from
- bulk-deleting sessions or drafts without understanding cycle reconciliation

## If You Must Touch Real User Data

Follow this order:

1. back up the app container or export files first
2. close the app
3. inspect the current state before editing anything
4. change the smallest possible set of records
5. relaunch and verify in the UI

## How To Inspect User Data

Prefer these approaches:

- use the History tab for read-only validation
- inspect exported JSON in `OpenLift/exports`
- use Xcode or device tooling to inspect the app container if you need the raw store

For simulator and device debugging, CLI tools can help:

- `xcrun simctl`
- `xcrun devicectl`

## Rules For Agents

If an AI agent is asked to change real user data:

- back up first
- avoid broad deletes
- prefer fixing the specific session, set, or draft involved
- explain whether the change affects draft state, completed history, exports, or all three

This repo has already hit bugs where draft state, cycle state, and history diverged. Treat stored user data as a high-risk area.
