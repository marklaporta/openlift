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

`Clustered Hypertrophy v1` is an internal versioned program template rather
than a general editable template. The Cycle tab disables editing and cloning it,
and rejects a published import that tries to replace its reserved name. Its
three cluster state rows and stable progression identities are created only by
the explicit backup-gated rollout described in
[`migration-safety.md`](migration-safety.md).

The reserved template has 15 structural days but the Workout tab never presents
them as one global day rotation. It presents the current selection from all
three clusters together. Each table column advances independently; rows are
identity mappings, not synchronized whole-workout days:

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

Every slot defaults to three rows. A qualifying prior performance for the exact
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
