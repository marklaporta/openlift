# Repository Guidelines

## Project Overview
OpenLift is a fully implemented iOS app for hypertrophy rotation tracking. Built with SwiftUI and SwiftData, targeting iOS 17.0+. No external dependencies — pure Apple frameworks only.

## Project Structure
```
Sources/          application source (SwiftUI views + services)
Tests/            unit tests mirroring service logic
Config/           build configuration
  Shared.xcconfig   safe public defaults (committed)
  Local.xcconfig    personal Apple team/bundle ID (gitignored)
docs/             architecture and workflow documentation
Resources/        reference exercise notes
```

### Sources files
| File | Responsibility |
|---|---|
| `OpenLiftApp.swift` | App entry; SwiftData container init with resilient in-memory fallback |
| `Models.swift` | All SwiftData models and supporting enums |
| `RootTabView.swift` | Four-tab navigation root (Workout / History / Cycle / Import) |
| `WorkoutView.swift` | Draft session, set entry, prefill, workout completion, draft export |
| `HistoryView.swift` | Completed session display, deduplication, export recovery |
| `CycleView.swift` | Template listing, editing, cloning, activation, published import |
| `ImportView.swift` | Instructional UI for adding published cycles via iCloud |
| `OpenLiftStateResolver.swift` | Centralised active-template / cycle / draft selection logic |
| `OpenLiftValidator.swift` | Model validation for all SwiftData types |
| `CycleOrdering.swift` | Day/slot ordering by position, with legacy label-based fallback |
| `BootstrapDataService.swift` | Exercise catalog seeding, starter template, history hydration from exports |
| `PublishedCycleService.swift` | iCloud cycle JSON discovery, parsing, fuzzy exercise name resolution |
| `SessionExportService.swift` | Writes completed workouts and draft snapshots to iCloud / local Documents |

## Data Models
All models use SwiftData `@Model` with `@Attribute(.unique) var id: UUID`.

| Model | Key fields |
|---|---|
| `Exercise` | `name`, `primaryMuscle`, `type`, `equipment`, `isActive` |
| `CycleTemplate` | `name`, `days: [CycleDay]`, `rotationPools: [RotationPool]` |
| `CycleDay` | `position`, `label`, `slots: [CycleSlot]` |
| `CycleSlot` | `position`, `muscle`, `exerciseId`, `defaultSetCount` |
| `RotationPool` | `key`, `entries` — quad compound rotation |
| `RotationIndex` | `key`, `value` — tracks rotation position per cycle instance |
| `ActiveCycleInstance` | `templateId`, `currentDayIndex`, `rotationIndices` |
| `Session` | `cycleInstanceId`, `cycleDayIndex`, `cycleNameSnapshot`, `dayLabelSnapshot`, `status`, `exportStatus` |
| `SetEntry` | `sessionId`, `exerciseId`, `setIndex`, `weight`, `reps`, `isLocked` |
| `SessionSlotOverride` | `sessionId`, `slotPosition`, `exerciseId` |

## Build & Test Commands

**Run tests (simulator):**
```
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```

**Build for connected device:**
```
xcodebuild -scheme OpenLift -destination 'id=<DEVICE_UDID>' -configuration Debug build
```

**Install on connected device (after build):**
```
xcrun devicectl device install app --device <DEVICE_UDID> <path-to-.app>
```

**Find device UDID:**
```
xcrun devicectl list devices
```

**List available destinations:**
```
xcodebuild -scheme OpenLift -showdestinations
```

No Makefile. No npm. All build config lives in `Config/Shared.xcconfig`; personal Apple team ID and bundle ID override go in `Config/Local.xcconfig` (gitignored).

## Architecture Patterns
- **Static enum services** — `BootstrapDataService`, `SessionExportService`, `PublishedCycleService`, `OpenLiftValidator`, `CycleOrdering`, `OpenLiftStateResolver` are all caseless enums with only static functions. No stored state.
- **SwiftUI `@Query`** — views fetch all models reactively; derived state flows through `OpenLiftStateResolver`.
- **SwiftData `@Environment(\.modelContext)`** — views inject the model context for writes and deletes.
- **UserDefaults** — stores `openlift.lastActivatedTemplateId` and `openlift.lastActivatedTemplateName`.
- **iCloud + local fallback** — exports write to `OpenLift/exports/` in iCloud Drive; fall back to local Documents if iCloud is unavailable.
- **Snapshot resilience** — `Session` stores `cycleNameSnapshot` and `dayLabelSnapshot` so history survives template deletion or renaming.

## Testing Guidelines
Tests live in `Tests/` and cover service logic only — no UI tests.

Current test suites:
- `BootstrapDataServiceTests` — template preference, day inference, history hydration, draft selection
- `CycleOrderingTests` — position-based and semantic (Upper/Lower) day ordering
- `PublishedCycleServiceTests` — JSON parsing, exercise name aliases
- `OpenLiftStateResolverTests` — active cycle/template/draft resolution
- `WorkoutDraftSelectionTests` — draft session preference rules
- `WorkoutEntryEditingTests` — set add/delete/reentry, weight prefill, entry repair

Expectations for new logic:
- Unit tests for happy path + edge cases
- Regression test for each bug fix
- Test service functions directly; don't test SwiftUI views

## Commit & Pull Request Guidelines
Use Conventional Commits:
- `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`

PRs should include:
- Concise summary of behaviour changes
- Test evidence (command + result)
- Sample payload or screenshot when export output or UI changes

## Security & Configuration
- `Config/Local.xcconfig` is gitignored — it holds your personal Apple Team ID and real bundle ID. Never commit it.
- Do not commit `.env` files, personal exports, or training data JSONs.
- The tracked bundle ID in `Shared.xcconfig` is a placeholder (`com.example.openlift`). Your real bundle ID lives only in `Local.xcconfig`.
- iCloud container: `iCloud.com.example.openlift` (mirrored from real bundle ID in local config).

## Documentation
Detailed design notes live in `docs/`:
- `architecture.md` — code-path map, data model intent, debugging hotspots
- `setup.md` — local dev environment, Apple account requirements
- `templates.md` — built-in starter template, published JSON format
- `data-and-history.md` — storage model, export paths, history recovery rules
- `ai-workflows.md` — what AI agents can/cannot do, recommended task types
