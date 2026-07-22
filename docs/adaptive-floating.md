# Adaptive Floating program

This document records the implementation constraints that refine the Adaptive
Floating build plan. Migration safety remains the first gate; none of the
following authorizes live-data migration or production programming values.

## One active program and one entry surface

OpenLift has one active training mode at a time: `rotation` or `adaptive`.
It does not generate or operate a fixed-cycle workout and an Adaptive workout
concurrently. Switching modes may preserve inactive history and a resumable
fixed-cycle pointer or draft, but only the active mode participates in Workout
resolution, generation, and completion.

Each user task keeps one entry page. In particular, `WorkoutView` remains the
single Workout surface and changes its content and behavior according to the
active mode. Shared set-entry, swap, completion, and history components are
reused; mode-specific services own planning and mutation rules. The internal
implementation must not create competing user-facing Workout pages.

## Ad hoc work during Adaptive mode

Ad hoc workout logging remains available regardless of active training mode.
When an ad hoc session is completed during Adaptive mode, its locked completed
sets contribute to the rebuildable training-load ledger. The next Adaptive plan
must account for that work when evaluating recovery, recent exposure, rolling
volume, binary training-window exposure, and eligibility.

Ad hoc work is load and recovery evidence, but is not automatically comparable
Adaptive-complex performance evidence. Drafts and unlocked sets never affect the
ledger. Substitutions or materially different occurrences remain not comparable
unless explicit matching rules prove equivalence.

Durable regression cases must prove that:

- only one training mode can resolve the Workout surface at a time;
- inactive-mode drafts and pointers cannot win active-mode resolution;
- completing ad hoc locked sets changes a subsequent Adaptive load ledger and
  may change the future plan;
- the same ad hoc session does not become a same-complex performance comparison;
- incomplete, unlocked, or deleted ad hoc entries have no planning effect.

## Adaptive profile and muscle scope

The supported programming buckets are Chest, Back, Triceps, Biceps,
Shoulders, Quads, Hamstrings, Forearms, Glutes, Calves, Abs, and Traps. The
initial enabled priority is:

1. Chest
2. Back
3. Triceps
4. Biceps
5. Shoulders
6. Quads
7. Hamstrings
8. Forearms
9. Glutes
10. Calves

Abs and Traps are explicit candidates but start disabled, unranked, and without
a training-window requirement. The persisted shoulder raw value remains `sideDelts` so old
stores continue to decode; it is presented as the broader Shoulders bucket.
The current catalog is side-delt focused, but future front- or rear-delt
exercise variants may use the same bucket.

Cycle contains the one Adaptive profile editor. A profile stores strict muscle
priorities, a binary training-window and recovered-gap policy, per-exposure and
per-exercise caps, and a default muscle-group exposure target (four by default).
Complexes are ordered atomic units with ordered component exercises, set counts,
primary plus optional major-secondary attribution, and easy/moderate/hard recovery context.
The training-window requirement is binary: one or more qualifying locked working
sets means the muscle was trained, regardless of set count. Set prescriptions
are adjusted separately from volume feedback and repeat performance. A muscle
with no qualifying exposure in its window is due and receives protection from
starvation without turning the missing history into an invented set quota.
The proposed slate remains editable: movements may be added, removed, swapped,
or reordered before it is accepted, including beyond the automatic target.
Exercises may also be added to a specific complex before or after the workout is
frozen. Explicit post-freeze additions create editable, prefilled set rows without
changing existing or locked work, and explicit reordering remains available until
the workout is completed. A skipped exercise can be restored before completion;
skip and restore actions remain in the immutable override audit trail. The
Workout surface is a linear Readiness, Design, and Execute flow. Readiness starts
at none / none / eager for every enabled muscle and one submission records all
defaults plus any edits. Design can reopen readiness, revise today's exposure
target without changing the profile default, and uses the same canonical planner
for every regeneration. Execute remains structurally editable until completion,
including locked-set correction or deletion. Both Design and Execute can append
an absent muscle through Add Complex; a configured complex is reused when
available and manual construction remains available when it is not.
Because completion publishes the final workout export for external ingestion,
Finish Adaptive Workout requires an explicit destructive confirmation. Cancelling
the confirmation leaves the active workout editable and unchanged.
After completion, the Workout tab shows a provisional prediction for tomorrow
using the normal planner queue, completed load ledger, profile workout size, and
an assumption of recovered readiness. The next day's actual readiness remains
authoritative and may replace that prediction.

