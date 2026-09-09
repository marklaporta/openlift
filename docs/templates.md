# Templates

## How Templates Enter The App

OpenLift can get workout templates from three places:

1. templates already stored in SwiftData
2. published JSON files in `OpenLift/cycles`
3. a built-in fallback starter template named `4D Upper/Lower`

The built-in fallback is only used when there are no stored templates and no published cycles available.

## Built-In Starter Template

The built-in default is a 4-day upper/lower split:

- `Upper A`
- `Lower A`
- `Upper B`
- `Lower B`

Upper days include chest, back, delts, triceps, and biceps.
Lower days are lower-focused and do not include arm work.

The starter template is defined in [`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift).

## Published JSON Templates

Published templates are JSON files discovered from:

- `iCloud Drive/OpenLift/cycles`

The app can import them from the Cycle tab.

There is no separate Import tab. After placing a cycle JSON in this folder,
open Cycle, tap Refresh, then choose Import or Import + Activate.

Minimal shape:

```json
{
  "name": "4D Upper/Lower",
  "days": [
    {
      "label": "Upper A",
      "slots": [
        {
          "muscle": "chest",
          "exerciseName": "Flat Dumbbell Press",
          "defaultSetCount": 3
        }
      ]
    }
  ]
}
```

Notes:

- use `exerciseName` unless you have a specific reason to use `exerciseId`
- `exerciseName` must resolve against the seeded exercise catalog
- day labels matter because the app uses them in cycle progression and history display

## Vibe-Coding A New Template

Good workflow:

1. decide the split and day labels first
2. pick exercises from the seeded catalog already used by the app
3. keep slots ordered the way you want them displayed
4. validate on simulator
5. import and activate in the app

When asking an AI agent to generate a template, give it:

- target split, for example `4-day upper/lower`
- equipment constraints
- exercise preferences
- whether lower days should include any upper-body accessories
- whether to output a JSON published cycle file or code changes

Good prompt example:

```text
Create a published cycle JSON for a 4-day upper/lower hypertrophy split using only exercises already in OpenLift's seeded exercise catalog. Keep lower days strictly lower-body. Output valid JSON for OpenLift/cycles.
```

## Editing Templates In The App

The Cycle tab supports:

- creating templates
- cloning templates
- editing template days and slots
- importing published templates
- activating a template

Changing to a different active template requires confirmation.

`Clustered Hypertrophy v1`, `v2`, and `v3` are internal versioned program templates rather
than a general editable template. The Cycle tab disables editing and cloning it,
and rejects a published import that tries to replace its reserved name. Its
three cluster state rows and stable progression identities are created only by
the explicit backup-gated rollout described in
[`migration-safety.md`](migration-safety.md).

The reserved template has 15 structural days but the Workout tab never presents
them as one global day rotation. It presents the current selection from all
three clusters together. Each table column advances independently; rows are
identity mappings, not synchronized whole-workout days:

The Workout tab may replace a movement for only the current workout or for that
exact rotation slot going forward. The latter scope means program version plus
canonical template-day position plus slot position; it does not spill into a
different raw day that happens to share a shortened progression identity.
These choices are overlays, not template edits. Resetting a durable preference
restores the canonical movement, and locked positive-rep work blocks replacement.

**Original v1 mappings (archived after the [v2 revision](#september-2026-clustered-revision-v2)):**

| Identity | Cluster 1: chest + back | Cluster 2: legs + triceps + biceps | Cluster 3: shoulders + calves/forearms |
|---|---|---|---|
| A | Incline Dumbbell Press; Lat Pulldown | Belt Squat; Overhead Cable Extension; Incline Curl | Super ROM Dumbbell Lateral Raise; Stair Calves |
| B | Flat Dumbbell Press; Lat Prayer | Stiff-Leg Deadlift; Cable Pushdown; Dumbbell Preacher Curl | Cable Lateral Raise; Bench-Supported Cable Wrist Curl (Supinated) |
| C | Incline Press-Flye; Chest Supported Row | Sumo Belt Squat; Dumbbell Skullcrusher; Bayesian Curl | Super ROM Dumbbell Lateral Raise; Stair Calves |
| D | repeats A | Back Extension; Overhead Cable Extension; Incline Curl | Cable Lateral Raise; Bench-Supported Cable Wrist Extension (Pronated) |
| E | repeats B | Bulgarian Split Squat; Cable Pushdown; Dumbbell Preacher Curl | Super ROM Dumbbell Lateral Raise; Stair Calves |
| F | repeats C | Leg Curl; Dumbbell Skullcrusher; Bayesian Curl | Cable Lateral Raise; Captain of Crush |

Cluster 1 therefore has a three-step rotation; Clusters 2 and 3 each have six.
Cluster 2 derives three-step arm identities inside its six-step leg rotation.
Cluster 3 derives a two-step shoulder identity inside its six-step
calves/forearms rotation. One whole-cluster state advances atomically; there is
no pointer or completion action for an internal lane.

In v1, every slot defaults to three rows. A qualifying prior performance for the exact
progression identity replaces that default with its literal completed row count,
weights, and reps. Removing row three and completing that lane therefore makes
the next matching occurrence a two-row draft without changing the immutable
template. The two newly introduced cable-wrist exercises start with the approved
VOLTRA profile of 70% inverse chains and 30% eccentric.

`Complete Cluster` records every prescribed movement as performed or skipped and
advances that cluster even if all of its rows were skipped. `Finish Workout`
requires at least one completed cluster and persists only performed work from
completed occurrences. Partial-cluster advancement is intentionally unsupported.

## Where To Change The Default Starter

If you want to change the built-in fallback template, update:

- [`BootstrapDataService.defaultStarterTemplate(...)`](../Sources/BootstrapDataService.swift)
- starter-template tests in [`BootstrapDataServiceTests.swift`](../Tests/BootstrapDataServiceTests.swift)

That keeps fresh installs deterministic and test-covered.


### Cluster progress and completion recap

Each draft cluster shows Not started, In progress, or Completed with the count of
locked positive-rep sets. Prefilled editable rows do not mark a cluster started.
Complete Cluster saves/advances only that cluster; Finish Workout closes the
session without advancing untouched clusters. If another cluster contains locked
work, finishing names it and offers a Review action that navigates to that cluster.
The recap lists actual retained work and all three independent next selections,
explicitly distinguishing advanced from unchanged rotations. The existing 3/6/6
rotation model and set-count/prefill policies are unchanged.

## September 2026 clustered revision (v2)

This explicit, backup-gated content revision leaves the v1 reserved template,
completed history, old pointers, and old durable preferences archived. It does
not change the V14 SwiftData schema or reset raw cluster positions. The existing
cycle continues with v2 pointers at the same values.

- Cluster 1 A: Flat Dumbbell Press + Lat Pulldown.
- Cluster 1 B: Incline Dumbbell Press + Chest Supported Row.
- Cluster 1 C: Incline Press-Flye + Dumbbell Lat Pullover.
- Cluster 2 legs A–F: Leg Curl, Belt Squat, Stiff-Leg Deadlift, Safety Bar Squat,
  Back Extension, Bulgarian Split Squat. The triceps/biceps pairs keep their
  original raw-day positions; Cluster 3 is entirely unchanged.

Dumbbell Lat Pullover is the default. Cable Lat Pullover is available through the
existing exact-slot/workout-only substitution flow, with the usual cable/VOLTRA
resistance-profile editor. No load or VOLTRA settings are invented.

Surviving movements retain their v1 semantic progression identities, independent
of their new structural position. The pullover gets a fresh identity and copies
only the retired straight-arm lane's literal completed row count, not its load,
reps, or resistance profile. Safety Bar Squat reuses the existing safety-squat-bar
exercise UUID and the same-exercise Sept 5 performance (225 × 6, 5), via the old
Cluster 2 F progression key. The lookup additionally requires the exercise UUID,
so leg curls, belt squats, and substitutions cannot contaminate that baseline.

V1 exact-slot preferences are carried by canonical exercise meaning to v2 when
the canonical movement survives. Preferences on retired lat-prayer/sumo slots
remain archived, not mapped onto the new movements. In particular, a Bulgarian
split squat preference on the former sumo slot cannot replace Safety Bar Squat.

The authorized name correction changes the catalog name to **Safety Bar Squat**
and only that movement's frozen name evidence in session
`734246BD-22B9-4D6E-BF88-130B5144B28A`. It preserves the exercise UUID, sets, dates,
profiles, progression key, and all other completed snapshots. The corrected
session is marked pending and re-exported after the revision transaction.

## Seated dumbbell shrug revision (v3)

V3 adds **Seated Dumbbell Shrugs** after the existing movements in **Cluster 3
A/C/E** (canonical template positions 9/11/13). Those calf-day variants start
with two shrug rows and a displayed target of 12–16 reps. B/D/F retain only their
existing shoulder and forearm movements. This is every other Cluster 3 exposure,
not a calendar schedule; there is no SLDL exclusion or missed-work catchup.

The first shrug inputs are blank: no working load or completed performance is
invented. All three shrug slots share one new traps progression identity. Later
drafts repeat its literal completed row count, weights, and reps, so completing
one row carries forward one row. The normal add/remove/skip behavior remains.

Existing movements keep their v2 prescriptions, exact-slot substitutions,
resistance profiles, and v1/v2 progression identities. All three independent raw
pointers are copied unchanged; activation neither advances a cluster nor forces
an immediate shrug exposure. V1/v2 templates, preferences, pointers, and completed
history remain archived. Apply only through the explicit, backup-gated
[v3 content revision](migration-safety.md#seated-shrug-content-revision-v3):
finish the current workout, then use **Cycle → Add Seated Dumbbell Shrugs**. The app
makes and verifies a fresh pre-revision store snapshot before applying.

Catalog bootstrap corrects the former singular label to **Seated Dumbbell
Shrugs** using the same exercise UUID. It leaves existing slots, draft/completed
sets, progression keys and frozen historical names unchanged. Old singular-name
exports remain an import alias; conflicting existing identities are not merged.

## Safety-bar/Bulgarian placement swap (v3 preferences)

**Cycle → Swap Safety Bar Squat & Bulgarians** keeps v3 and swaps only Cluster 2
D/F through durable exact-slot preferences. The resulting leg order A–F is
Leg Curl, Belt Squat, Stiff-Leg Deadlift, Bulgarian Split Squat, Back Extension,
Safety Bar Squat. This separates the two major spinal-loading movements, SLDL
and Safety Bar Squat, without changing the other lanes or advancing a pointer.

Both original squat UUIDs retain their original progression keys at D/F, so
same-exercise completed row counts, loads and reps follow the movement. Other
substitutions retain slot isolation. Canonical templates, completed occurrence
snapshots, notes and resistance profiles are unchanged. The preference payload
already supported by JSON export/recovery carries the new placement.
