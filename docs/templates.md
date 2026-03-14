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

## Where To Change The Default Starter

If you want to change the built-in fallback template, update:

- [`BootstrapDataService.defaultStarterTemplate(...)`](../Sources/BootstrapDataService.swift)
- starter-template tests in [`BootstrapDataServiceTests.swift`](../Tests/BootstrapDataServiceTests.swift)

That keeps fresh installs deterministic and test-covered.
