# OpenLift

OpenLift is a local-first hypertrophy workout tracker for rotating training cycles, workout logging, and export-backed history recovery.

License: [MIT](LICENSE)

## Current App

The shipped tabs are **Log, Workout, and History**. OpenLift handles reliable
workout entry and complete exports; an LLM can analyze those exports and manage
supported program revisions through the [paired-host bridge](docs/program-updates.md).
There is no Cycle tab or program-update menu.

The bridge requires a paired Mac, development-container access, and a launchable
phone; TestFlight-only delivery is not supported. It previews exact revisions,
blocks changes while a draft or pending edits exist, and backs up before an
explicitly approved activation. Installing the app does not change the program.

The [older interface mockups](docs/images/) are historical design illustrations,
not screenshots of the current navigation or input behavior.

This repository is set up for two audiences:

- humans who want to build, run, and evolve the app
- coding agents such as Codex or Claude Code that need a reliable map of the project and the Apple-specific workflow

## Start Here

If you are new to the repo, read these in order:

1. [`docs/setup.md`](docs/setup.md)
2. [`docs/architecture.md`](docs/architecture.md)
3. [`docs/templates.md`](docs/templates.md)
4. [`docs/data-and-history.md`](docs/data-and-history.md)
5. [`docs/migration-safety.md`](docs/migration-safety.md)
6. [`docs/program-updates.md`](docs/program-updates.md)
7. [`docs/ai-workflows.md`](docs/ai-workflows.md)

## Repo Overview

- [`Sources`](Sources): SwiftUI app code, SwiftData models, export/bootstrap logic
- [`Tests`](Tests): unit and regression tests
- [`Resources`](Resources): reference notes used for exercise modeling
- [`Config`](Config): tracked shared build config plus local-only override template
- [`prd.md`](prd.md): product requirements baseline

## Local Config Model

Tracked defaults in [`Config/Shared.xcconfig`](Config/Shared.xcconfig) contain
public app identifiers only. They are not signing credentials. Personal Apple
team settings, a private direct-export endpoint, and any bearer token belong in
`Config/Local.xcconfig`.

That file is ignored by git. Start from:

- [`Config/Local.example.xcconfig`](Config/Local.example.xcconfig)

## Quick Rules

- Never commit `Config/Local.xcconfig`.
- Never commit signing keys, provisioning profiles, personal workout exports,
  SwiftData stores, app-container captures, or build archives.
- Use the [program bridge](docs/program-updates.md) for supported clustered revisions;
  legacy published-cycle JSON is a different format, not a bridge input.
- Select checks proportionate to the change; see [test lanes](docs/setup.md#fast-everyday-checkpoints).

## Current Behavior

- Fresh installs seed an exercise catalog and use a published legacy template or
  the built-in `4D Upper/Lower` fallback when no stored template exists. They do
  not automatically activate the versioned clustered program.
- Stored Fixed Cycle and Adaptive Floating modes remain supported. Mode/profile
  administration is not exposed in the shipped tabs or the program bridge.
- The bundled v8 clustered program has independent 4/8/6-step torso/arm, leg,
  and accessory rotations. All current clusters stay visible in one workout,
  with physical setup notes beside each exercise and free-order logging.
- Fixed Cycle requires a dated readiness observation before set edits or
  completion; readiness is advisory and does not change the program or dose.
- Movement substitutions can apply to this workout or one exact future rotation
  slot, without rewriting the reserved template or completed history.
- Completing a cluster freezes movement/progression/resistance evidence and
  advances only that cluster. Finish saves locally before asynchronous export;
  failed delivery is retryable without repeating progression.
- New Fixed/clustered sets keep the qualifying prior weight and literal row
  count, but require new reps. Tap a numeric field and type to replace its value;
  **Complete Set** above the keyboard commits and completes in one tap.
- Cable entries preserve resistance source and VOLTRA settings, including
  distinct percent/pound units. Missing historical settings remain unknown.
- Completed workouts export to `OpenLift/exports`; draft snapshots go to
  `OpenLift/exports/drafts`. History includes exercise-name search.
- Daily full-store backups and export-backed history recovery exist. A dedicated
  agent-managed recovery preview/restore command is not yet implemented; the
  program bridge does not restore backups. See [recovery scope](docs/data-and-history.md#recovery-scope).

## For LLM Agents

If you are using Codex or Claude Code, treat this README as the index and then load only the specific document you need:

- setup and Apple account / Xcode issues: [`docs/setup.md`](docs/setup.md)
- architecture and code-path map: [`docs/architecture.md`](docs/architecture.md)
- previewing and applying clustered revisions: [`docs/program-updates.md`](docs/program-updates.md)
- template formats and historical program revisions: [`docs/templates.md`](docs/templates.md)
- history, exports, and real user data: [`docs/data-and-history.md`](docs/data-and-history.md)
- schemas, backups, rollout, and real-store gates: [`docs/migration-safety.md`](docs/migration-safety.md)
- CLI-driven development with Xcode, simulators, devices, and AI agents: [`docs/ai-workflows.md`](docs/ai-workflows.md)
