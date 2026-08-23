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

- Log
- Workout
- History
- Cycle

## Core Data Model

The main SwiftData models are defined in [`Models.swift`](../Sources/Models.swift):

- `Exercise`
- `TrainingPreference`
- `AdaptiveProgram`, `AdaptiveMuscleRule`
- `AdaptiveExerciseComplex`, `AdaptiveComplexComponent`
- `AdaptiveMuscleVolumeTarget`, `AdaptiveWorkoutCapacityPreference`,
  `AdaptiveMuscleVolumeAnchor`
- `DailyReadinessCheck`, `AdaptiveReadinessResponse`
- `GeneratedWorkoutPlan`, `PlannedComplexSnapshot`, `PlannedExerciseSnapshot`
- `AdaptiveSetOccurrenceLink`, `ComplexFeedback`, `AdaptiveOverrideEvent`
- `CycleTemplate`
- `CycleDay`
- `CycleSlot`
- `ActiveCycleInstance`
- `Session`
- `SetEntry`
- `SessionSlotOverride`
- `FixedCycleReadinessObservation`, `FixedCycleReadinessResponse`
- `FixedCycleOccurrenceOverride`
- `ExerciseResistanceProfile`
- `ClusterRotationState` and `ClusterOccurrenceRecord`

Design intent:

- `TrainingPreference` selects exactly one active programming mode and defaults
  missing legacy state to Fixed Cycle
- Adaptive profile/complex edits create immutable versions; proposed and frozen
  execution records snapshot source IDs, names, muscles, order, sets, and costs
- occurrence links keep duplicate uses of one exercise distinct without adding
  migration-sensitive fields to legacy `SetEntry`
- `CycleTemplate` describes programming structure
- `ActiveCycleInstance` tracks the active legacy cycle. Its whole-day pointer
  remains for backward compatibility but does not select a clustered workout.
- `Session` is the workout occurrence
- `SetEntry` stores logged sets for a session
- `ClusterRotationState` is the one mutable next-position record for each
  independently advancing cluster
- `ClusterOccurrenceRecord` is immutable completion evidence for one whole
  cluster and references the unchanged legacy `Session` by UUID

### Cable Resistance Profiles (V12)

`Exercise.equipment` continues to describe movement mechanics, so a
conventional stack and VOLTRA remain one `cable` exercise. The parallel
`ExerciseResistanceProfile` identifies one performed occurrence: Fixed/ad-hoc
use session + exercise, while Adaptive also uses its durable occurrence ID.
Profile controls and comparison gates are cable-only; dumbbell, barbell,
machine, and bodyweight movements never offer a VOLTRA profile. The canonical
Lat Pulldown is cable equipment, and catalog bootstrap narrowly upgrades the
legacy machine-classified Lat Pulldown row without rewriting other equipment.

Canonical settings are `weightStack`, or `voltra` with exactly one of `none`,
`chains`, `inverseChains` plus raw chain/eccentric percentages. Effective load
is derived and never stored. A missing row means unknown, including all
unmigrated legacy cable work.

The profile freezes when its first set is locked. Correction then requires an
explicit occurrence-wide confirmation. New cable work first copies the last
complete profile for that exercise, falling back to the newest complete cable
profile for Mark's usually-stable setup. The two new clustered cable-wrist
movements instead start at the approved VOLTRA default of 70% inverse chains
and 30% eccentric. A complete selection is still required before the first set
locks. Repeat-last and progression scoring require an exact complete match.
Unlike/unknown history remains visible as reference.

### Clustered Fixed Cycle (V13)

The versioned clustered program keeps the V1-V12 graph unchanged and stores its
new state in exactly two parallel entities. Each cluster has one authoritative
mutable `ClusterRotationState`. Completing a whole cluster creates one
immutable `ClusterOccurrenceRecord` that freezes the selected step, progression
keys, performed/skipped status, and resistance profiles, then advances only
that cluster's state. The reserved program template is immutable, skipped sets
do not prevent advancement, and no subsection inside a cluster advances
independently.

Progression keys are versioned structural identities, not template-day lookup
heuristics. Shorter internal rotations are derived from the cluster step, while
future structural edits require a new program version. Normal startup and V13
migration do not activate this program; the explicit rollout is documented in
[`migration-safety.md`](migration-safety.md).

The current program has a 3/6/6 structure: torso rotates A-C; legs rotate A-F
while arms repeat A-C inside the same six-step cluster; shoulders repeat A-B
while the calves/forearms lane rotates A-F. The app derives those shorter
identities with modulo arithmetic but persists only one state per cluster.

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
9. ensure the correct draft exists. Legacy Fixed Cycle suppresses a second
   same-day draft after completion; the clustered program creates one draft
   containing all three current cluster selections.

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

Key Fixed Cycle behavior:

- a draft session is created for the active cycle and current day only when no
  Fixed Cycle workout has already been completed on that local calendar day
- after completion, the pointer advances immediately but the Workout tab shows
  a concise completed-work recap and a non-editable preview of tomorrow's
  scheduled day; any older-build draft already stored for that next day remains
  untouched but hidden
