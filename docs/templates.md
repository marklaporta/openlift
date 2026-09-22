# Templates And Clustered Programs

## Current Program

The bundled v8 definition in
[`BundledClusterPrograms.swift`](../Sources/BundledClusterPrograms.swift) has
three independently advancing rotations:

| Cluster | Steps | Work |
|---|---|---|
| 1 | 4 | Chest, back, triceps, and biceps scheduled together |
| 2 | 8 | Legs |
| 3 | 6 | Shoulders, calves, forearms, and accessories |

All three current selections appear in one workout. Scheduling is separate from
visual grouping: when Cluster 1 contains torso and direct-arm slots, the workout
shows Torso → legs (Cluster 2) → Arms → Cluster 3 as separate cards. Torso and
arms keep one shared rotation and one **Complete Torso + Arms** action after the
arm rows; log sets anywhere in the workout before completing them. The display
split uses prescribed slot muscles (including substituted exercises), and
completed cards use frozen occurrence muscles. Historical unsplit selections
retain their original cards. This presentation change needs no activation.

Completing a cluster advances only its own raw counter; there is no global workout-day rotation or
independently advancing movement lane. `Finish Workout` requires at least one
completed cluster. Skipped rows do not block whole-cluster completion, but only
locked positive-rep rows backed by performed occurrence snapshots enter history
and exports.

The stored template and exact-slot overrides determine effective selections.
Bundled content is a fallback, not authority to reset a live program. Use the
bridge's `starter` command to inspect the actual program rather than infer it
from the bundled definition.

## Program Content And Identity

[`ClusterProgramDefinition.swift`](../Sources/ClusterProgramDefinition.swift)
defines program/version identity, ordered steps and structural template
positions, exercise references, fallback counts, and progression rules. The
generic interpreter owns selection, validation, and recovery construction.
Loading a definition does not activate it or write the store.

A qualifying previous effort supplies its literal set count and weights. With
no qualifying effort, the stored template supplies its fallback count. New
Fixed/clustered rows start with blank actual reps; prior reps stay visible as
reference. Completing two rows can therefore carry two rows forward without
editing the template.

Progression identity is not display order. Reordering a movement must retain its
valid identity mapping rather than inherit the previous occupant's loads.
Existing stored occurrence identities remain readable and are never rebuilt
from today's definition. Setup instructions reference catalog notes; custom
and deliberately empty notes survive.

For Overhead SA Cable Extension, one row represents one set on each side;
record load and reps per side. Seated DB Hammer Curl loads are per dumbbell.

## Exercise Substitutions

Workout can replace a movement for this workout only or for the exact rotation
slot going forward. Persistent scope is program version + canonical template-day
position + slot position, not every position sharing a progression identity.
Resolution is occurrence override, persistent preference, then canonical exercise.
These choices are overlays, not edits to the reserved template. Locked
positive-rep work blocks replacement; resetting a persistent preference restores
the canonical movement.

## Program Updates

Use [`scripts/program-agent.py`](../scripts/program-agent.py) from a trusted
paired Mac to export a starter, preview a revision, and apply the exact approved
preview. [Program updates](program-updates.md) defines the supported bounds,
authority, draft protection, backup, and receipt contract. There is no in-app
administration menu.

## Fresh-Install Template Selection

Bootstrap uses stored templates first. If none exist, it can discover published
JSON in `OpenLift/cycles`; otherwise it creates the built-in `4D Upper/Lower`
fallback: Upper A, Lower A, Upper B, Lower B. This does not automatically activate
the clustered program.

Published-cycle parsing remains a compatibility input to bootstrap, not the
versioned bridge format. Its decoder is
[`PublishedCycleService.swift`](../Sources/PublishedCycleService.swift). Starter
content and fallback selection live in
[`BootstrapDataService.swift`](../Sources/BootstrapDataService.swift); changing
the fallback must not overwrite stored user templates.
