# Data And History

## Storage Model

OpenLift stores app data locally with SwiftData.

Core models live in [`Models.swift`](../Sources/Models.swift):

- `TrainingPreference`
- `Exercise`
- versioned Adaptive program, muscle-rule, complex, and component records
- raw daily readiness and generated/frozen plan snapshots
- Adaptive occurrence links, complex feedback, and explicit override events
- `CycleTemplate`
- `ActiveCycleInstance`
- `Session`
- `SetEntry`
- `SessionSlotOverride`

## What Counts As History

The History tab primarily shows completed `Session` records plus their locked `SetEntry` values.

History is searchable by exercise name. Search results combine Rotation, ad hoc,
and Adaptive completed work into a newest-first timeline showing the workout
date and every completed set's weight and reps. Incomplete or unlocked Adaptive
rows are excluded.

Ad hoc logging remains available in either training mode. Completed locked ad
hoc sets will be load/recovery evidence for Adaptive planning, but they are not
automatically same-complex performance evidence. Drafts and unlocked sets do
not count.

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

Completed workouts:

- `OpenLift/exports/workout-YYYYMMDD-HHMMSS.json`

Draft snapshots (one per active session, deleted automatically when the workout is finished):

- `OpenLift/exports/drafts/draft-<session-id>.json`

Write locations:

- iCloud Documents container: `Documents/OpenLift/exports`
- local app Documents: `OpenLift/exports`

The app intentionally writes to both when possible. The local Documents mirror keeps exports visible through Finder / Files app / device-container tooling even when the iCloud Documents container is slow, broken, or not materialized on a Mac.

Completed workouts only count as successfully exported after the iCloud Documents mirror is written and read back. If that mirror is unavailable, SwiftData remains the source of truth, the local Documents copy remains a rescue copy, and OpenLift retries failed/pending completed-session exports when the app opens, returns to foreground, or receives a background app-refresh slot.

## Recovery Behavior

The app can rebuild missing completed sessions from export files during bootstrap. That is why export files matter even though SwiftData is the primary store.

Rotation and ad hoc workouts remain backward-readable through the v1 JSON
shape. Ad hoc exercise entries may add the optional `volume_feedback` field;
older files decode with that field missing.

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
