# Hypertrophy Rotation Tracker – Product Requirements Document (PRD)

## 1. Product Overview

A deterministic, rotation-based hypertrophy training tracker with:

* Locked exercises per mesocycle
* Local-first session logging
* Auto-advancing workout rotation
* Optional AI-generated cycle templates (via JSON import)
* Lightweight per-muscle rolling weekly volume estimates
* Structured data export to iCloud Drive

This is **not** an AI coaching system or progression enforcement engine.
It is a structured execution + logging system with optional planning acceleration.

---

# 2. Core Product Philosophy

1. Exercises are locked for the duration of a mesocycle.
2. Sets are adjustable per session (optionally persistent).
3. No automatic deload logic (user simply takes time off).
4. No progression enforcement.
5. No required AI usage.
6. Rotation-based, not calendar-based.
7. Local-first persistence; export on workout completion.

---

# 3. Scope (v1)

## Included

* Cycle templates
* Cycle cloning
* Rotation engine
* Session logging
* Add/remove sets per workout
* Optional persistent set count changes
* Per-exercise history
* Session history
* JSON export to iCloud
* AI JSON cycle import
* Rolling weekly set estimates per muscle

## Explicitly Excluded (v1)

* Charts or dashboards
* Fatigue algorithms
* RIR logging
* Load prescriptions
* Cloud sync
* Multi-device support
* Automatic deload systems
* AI live control of sessions

---

# 4. Supported Muscle Groups (v1)

* Chest
* Back
* Quads
* Hamstrings
* Biceps
* Triceps
* Side Delts

No other muscle groups in v1.

---

# 5. Core Entities & Data Model

## 5.1 Exercise

```json
{
  "id": "UUID",
  "name": "string",
  "primaryMuscle": "enum",
  "type": "compound | isolation",
  "equipment": "machine | barbell | dumbbell | cable | bodyweight",
  "notes": "string",
  "isActive": true
}
```

Rules:

* AI may only reference existing exercises.
* Exercises must belong to supported muscle enum.

---

## 5.2 CycleTemplate

```json
{
  "id": "UUID",
  "name": "string",
  "days": [
    {
      "label": "string",
      "slots": [
        {
          "muscle": "enum",
          "exerciseId": "UUID",
          "defaultSetCount": 3
        }
      ]
    }
  ],
  "rotationPools": {
    "quads_compound": ["exerciseId1", "exerciseId2"]
  }
}
```

Rules:

* Exactly one slot per muscle per day.
* Max one compound leg movement per day.
* Max 3 sets per slot (v1).
* No duplicate muscle slots per day.
* Rotation pools optional (used for quad compounds).

---

## 5.3 ActiveCycleInstance

```json
{
  "id": "UUID",
  "templateId": "UUID",
  "currentDayIndex": 0,
  "rotationIndices": {
    "quads_compound": 0
  }
}
```

Behavior:

* Resets rotation index when new meso activated.
* Resets day index to 0 on activation.

---

## 5.4 Session

```json
{
  "id": "UUID",
  "cycleInstanceId": "UUID",
  "cycleDayIndex": 0,
  "createdAt": "ISO8601",
  "finishedAt": "ISO8601",
  "status": "draft | completed",
  "exportStatus": "pending | success | failed"
}
```

---

## 5.5 SetEntry

```json
{
  "id": "UUID",
  "sessionId": "UUID",
  "exerciseId": "UUID",
  "setIndex": 1,
  "weight": 225,
  "reps": 8
}
```

---

# 6. Rotation Logic

* On app launch:

  * If draft session exists → load it.
  * Else → create new session from current cycle day.

* On Finish Workout:

  * Mark session complete.
  * Export JSON to iCloud.
  * Advance day index.
  * Create next draft session automatically.
  * Load next workout immediately.

No calendar logic involved.

---

# 7. Workout Session Behavior

## Prefill Rules

* Prefill weight/reps from last session for that exercise.
* No progression enforcement.
* Regression allowed without penalty.

---

## Add Set (Session Only)

* Increments planned set count.
* Adds empty set row.
* Prefills weight from prior session if available.
* Does not modify template unless user confirms.

---

## Remove Set

* Removes last unlogged set without confirmation.
* Removing logged set requires confirmation.
* Does not modify template unless user confirms.

---

## Persistent Set Change Option

When adding/removing sets:

Prompt:

* Today Only
* Apply to This Cycle Day

If persistent:

* Update CycleTemplate slot defaultSetCount.

---

# 8. Session History

## Session List

Displays:

* Date
* Cycle Name
* Day Label
* Exercise Count
* Export Status

## Session Detail

* Read-only
* Shows all exercises and sets
* Retry Export button if failed

---

# 9. Rolling Weekly Volume Estimation

## Frequency Calculation

Based on last 30 days:

```
avg_sessions_per_week = (sessions_last_30_days / 30) * 7
```

## Weekly Sets Per Muscle

```
weekly_sets =
(total_sets_per_cycle_for_muscle)
*
(avg_sessions_per_week / cycle_length)
```

Displayed inside Cycle Builder only.

Informational only. No enforcement.

---

# 10. AI Integration

## Design Principles

* AI planning is optional.
* AI cannot mutate active cycle.
* AI cannot create new exercises.
* AI cannot modify sessions.
* All AI-generated cycles must be imported and activated manually.

---

## AI Import Flow

1. User generates JSON externally.
2. Paste into app.
3. App validates:

   * Exercises exist
   * Muscle enum valid
   * No structural violations
4. Preview screen
5. Activate

---

# 11. Clone Cycle Behavior

When cloning:

Preserve:

* Exercise selections
* Default set counts
* Slot ordering

Reset:

* currentDayIndex → 0
* rotationIndices → 0

---

# 12. Export Contract

On session completion:

Export to:

```
iCloud Drive/OpenLift/exports/workout-YYYYMMDD-HHMMSS.json
```

Structure:

```json
{
  "session_id": "...",
  "cycle_name": "...",
  "cycle_day_index": 1,
  "date": "...",
  "exercises": [
    {
      "exercise_name": "...",
      "muscle": "...",
      "sets": [
        {"set_index": 1, "weight": 225, "reps": 8}
      ]
    }
  ]
}
```

CSV export optional (v2).

---

# 13. Manual Cycle Builder Requirements

Must support:

* Add day
* Delete day
* Duplicate day
* Add muscle slot
* Select exercise
* Set default sets
* Reorder slots
* Show per-muscle weekly estimate
* Clone cycle
* Activate cycle

No AI dependency required.

---

# 14. Non-Goals

* No automatic fatigue detection.
* No MRV/MAV enforcement.
* No dynamic auto-programming mid-meso.
* No deload modes.
* No weekly calendar scheduling.
* No required cloud backend.

---

# 15. Future Extensions (Out of Scope v1)

* Charts
* PR tracking UI
* Volume trend graphs
* Apple Health integration
* Cloud sync
* Multi-device support
* RIR tracking

---

# Final System Definition

This product is:

> A deterministic, rotation-aware hypertrophy execution engine with structured mesocycle design, local-first logging, optional AI-generated cycle templates, and lightweight contextual volume awareness.