Exercise continuity is configured per muscle rather than by a workout-wide
rotation rule. `Pinned exercise` always proposes one foundation movement;
`Repeat latest` preserves the most recently completed available movement; and
`Alternate recent` proposes the prior distinct available movement; when only one
movement has history, it chooses a different available movement to start the
rotation. A two-item pool then alternates across exposures and returns to each
exercise for progressive overload. Compound and isolation continuity are independent: a compound
recommendation targets the core slot and an isolation recommendation targets the
accessory slot, so a fly cannot replace a press. Rotation is restricted to the user's current-equipment availability
pool. The requested initial policy pins Belt Squat as the only currently available
heavy quad foundation; Safety Squat Bar Squat, Leg Press, and Hack Squat remain
unavailable heavy candidates, and Leg Extension remains an unavailable light
accessory. Stiff-Leg Deadlift is the currently available pinned heavy hamstring
foundation. Reverse Hyper starts as an available light hamstring accessory.
Glute-Ham Raise remains a candidate heavy foundation movement but starts unavailable
until the user is ready to perform it. Chest, back, triceps, biceps, shoulders, and forearms
alternate available recent movements. Glutes and calves repeat the latest
available movement until explicitly changed.
Exercise category is the single source of truth for recovery role: compounds are
hard/core movements and isolations are light/accessory movements. This applies to
automatic proposals, manual additions, and substitutions; a stored complex cannot
override the category with a different difficulty. Presses and rows are compound,
while flyes, curls, lateral raises, and analogous single-joint work are isolation.
Automatic plans include at most one compound for any muscle in a workout. A
compound-plus-isolation complex (for example, Incline Press plus Chest Fly) is
valid and remains atomic; two compounds for the same muscle are not proposed.
Manual slate editing remains an explicit escape hatch.
Saving an edit creates a new immutable profile and complex version. The starter is
labelled as requiring review and cannot invent catalog exercises for a missing
muscle.

No production training-window, cap, difficulty, or complex value is silently activated.
The initial rank above is user-supplied, but G3 remains open until the entire
production profile and complex library are explicitly reviewed.

## Readiness before difficulty

Observed muscle readiness is authoritative for future scheduling. Difficulty
is recovery context and a recovery-prediction hint only; it never
makes work eligible for an unrecovered muscle. An easy hamstring curl is held
when hamstrings are unrecovered after an SLDL exposure.

There is no global difficulty-point budget. Automatic planning strongly avoids
combining a hard quad movement with a hard hamstring movement when another
recovered muscle can fill the exposure target. The combination is not an error:
the planner may use it when no reasonable alternative exists, and manual edits
can always create it without a warning or confirmation.

Readiness checks are committed to SwiftData before Design appears. A distinct,
idempotent `adaptive_readiness` snapshot is then mirrored asynchronously under
`OpenLift/exports/readiness`; it is not a completed-workout payload and cannot be
hydrated by the completed-workout importer. A local recovery copy remains
pending rather than being reported as an iCloud success.

The first morning after a productive exposure is treated as a DOMS observation
window, not proof of recovery: even a low-soreness answer cannot schedule that
muscle again. Readiness is tested again beginning on the second calendar day,
when delayed soreness commonly becomes more informative. A high-soreness or
stop-pain answer continues to hold the muscle for as long as it is reported.
This observation window is based on direct work only: secondary loading from
chest does not bar triceps the next day, and secondary loading from back does
not bar biceps. Shoulders are explicitly eligible on consecutive days when
their current readiness is clear; soreness and pain answers still override.

Completed Rotation and ad hoc sets contribute to the muscle load/recovery
ledger. Ad hoc volume feedback is retained and may contribute conservatively to
a future dose recommendation, but ad hoc work and substitutions remain excluded
from like-for-like Adaptive-complex performance comparisons.
