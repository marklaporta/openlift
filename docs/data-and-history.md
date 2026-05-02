# Data And History

## Storage Model

OpenLift stores app data locally with SwiftData.

Core models live in [`Models.swift`](../Sources/Models.swift):

- `Exercise`
- `CycleTemplate`
- `ActiveCycleInstance`
- `Session`
- `SetEntry`
- `SessionSlotOverride`

## What Counts As History

The History tab primarily shows completed `Session` records plus their locked `SetEntry` values.

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

## Recovery Behavior

The app can rebuild missing completed sessions from export files during bootstrap. That is why export files matter even though SwiftData is the primary store.

Bootstrap and recovery logic live in:

- [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift)
- [`WorkoutView.swift`](../Sources/WorkoutView.swift)

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
