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
per-exercise caps, and an automatic component-movement target (four by default).
Complexes are ordered atomic units with ordered component exercises, set counts,
primary plus optional major-secondary attribution, and easy/moderate/hard recovery context.
The training-window requirement is binary: one or more qualifying locked working
sets means the muscle was trained, regardless of set count. Set prescriptions
are adjusted separately from volume feedback and repeat performance. A muscle
with no qualifying exposure in its window is due and receives protection from
starvation without turning the missing history into an invented set quota.
The proposed slate remains editable: movements may be added, removed, or swapped
before it is accepted, including beyond the automatic target.
Saving an edit creates a new immutable profile and complex version. The demo is
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

There is no global difficulty-point budget. The hard composition rule is
specific: a hard quad movement and a hard hamstring movement are not placed in
the same workout. Other hard combinations remain eligible when their muscles
are recovered and their configured caps fit.

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
