# Store Compatibility And Migration Safety

## Schema Contract

Production opens `OpenLiftSchemaV16` through `OpenLiftSchemaMigrationPlan` in
[`OpenLiftSchema.swift`](../Sources/OpenLiftSchema.swift). Shipped schema
checksums and entity identities are compatibility contracts: preserve frozen
model declarations and add a migration stage for new storage requirements.

- The versioned V1 declaration recognizes the original unversioned store.
- Adaptive state uses parallel records, not fake cycle IDs or sentinel day
  indices in Rotation sessions. Missing mode preferences resolve to Fixed Cycle.
- Cluster rotation state, immutable occurrences, and exact-slot substitutions
  use parallel entities. Schema migration creates no inferred occurrences,
  progression keys, substitutions, or program activation.
- Resistance-profile upgrades leave absent settings unknown. Percent and pound
  amounts are distinct units; opening a store never converts or backfills them.
- V16 preserves shipped V1–V15 set shapes in `LegacyNumericLoadModels`, maps the
  numeric `weight` attribute to `numericWeight` without conversion, and adds
  nullable `gripperModel`. Opening an older store does not reinterpret numeric
  gripper values. See [load encoding](data-and-history.md#coc-gripper-model-storage-v16).

Schema versions, program versions, and export payload versions are separate.
Program definitions use existing template metadata rather than requiring a new
schema for each revision. Completed occurrences retain their frozen evidence.

## Startup Failure

The app attempts to open the persistent store once. On migration/open failure,
it does not move, rename, delete, recreate, or retry against that URL. It renders
a blocking error view from an isolated in-memory container with the preserved
store path and backup guidance. Normal tabs and export retries remain unavailable.

Schema opening and explicit content changes are separate. Any retained startup
repair must match its exact allowlisted evidence, preflight conflicts before
writing, and be idempotent; it must never generalize into guessed history repair.

## Program Changes

The [program bridge](program-updates.md) validates supported revisions, refuses
pending edits and Fixed/Adaptive drafts, creates an integrity-checked retained
`VACUUM INTO` snapshot, and atomically saves activation with its receipt marker.
No asynchronous suspension occurs between backup and activation. Backup or save
failure must leave the program, visible draft, history, and counters unchanged.
Installation alone does not activate a revision. The bridge is not a full-store
restore interface.

## Verification

Choose the gate for the changed behavior; a passing synthetic fixture does not
prove compatibility with a personal store.

- `MigrationSafetyTests` covers unversioned-store recognition, stages through
  V16, entity/state readback, rollback readability, and deliberate migration
  rejection with preserved file hashes. Its synthetic fixture contains both
  completed and draft work and uses no personal data.
- For schema/startup changes, use a verified store backup with the copied-store
  gate below. Preserve the original and compare every affected logical field,
  including sessions, sets, profiles, occurrences, overrides, and raw counters.
  Ignore only SQLite/SwiftData bookkeeping, not application state.
- `ProgramImportTests` covers preview, drafts/pending edits, stale approvals,
  backup/save failure, atomic receipts, replay, cold reopen, completion, and
  export recovery. Its copied-phone test exercises activation only in a
  disposable draft-free copy and verifies the untouched source backup.
- `ProgramImportUITests` covers navigation; `scripts/test-program-agent.py`
  exercises private-file delivery and replay in a disposable simulator.

### Copied-Store Gate

Use an explicitly chosen disposable simulator, not a personal simulator or the
ordinary test runner's reusable simulators. Supply a directory containing
`default.store` and any sidecars, or a `.tgz`, `.tar.gz`, or `.tar` backup archive:

```bash
OPENLIFT_SIMULATOR_UDID=DISPOSABLE_SIMULATOR_UUID \
  scripts/test-real-store-migration.sh /private/path/to/backup
```

The helper stages a separate working copy, runs
`MigrationSafetyTests/testCopiedRealDeviceStoreMigratesToCurrentSchemaWhenOptedIn`,
and verifies that the supplied source remains unchanged. Keep backups and
container captures outside source control. See [test lanes](setup.md#fast-everyday-checkpoints)
for normal service/UI checkpoints.
