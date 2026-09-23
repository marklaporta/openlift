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
- V13 clustered Fixed Cycle state and immutable completed-cluster occurrences:
  exactly `ClusterRotationState` and `ClusterOccurrenceRecord`
- V14 clustered exercise overlays: exact-slot `ClusterExercisePreference` and
  session-scoped `ClusterExerciseOccurrenceOverride`

## Exercise setup notes

Tap “Add exercise note” or an existing note above the set rows in Fixed Cycle
(including clustered workouts), Adaptive execution, or the Log tab. Save updates
the note; Cancel leaves it unchanged. Clear Note empties the editor and Save
commits the removal. The Log tab allows editing any selected exercise without
starting or saving a workout.

Notes use the existing `Exercise.notes` field and stable catalog identity, so the
same exercise shares its editable note across sessions, slots, and modes. A
substitution shows the replacement exercise's own note. No schema migration or
workout-program change is required. Notes survive app restarts and full-store
backup/restore. Exports for embedded program definitions also include referenced
catalog notes as recovery evidence. Hydration restores notes for missing UUIDs,
not over existing catalog entries; exact restoration of existing edited or
cleared notes requires a full-store backup. See [program recovery](program-updates.md#persistence-and-recovery).

## Resistance units and recovery

V15 adds optional `chainPounds` and `eccentricPounds` to occurrence profiles.
Shipped percent profiles retain their raw integer fields and nil pound fields.
JSON exports add optional `chain_pounds` / `eccentric_pounds`; the corresponding
percent field is absent for a pound-valued modifier. Frozen cluster snapshots
use the same value semantics. Legacy exports decode unchanged. Fixed/ad-hoc and
Adaptive recovery, swaps, last-used defaults, locking, and comparison all carry
the selected units without reinterpreting set base weights.

## What Counts As History

The History tab opens in **Movements**: recent-first movement browsing with always-visible
exercise search and an A–Z sort option. Search accepts compact/expanded names and
explicitly consolidated CS DB Row aliases. Tap a movement for literal set weights
and reps across workouts. **Workouts** retains the date-first list and session details.

Movement details default to the most recent progression-key/resistance-profile
setup; the setup picker exposes other setups and all performances without blending
their trends. The performance chart uses `weight × (1 + reps / 30)` (Epley),
normalized to the first set at the start of each contiguous comparable setup = 100.
This is a load–rep trend estimate, not measured 1RM. First-set lines are emphasized;
other set positions share that baseline, and diamonds mark first-set load changes.
Dates retain calendar spacing. Profile/progression changes (including A → B → A)
reset the baseline and break lines even when filtering to one setup; missing set
positions break their own lines. Exact numbered weight/reps rows remain below.
Zero/nonfinite loads, ambiguous evidence, missing first sets, and unrecorded or
incomplete cable profiles are not indexed; no bodyweight or resistance modifiers
are invented. Grippers retain model labels and never index model ordinals as pounds.
Completed fixed, ad hoc, Adaptive, and export-only records are included; stored sessions win over
recovery mirrors by ID. Clustered rows require performed occurrence evidence when
cluster metadata exists. Draft, unlocked, skipped, and zero-rep work is excluded.
This projection is read-only and does not change progression, programs, or drafts.

Ad hoc logging remains available in either training mode. Completed locked ad
hoc sets will be load/recovery evidence for Adaptive planning. Direct sets count
toward the exercise primary muscle's set-rate target; secondary muscles receive
recovery context but no target credit. Ad hoc work is not automatically
same-complex performance evidence. Drafts and unlocked sets do not count.

Exercise effort history is shared across modes by canonical exercise identity.
Fixed Cycle first searches completed nonzero occurrences of the same stable
cycle-instance day, skipping zero-set omissions, and then falls back to the newest qualifying
Fixed Cycle, Adaptive, or ad hoc effort. Adaptive and ad hoc have no stable
cycle-day identity and use the global newest effort directly. New Fixed/clustered
rows copy the literal completed set count and weights, with blank actual reps
and prior reps shown as reference. Adaptive/ad hoc prefill is unchanged.

Cable effort adds one more identity gate: resistance source and the complete
raw profile must match. Different or unknown profiles are shown as reference
history but are not silently prefilled or scored against each other.

The versioned clustered program uses an explicit progression key per exercise
slot. Each version defines its identity mapping; historical key namespaces may
be retained across reordered positions. The current v8 layout is 4/8/6 steps,
with only one runtime state per whole cluster. A same-key prior occurrence with
an exact resistance profile is preferred;
if none exists, the newest same-key occurrence with another or unknown profile
is the explicit progression fallback. A fresh key may consult only legacy,
unkeyed global history as initial reference, without retroactively relabeling it
or considering sessions already owned by any versioned progression identity.
Legacy cable history must still match the current complete profile to prefill.
New drafts copy the literal qualifying row count and weights, not performed
reps, so manually reducing a non-leg lane from three rows to two carries forward after that lane is
completed. With no qualifying effort, the template supplies its literal
prescribed count.

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

## Recovery Scope

Daily full-store snapshots preserve the database, including program, rotations,
readiness, drafts, and catalog notes. Workout JSON supports missing-history
hydration and the program/occurrence evidence it explicitly contains; one late
workout export is not a complete store backup.

Agent-managed backup preview/restore is not yet implemented. The program bridge
only manages supported revisions, not store replacement or recovery. Recovery
work must distinguish these inputs and prove the intended result on a disposable
copy before changing a live store.

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
the three explicit rotation states. Only clusters intentionally completed in
the session are exported. Unfinished clusters and unperformed exercises are
omitted from completed-workout exercise lists; an all-skipped completed cluster
still exports its empty occurrence as advancement evidence. Export retries use
the frozen occurrence rather than the mutable live template. Exported exercise
names, muscles, and resistance profiles also use that snapshot, including an
unknown profile; a changed or missing live catalog/profile record cannot rewrite
or remove the performed evidence. The exporter also
rechecks that every set row is locked, positive-rep, and backed by a performed
occurrence snapshot, so a retry cannot leak rows from an untouched cluster.
Hydration restores explicit exported states when present and otherwise derives a
state only from gap-free, non-conflicting occurrence steps.
An explicitly confirmed occurrence-wide profile correction updates both the
live profile and that performed exercise's frozen cluster profile, marks the
session export-pending, and leaves progression identity, structure, and sets
unchanged. Ordinary edits never rewrite completed cluster snapshots.
All affected snapshot corrections are validated and encoded before changing live
or frozen records; malformed snapshot data rejects the correction without
partially applying it or discarding unrelated pending edits.
The same optional metadata exports the current durable exact-slot preferences
and active session overrides, including exercise descriptors needed for
recovery. Hydration restores preferences from the newest clustered snapshot and
session overrides by stable identity. Completed occurrence snapshots remain the
immutable source of truth for what was actually performed.

Adaptive workouts use additive schema v2 JSON. The payload records
`workout_kind: adaptive`, the session UUID, raw readiness/version, planner
version, ordered frozen complex and component snapshots, planned occurrence
IDs, actual locked sets, overrides, and feedback. Hydration deduplicates
Adaptive work by session UUID and reconstructs parallel Adaptive records; it
never creates or advances a Rotation cycle.
Adaptive hydration requires a clean caller context and rolls back rejected
nested snapshots, invalid set identities, or failed saves. It neither commits
unrelated draft edits nor leaves partial recovered objects for a later save.

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

## Unified history and recovery evidence

History interleaves Fixed Cycle/ad-hoc, Adaptive, and recovery-export-only sessions
in one newest-first timeline. Stable session IDs (case-normalized for JSON) merge
local/cloud export copies and prefer persisted sessions. Timestamp/name equality
does not collapse distinct workouts. Exercise search includes recovery-only work.

Completed screens distinguish the saved workout from its recovery JSON and the
daily full-store snapshot. An export's upload confirmation is not proof that
planner/rotation/readiness state is backed up. The full-store snapshot is daily
and may predate the workout just completed. Diagnostic filenames and timestamps
are available under **Backup Details**, not the primary workout flow.

Daily SQLite backups require a readable nonempty file and a successful SQLite
quick-check result. A cloud backup additionally requires ubiquitous-item and
uploaded metadata without an upload error. Pending retries reuse checked snapshot
bytes, avoiding repeated VACUUM/replacement/upload cycles. Evicted cloud snapshots
are requested for download and never blindly overwritten. Only integrity-checked snapshots count toward retention; cloud snapshots must also
have confirmed upload metadata. Pending/corrupt files cannot displace the last
seven verified recovery points.

### CS DB Row identity

The existing dumbbell-row UUID remains the one active selectable **CS DB Row**.
The two older catalog rows stay inactive: completed set IDs, names in frozen
occurrences, resistance profiles, and export evidence remain unchanged. Their
setup notes and the bench/Rogue lat-seat equivalence are retained in the
canonical notes. Future template/pool/program preferences resolve to the
canonical exercise. Rotation counters, versioned progression keys, and doses
are not rewritten.

History search accepts all three old names or `CS DB Row` and returns their
combined history with the canonical label. The selected exercise’s history sheet
also includes the old Fixed/Adaptive efforts; inactive aliases are excluded from
all future-entry pickers. Adaptive exercise recency resolves to the same identity.
Repeat-last lookup considers the
old identities only after activation, retaining key/profile precedence and
each effort's literal rows; it never concatenates sets from two identities.
Stored resistance profiles are not reinterpreted as dumbbell pounds.
Published-template imports resolve old IDs and names to the canonical entry.
Workout recovery retains known historical IDs and exact/expanded-name catalog
matches, including inactive legacy rows. Only unresolved names fall back to the
canonical equivalent: redirecting a known name-only export would duplicate its
sets alongside the preserved historical identity. Catalog seeding and new-entry
validation do not recreate selectable aliases.

## CoC gripper model storage (V16)

Captain of Crush / CoC Gripper stores the model identity **G**, **T**, or **1**
in `gripperModel`, with `numericWeight = 0` (not a zero-pound gripper). New
Fixed Cycle, Adaptive, and ad hoc sets use this representation. `weight` is a
computed compatibility adapter for the existing picker/prefill algorithms, not
a persisted ordinal. Other exercises keep their original numeric loads.

For untagged older data, ordinal `1` means G, `2` means T, and `3` means model
"1". Unknown values remain numeric and visibly unknown; never round or guess
a model from them.

JSON sets use `gripper_model` plus `load_encoding: "coc_model_identity_v2"`
and `weight: 0`. The semantic token `"1"` cannot be confused with legacy
numeric `1` (model G). Both Fixed/ad hoc and Adaptive exports carry this
metadata. Invalid tagged values fail decoding rather than falling back to a
numeric import. Untagged historical exports still decode with the old mapping;
recovery and new prefills save recognized values as semantic identities.

### Compact catalog labels

Normal catalog bootstrap shortens `Dumbbell` → `DB`, `Single-Arm` → `SA`,
and `Chest-Supported` → `CS` (including spaced variants), retaining UUIDs.
Published templates and Fixed/Adaptive recovery accept old and compact names.
Exact labels/UUIDs take priority; ambiguous compact aliases never select an
arbitrary movement. Existing names whose compact labels collide remain unchanged.
Completed occurrence snapshots, progression keys, drafts, and program selections
are not renamed or reset. `CS DB Row` is a label, not consolidation activation;
combined history still requires the canonical entry and both inactive legacy IDs.

### Fixed Cycle numeric entry

New Fixed/clustered draft rows retain the previous qualifying weight and literal
set count, but start with no performed reps. The previous weight/reps remain in
the exercise's inline reference. Existing drafts and completed history are not
rewritten. Unchanged weight is accepted when the user explicitly completes a set;
a positive rep count is required (zero weight remains valid for bodyweight work).

Numeric fields select existing text on focus for direct replacement. Raw decimal
text stays local to the native text field while typing; it does not re-render the
workout or save SwiftData per keystroke. A one-second idle checkpoint, leaving the
field, backgrounding, or a workout action flushes validated edits. Keyboard
**Complete Set** commits the latest character and completes that row in one tap;
**Done** only saves/dismisses. Invalid input remains visible for correction, and
failed saves preserve the raw edit for retry. Profile freezing and set completion
share one save, preserving the resistance source and modifier units.

Adaptive and ad hoc entry are separate flows and are unchanged by this input work.
