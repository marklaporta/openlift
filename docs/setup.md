# Setup

## What You Need

- a Mac with Xcode installed
- an Apple ID
- an Apple Developer membership if you want full signing/distribution capabilities
- Git
- optional: OpenAI Codex or Anthropic Claude Code for agent-assisted development

## Apple Account And Xcode

For local simulator development, Xcode alone is enough.

For device builds and iCloud entitlements, you should expect to:

1. sign into Xcode with your Apple ID
2. enroll in the Apple Developer Program if required for your intended workflow
3. create or reuse an app identifier and iCloud container under your own Apple team
4. let Xcode manage signing automatically unless you have a reason not to

Official starting points:

- Apple Developer enrollment: `https://developer.apple.com/programs/enroll/`
- Xcode download and release page: `https://developer.apple.com/xcode/`

## Clone And First Build

1. Clone the repo.
2. Copy [`Config/Local.example.xcconfig`](../Config/Local.example.xcconfig) to `Config/Local.xcconfig`.
3. Replace the placeholder values:
   - `OPENLIFT_APP_BUNDLE_ID`
   - `OPENLIFT_TEST_BUNDLE_ID`
   - `OPENLIFT_UI_TEST_BUNDLE_ID`
   - `OPENLIFT_ICLOUD_CONTAINER`
   - `OPENLIFT_KVSTORE_ID`
   - `OPENLIFT_DEVELOPMENT_TEAM`
4. Open [`OpenLift.xcodeproj`](../OpenLift.xcodeproj).
5. Build for simulator first.
6. Then test a device build if you need iCloud and physical-phone behavior.

## Why The Config Is Split

Tracked config files under [`Config`](../Config) contain public app identifiers,
entitlement names, and build settings. Apple bundle, team, issuer, and key IDs
are identifiers rather than credentials, but private keys, signing certificates,
bearer tokens, and private endpoints do not belong in tracked files.

The ignored local override:

- keeps your personal bundle ids out of git
- keeps your Apple team id out of git
- lets you keep using your real iCloud container on your own Mac

## Common Xcode Commands

### Fast everyday checkpoints

```bash
scripts/test.py                       # all unit/service + synthetic migration tests
scripts/test.py unit ExportIntegrityTests  # affected class while editing
scripts/test.py ui ResistanceProfileUITests/testVOLTRAModifiersAcceptIndependentPoundsAndPercentInputs
scripts/test.py full                  # all unit and UI methods, no filters
```

The runner keeps incremental DerivedData and ownership records for dedicated,
reusable **disposable** iPhone 17 simulators in `.build/tests/`. Unit or focused
UI runs need one simulator; all-UI/full runs use three. First use creates fresh
simulators; subsequent runs never choose a personal simulator by name. Do not
stage personal stores or use these simulators for manual data recovery.

Unit tests run serially. The full UI target is partitioned into three balanced,
disjoint groups on distinct simulators, avoiding Xcode's variable clone startup
and late dispatch of long classes. Two groups name existing long flows; the third
is **the entire UI target minus those groups**, so new UI classes remain included
automatically. No UI methods are omitted from an unfiltered `ui` or `full` run.
The ordinary Xcode scheme remains available for debugging and direct test runs.

Each invocation performs incremental `build-for-testing`, then runs those
just-validated products with `test-without-building`. The three UI processes only
read shared build products; they never build concurrently. There is no unchecked
skip-build mode, so edits cannot silently run stale binaries. The runner disables
signing, forces empty direct-export settings, and ignores inherited copied-store
fixture paths; use the separate [migration gates](migration-safety.md) for those.

Each dated run directory contains `build.log`, boot logs, per-part test logs and
`.xcresult` bundles, per-part summaries, and aggregate `summary.json`. Zero-test
selections and test/build failures fail the checkpoint. `unit` is the default fast
lane, **not** a full-suite pass; `full` runs units and all UI groups and refuses
filters. First-build/first-boot costs still apply on a fresh checkout. Simulators
are kept for reuse; exact IDs are in `.build/tests/simulator-1.json` through
`simulator-3.json` (created as needed).

### Measured checkpoint timing

On an M4 with iPhone 17 / iOS 26.5 simulators (September 7, 2026), the same
13 UI methods took **397.5s → 287.8s** using prepared simulators: about **28% less
wall time**. The new runner's time includes its incremental build check. Aggregate
UI method time fell **841.4s → 615.2s**; all assertions and screenshots remain.
A warm all-unit checkpoint took **23.2s** (348 passed, two copied-store opt-in
skips). All 363 methods are retained: 350 unit and 13 UI.

