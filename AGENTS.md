# Repository Guidelines

## Project Overview

OpenLift is a local-first iOS hypertrophy tracker built with SwiftUI, SwiftData,
and Apple frameworks only. It supports Fixed Cycle, the V13 independently
advancing clustered program, Adaptive Floating, ad hoc logging, resistance
profiles, and export-backed recovery. The deployment target is iOS 17+.

## Project Structure

```text
Sources/    application code and assets
Tests/      unit, migration, and regression tests
UITests/    simulator UI flows
Config/     tracked public build settings plus a gitignored local override
docs/       current architecture and operating documentation
Resources/ reference exercise notes
scripts/   repo-safe migration and interactive deployment helpers
```

Key source files:

| File | Responsibility |
|---|---|
| `OpenLiftApp.swift` | App entry, V13 container startup, explicit rollout/repair gates |
| `OpenLiftSchema.swift` | Additive V1-V13 schemas and migration plan |
| `Models.swift` | SwiftData models and supporting value types |
| `BootstrapDataService.swift` | Catalog/template seeding, hydration, repairs, clustered program/rollout |
| `WorkoutView.swift` | Fixed Cycle draft entry, clustered completion, prefill, finish/export |
| `AdaptiveWorkoutView.swift` | Adaptive readiness, design, execution, and completion |
| `AdaptivePlanningServices.swift` | Planning, repeat-last lookup, progression/profile isolation |
| `HistoryView.swift` | Completed history, occurrence-backed display, export retry |
| `CycleView.swift` | Mode/template selection, editing, activation, published import |
| `ResistanceProfileService.swift` | Per-occurrence cable/stack/VOLTRA profiles |
| `SessionExportService.swift` | Completed/draft JSON, hydration metadata, fail-closed filtering |
| `StoreBackupService.swift` | Local store backup snapshots |
| `DirectExportService.swift` | Optional best-effort private HTTPS delivery |

## Current Clustered Fixed Cycle

V13 adds exactly two parallel entities without changing legacy session/set
shapes:

- mutable `ClusterRotationState`: one authoritative next-position state for each
  whole cluster
- immutable `ClusterOccurrenceRecord`: one completed-cluster snapshot containing
  structural step, stable progression keys, performed/skipped status, and
  resistance profiles

All three current clusters appear in one draft. Their rotation lengths are
3/6/6. Completing a cluster advances only its own state; skipped rows do not
block advancement; no movement or internal lane advances independently.
`Finish Workout` requires at least one completed cluster and retains/exports
only locked positive-rep rows backed by performed occurrence snapshots.

The reserved template defaults every slot to three rows. A qualifying previous
performance for the same progression identity supplies its literal row count,
weights, and reps, so a completed manual reduction carries forward. Cluster 2
derives three-step arm identities inside its six-step leg rotation; Cluster 3
derives a two-step shoulder identity inside its six-step calves/forearms lane.
Do not add sub-rotation state.

## Build And Test

Full simulator suite:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```

Useful diagnostics:

```bash
xcodebuild -scheme OpenLift -showdestinations
xcrun simctl list
xcrun devicectl list devices
```

Tests include service tests, copied-store migration gates, clustered
progression/export/hydration regressions, and UI flows. Add a regression test for
each behavior fix. Do not claim the full suite passed unless the UI runner also
finished.

## Architecture Rules

- Keep schemas additive. Never alter a shipped model checksum to simplify a new
  feature.
- Preserve legacy V1-V12 history. Do not guess or backfill V13 progression keys.
- Treat stable progression identity as stronger than current template position.
- For clustered prefill: exact key/profile first, then same key with another
  profile, then only safe legacy/unkeyed global history. Never let another
  versioned identity enter the fallback.
- Freeze completed structural/profile evidence in occurrences; retries and
  hydration must not rederive it from a mutable live template.
- SwiftData is primary; JSON is the recovery layer. Real-store work requires a
  verified backup and scratch-copy migration testing.
- Keep explicit rollout/repair operations separate from normal schema migration
  and normal startup.

## Security And Local Configuration

Tracked config contains public app identifiers and placeholders, not signing
credentials. Copy `Config/Local.example.xcconfig` to the ignored
`Config/Local.xcconfig` for local Apple-team settings and optional direct-export
configuration.

Never commit:

- signing keys/certificates or provisioning profiles
- bearer tokens, passwords, private endpoints, or `.env` files
- SwiftData/SQLite stores or `-wal`/`-shm` sidecars
- personal backups, workout exports, or app-container captures
- archives, IPAs, dSYMs, apps, DerivedData, or local build output

The repo-local TestFlight script uses Xcode automatic signing and is suitable for
an interactive Aqua/Xcode login session. OpenClaw's headless System security
session cannot access Keychain signing identities; use the canonical workspace
headless deployment scripts, whose credentials and device configuration remain
outside this repository.

## Commits And Documentation

Use Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`,
`chore:`). Before pushing, review the diff, run `git diff --check`, and run tests
in proportion to the files changed.

Current documentation:

- `docs/architecture.md`
- `docs/data-and-history.md`
- `docs/migration-safety.md`
- `docs/templates.md`
- `docs/setup.md`
- `docs/adaptive-floating.md`
- `docs/ai-workflows.md`

`prd.md` is the historical v1 requirements baseline, not the live architecture.