- on the next local calendar day, the stored next draft becomes editable, or a
  new draft is created from the advanced pointer if none exists
- the user may inspect the workout before readiness, but all working-set mutation
  and completion remain gated until a readiness record for the current local
  date has been saved
- readiness revisions are append-only observations associated with the draft;
  they can warn but never reschedule, reorder, or change set count
- draft entries use the most recent qualifying nonzero effort for the canonical
  exercise on that same stable cycle-instance day, then the globally newest completed effort
  across Fixed Cycle, Adaptive, and ad hoc work
- zero-set skips and abandoned drafts do not become dose evidence or mutate the
  template; explicit replacement/add/remove actions are day-scoped template edits
- when a persistent removal follows completed draft work, a V9 occurrence
  snapshot retains the pre-edit membership so those sets remain visible and
  exportable while the future template immediately omits the removed item
- finishing requires at least one locked working set with reps, converts the
  draft to a completed session, exports it, and advances exactly once without
  creating another same-day draft

For the versioned clustered program, all three current clusters are shown in one
draft. `Complete Cluster` is the intentional whole-cluster action and may be
used even when prescribed rows were skipped. It immediately freezes the
occurrence, including progression keys, performed/skipped status, and the
selected resistance profile, then advances only that cluster. `Finish Workout`
requires at least one completed cluster. Completion, History, and export retain
only locked positive-rep rows backed by a performed snapshot in an immutable
occurrence; untouched clusters and skipped exercises are omitted. Export applies
the same fail-closed filter independently. The legacy whole-day pointer is not
used, and a draft containing a completed cluster cannot be discarded or silently
replaced. Partial-cluster advancement does not exist.

Each reserved template slot defaults to three draft rows. If a comparable prior
performance exists, draft creation copies its literal row count, weights, and
reps instead. This is why manually completing two rows for a non-leg progression
lane causes the next occurrence of that same lane to open with two rows; the
template itself remains immutable.

`WorkoutView` remains the single user-facing Workout page. Its content mutates
with the selected mode. While Adaptive is selected, Fixed Cycle's instance,
pointer, rotation indices, and draft remain persisted but cannot resolve into
the active Workout UI.

Adaptive Workout is one tab with three service-backed phases: Readiness, Design,
and Execute. Readiness is committed locally before its distinct asynchronous
iCloud mirror begins. Design stores a per-plan muscle-group exposure target in
parallel migration-safe metadata; the profile default remains independent.
The exposure controller derives each muscle's next eligible date from immutable
completed direct-set evidence and its editable cadence. Missing work creates no
debt or carry-forward. Secondary-muscle attribution does not reset clocks.
Scheduling eligibility remains Adaptive-owned, while the dose starting point is
the literal latest qualifying effort for that canonical exercise. Feedback,
readiness, recovery timing, difficulty, and overdue status do not raise or lower
the copied set count.
Automatic planning applies the profile's muscle-group, exercise, per-muscle
exercise, total-set, and per-exercise caps.
Difficulty is recovery context rather than a global point budget. The canonical
planner strongly deprioritizes a hard quad plus hard hamstring pairing but does
not make it infeasible. It hard-bans Chest + Triceps and Back + Biceps in the
same automatic plan, while manual editing remains available.
None and Light soreness are treated as normally trainable, with Light losing an
otherwise equal scheduling tie to None; Moderate and Heavy are excluded from
automatic planning while manual plan edits remain available.

## Cycle Flow

The Cycle tab manages:

- selecting Fixed Cycle or Adaptive Floating as the one active training mode
- listing templates
- editing and cloning templates
- importing published cycle JSON
- activating a template
- showing lightweight debug state

Relevant code:

- [`CycleView.swift`](../Sources/CycleView.swift)
- Adaptive profile validation/versioning:
  [`AdaptiveProgramService.swift`](../Sources/AdaptiveProgramService.swift)
- Adaptive profile and complex editor:
  [`AdaptiveProgramEditorView.swift`](../Sources/AdaptiveProgramEditorView.swift)
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
- exercise-name search combines Rotation, ad hoc, Adaptive, and export-recovery
  history into a newest-first set timeline
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
- failed/pending completed-session exports are retried on launch, foreground activation, and iOS background app refresh

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

The tracked files contain public identifiers and placeholders, never private
keys. Local-only Apple settings and optional direct-export credentials live in:

- `Config/Local.xcconfig`

That file is intentionally ignored by git.

Private signing keys and provisioning profiles, SwiftData stores and sidecars,
container captures, personal backups/exports, archives, IPAs, dSYMs, and local
build output are also ignored. Keep them outside the repository whenever
practical.

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
- [`AdaptiveProgramServiceTests.swift`](../Tests/AdaptiveProgramServiceTests.swift)
- [`ClusteredProgramTests.swift`](../Tests/ClusteredProgramTests.swift)
- [`MigrationSafetyTests.swift`](../Tests/MigrationSafetyTests.swift)

UI coverage lives under [`UITests`](../UITests), including the Fixed Cycle
cluster-completion flow.

Run:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```