These are measured runs, not a universal timing guarantee. First-boot migration,
build caches and Xcode worker scheduling materially affect wall time; an initial
fresh-clone baseline took 647.1s and is deliberately not the comparison above.
The long adaptive end-to-end flow remains intact and still sets a useful lower
bound. Copied personal-store gates and physical-device/cloud delivery are not
part of these simulator measurements.

### Direct Xcode commands

Simulator unit checkpoint (use a disposable simulator without staged personal stores):

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OpenLiftTests OPENLIFT_DIRECT_EXPORT_ENDPOINT= OPENLIFT_DIRECT_EXPORT_BEARER_TOKEN=
```

During edits, select the affected service class with
`-only-testing:OpenLiftTests/ServiceTests`. Run the ordinary unit target at an
integration checkpoint; synthetic migrations are included. Select UI flows for
changed screen wiring, for example:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:OpenLiftUITests/ResistanceProfileUITests/testVOLTRAModifiersAcceptIndependentPoundsAndPercentInputs \
  -only-testing:OpenLiftUITests/SwapExerciseUITests/testLogWorkoutSavesEnteredSetToLocalHistory \
  -maximum-parallel-testing-workers 3 \
  OPENLIFT_DIRECT_EXPORT_ENDPOINT= OPENLIFT_DIRECT_EXPORT_BEARER_TOKEN=
```

Use broader UI runs for broad navigation changes or release validation, not
for every service edit. Report the selected checks and opt-in skips; a unit-only
run is not a full-suite pass. Repeat passing checks only for a relevant change
or unresolved failure.

Export tests inject temporary paths and direct-delivery callbacks. Constructed
`ExportEnvironment` values do not schedule direct delivery unless explicitly
supplied a callback; production `.live()` retains that behavior. UI-test launches
use an in-memory model and a process-local temporary export directory, with no
live iCloud or direct-export transport. The ad hoc save flow verifies the entered
set in local History, not cloud upload or persistence across app launches.

Copied-store migration and September content-revision tests remain opt-in;
follow [migration safety](migration-safety.md) when schema/startup/recovery or
that explicit rollout changes. Neither a skipped copied-store gate nor synthetic
fixtures establish compatibility with every installed historical store.

Device build:

```bash
xcodebuild -scheme OpenLift -destination 'id=<DEVICE_UDID>' -configuration Debug build
```

Show destinations:

```bash
xcodebuild -scheme OpenLift -showdestinations
```

## TestFlight Deployment

TestFlight requires a paid Apple Developer Program membership and an App Store
Connect app record for the configured bundle identifier.

Archive locally without uploading:

```bash
scripts/testflight-deploy.sh archive
```

Archive and upload:

```bash
scripts/testflight-deploy.sh
```

The script assigns a UTC timestamp build number, keeps generated archives under
`.build/testflight/`, and refuses to deploy a dirty worktree by default.

This repository script uses Xcode's automatic-signing archive path. It works in
an interactive Aqua/Xcode login session with the signing identity available in
Keychain. It does **not** work from OpenClaw's headless System security session,
where Keychain signing identities are unavailable. Headless OpenClaw deployment
must use the canonical workspace device/TestFlight deployment scripts, which
build unsigned and sign from private material stored outside this repository.
Those scripts and their private configuration are intentionally not copied or
documented here.

It can use the Apple account saved in Xcode. For unattended deployment, create
an App Store Connect API key and provide all three values:

```bash
ASC_KEY_ID=... \
ASC_ISSUER_ID=... \
ASC_PRIVATE_KEY_PATH=/absolute/path/to/AuthKey_....p8 \
scripts/testflight-deploy.sh
```

Do not commit the private key. Optional overrides are
`OPENLIFT_BUILD_NUMBER`, `OPENLIFT_MARKETING_VERSION`,
`OPENLIFT_TESTFLIGHT_OUTPUT_DIR`, and `OPENLIFT_ALLOW_DIRTY=1`.

## iCloud Expectations

The app uses iCloud Documents style storage for:

- published cycles in `OpenLift/cycles`
- completed exports in `OpenLift/exports`
- draft exports in `OpenLift/exports/drafts`

If iCloud is unavailable, workout exports fall back to the app's local documents directory.

## Safe Local Hygiene

Do not commit:

- `Config/Local.xcconfig`
- `.p8`, `.p12`, `.pem`, or `.key` signing material
- provisioning profiles
- app container dumps
- SwiftData/SQLite stores and their `-wal`/`-shm` sidecars
- exported workout JSON from your own usage
- Xcode user-state files
- archives, IPAs, dSYMs, and local build output

The repo ignores these classes via [`.gitignore`](../.gitignore), but keep
credential and personal-data artifacts outside the checkout as the primary
boundary. Before publishing, scan both the current tree and reachable history;
GitHub secret scanning and push protection are a second line of defense, not a
replacement for local hygiene.
