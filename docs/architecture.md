# Architecture

## Top-Level Shape

OpenLift is a SwiftUI app with:

- SwiftData for local persistence
- iCloud Documents style files for published cycle import and workout export recovery
- a small centralized state resolver for choosing the active template, active cycle, and draft

Entry points:

- app entry: [`OpenLiftApp.swift`](../Sources/OpenLiftApp.swift)
- root navigation: [`RootTabView.swift`](../Sources/RootTabView.swift)

Main tabs:

- Workout
- History
- Cycle
- Import

## Core Data Model

The main SwiftData models are defined in [`Models.swift`](../Sources/Models.swift):

- `Exercise`
- `CycleTemplate`
- `CycleDay`
- `CycleSlot`
- `ActiveCycleInstance`
- `Session`
- `SetEntry`
- `SessionSlotOverride`

Design intent:

- `CycleTemplate` describes programming structure
- `ActiveCycleInstance` tracks where the user currently is in a cycle
- `Session` is the workout occurrence
- `SetEntry` stores logged sets for a session

## State Selection

The app used to spread active-cycle logic across views. That is now centralized in [`OpenLiftStateResolver.swift`](../Sources/OpenLiftStateResolver.swift).

It is responsible for:

- choosing the preferred template
- choosing the active cycle
- choosing the preferred draft session
- resolving cycle/day labels for history
- finding the most recent matching completed session by template name and day index

This is the main file to inspect if Workout, History, and Cycle disagree about what is active.

## Bootstrap Flow

Most startup behavior lives in [`WorkoutView.swift`](../Sources/WorkoutView.swift), not in a separate service layer.

The bootstrap path does this:

1. seed the exercise catalog
2. load stored sessions and latest export summaries
3. import a matching published template if recent history implies one
4. if no templates exist, import a preferred published template from iCloud
5. if there is still no template, create the built-in `4D Upper/Lower` starter template
6. resolve the active template and cycle
7. create or reconcile the active cycle
8. hydrate missing completed sessions from export files
9. ensure a draft session exists for the current day

Important files:

- bootstrap helpers: [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift)
- runtime bootstrap caller: [`WorkoutView.swift`](../Sources/WorkoutView.swift)

## Workout Flow

The Workout tab owns:

- bootstrap on load
- draft-session creation
- set entry editing
- history-prefill behavior
- workout completion
- draft export snapshots
- malformed-entry repair logic

Relevant code:

- [`WorkoutView.swift`](../Sources/WorkoutView.swift)

Key behavior:

- a draft session is created for the active cycle and current day
- draft entries are prefilled from the most recent matching completed day
- finishing a workout converts the draft to a completed session, exports it, advances the cycle, and creates the next draft

## Cycle Flow

The Cycle tab manages:

- listing templates
- editing and cloning templates
- importing published cycle JSON
- activating a template
- showing lightweight debug state

Relevant code:

- [`CycleView.swift`](../Sources/CycleView.swift)
- published cycle parsing: [`PublishedCycleService.swift`](../Sources/PublishedCycleService.swift)

Activation behavior:

- changing to a different active template requires confirmation
- activating a new template clears only draft sessions for the stale cycle being replaced
- the selected template id/name is persisted in `UserDefaults`

## History Flow

The History tab displays completed sessions and can fall back to exported summaries.

Relevant code:

- [`HistoryView.swift`](../Sources/HistoryView.swift)

Behavior:

- completed sessions are deduped
- cycle/day labels use snapshots first, then resolver-based fallback
- failed exports can be retried from session detail

## Export And Recovery

Workout exports are written by [`SessionExportService.swift`](../Sources/SessionExportService.swift).

Written files:

- completed workouts: `OpenLift/exports`
- draft snapshots: `OpenLift/exports/drafts`

Read back during bootstrap:

- latest export summary
- all export summaries for missing-session hydration

Important consequence:

- SwiftData is the primary store
- export JSON is the recovery layer

If history looks wrong after corruption or data loss, inspect both the SwiftData store and the export files.

## Template Sources

Templates can come from:

1. stored SwiftData templates
2. published JSON files in `OpenLift/cycles`
3. built-in fallback starter template from [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift)

Published JSON format is documented in [`docs/templates.md`](templates.md).

## Config And Secrets Boundary

Public-safe defaults live in tracked config:

- [`Config/Shared.xcconfig`](../Config/Shared.xcconfig)
- [`Config/OpenLift.xcconfig`](../Config/OpenLift.xcconfig)
- [`Config/OpenLiftTests.xcconfig`](../Config/OpenLiftTests.xcconfig)

Local-only Apple settings live in:

- `Config/Local.xcconfig`

That file is intentionally ignored by git.

## Where Bugs Usually Cluster

If you are debugging a regression, start in these areas:

- active template / cycle mismatch:
  [`OpenLiftStateResolver.swift`](../Sources/OpenLiftStateResolver.swift)
- wrong draft or stale workout screen:
  [`WorkoutView.swift`](../Sources/WorkoutView.swift)
- history mismatch or export recovery issue:
  [`HistoryView.swift`](../Sources/HistoryView.swift)
  [`SessionExportService.swift`](../Sources/SessionExportService.swift)
  [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift)
- published cycle import problem:
  [`PublishedCycleService.swift`](../Sources/PublishedCycleService.swift)
  [`CycleView.swift`](../Sources/CycleView.swift)

## Testing Strategy

Regression coverage is concentrated in:

- [`BootstrapDataServiceTests.swift`](../Tests/BootstrapDataServiceTests.swift)
- [`CycleOrderingTests.swift`](../Tests/CycleOrderingTests.swift)
- [`PublishedCycleServiceTests.swift`](../Tests/PublishedCycleServiceTests.swift)

Run:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```
