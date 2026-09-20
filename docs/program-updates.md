# Agent-managed program revisions

OpenLift exposes Log, Workout and History. Cycle and Program Updates are not user-facing destinations. The paired-host bridge handles clustered revision authoring, preview and explicitly approved activation without rebuilding the app. There is no network listener, public file importer, background inbox scan or automatic queued activation.

## Paired-host operation

This first transport requires a development installation with Apple's paired CoreDevice app-container access and a launchable/unlocked phone. TestFlight-only remote management is not supported. A custom `openlift-agent://request/<lowercase UUID>` URL wakes the running app without terminating it; the URL has no program payload or authority. The matching command must already exist under private `Library/Application Support/OpenLiftAgentBridge/inbox/`. Arbitrary links without a privately staged command do nothing. Do not place command files in Documents/iCloud/Files.

Run from a trusted paired Mac with an explicit device and private local archive outside the repository:

```sh
python3 scripts/program-agent.py --device DEVICE --state-dir PRIVATE_DIR starter --output PRIVATE_DIR/revision.json
python3 scripts/program-agent.py --device DEVICE --state-dir PRIVATE_DIR preview PRIVATE_DIR/revision.json
python3 scripts/program-agent.py --device DEVICE --state-dir PRIVATE_DIR apply --approved-preview PRIVATE_DIR/PREVIEW_UUID.receipt.json
python3 scripts/program-agent.py --device DEVICE --state-dir PRIVATE_DIR status
```

Discuss the returned full proposed revision, setup references, changes and upcoming selections with the user before applying. `apply --approved-preview` is the explicit instruction for that exact preview, not a second in-app approval. Preview tokens expire after at most 15 minutes and bind the exact revision bytes and observed source state. A changed source requires a new preview and review of the differences; the bridge never refreshes approval implicitly. Commands expire and rejected requests remain terminal, including after a workout draft is finished. No draft is discarded or silently retired. Workout currently creates a draft on launch unless a workout was already completed that day, so the usual activation window is after finishing a workout and before the next day's draft.

The CLI retains each exact request and receipt. Exit 0 means a terminal `ok`, `previewed` or `applied` receipt; exit 2 means a terminal app rejection/expiry. Exit 3 is a transport/client problem or **unknown outcome**, not proof activation failed. After a lost response, use the same archive and request UUID:

```sh
python3 scripts/program-agent.py --device DEVICE --state-dir PRIVATE_DIR retry REQUEST_UUID
```

Never replace that retry with another apply. UUIDs are bound to command hashes; reusing one with different bytes is rejected. The app first records a terminal interruption intent. Successful activation writes its receipt marker in the same SwiftData transaction as the new program; replay reconstructs the response even if the app died after commit but before writing the receipt file. Before workout bootstrap, a matching atomic receipt also restores the already-active template’s selection cache if process death left UserDefaults stale; this does not activate a program or change the store. Rejected/expired/interrupted commands never execute later on normal launch. Retained full-store revision backups are outside daily pruning. Receipt files and revision archives can contain private workout/program details and must stay out of source control.

This bridge does not expose manual template editing, training-mode/Adaptive profile changes, legacy migration controls, arbitrary database writes or recovery restore. Those are separate capabilities, not implied by removing Cycle.

## Authoring

Use the bridge `starter` command to save JSON containing the active program's effective selections, exact catalog UUIDs, template fallback counts, progression identities, and current raw cluster counters. This includes persistent exercise substitutions. Discuss the change, edit this file, and submit it for preview. A starter unchanged except its next version/name is a behavior-preserving revision. Export again if a cluster completes before activation; stale counter expectations are rejected.

The preview lists the next selection of each cluster, rotation-length changes, set-default and progression changes, and every step of the proposed rotation with existing setup notes. Template fallback counts do not override qualifying completed-effort counts. Apply is blocked by any Fixed or Adaptive draft, including an empty draft; the draft is never discarded.

The file contract is `formatVersion: 1`:

- `sourceProgramVersionID`: exact currently active version.
- `definition`: the Codable `ClusterProgramDefinition`. Target versions are monotonically increasing integers 9–999999 under `openlift.clustered-hypertrophy.vN`; `identityKey` is `openlift_clustered_hypertrophy_vN`.
- `counters`: exactly one entry per `cluster-1`, `cluster-2`, and `cluster-3`, with `expectedPosition` and `resumePosition` both equal to the current raw counter.
- `carry`: one `{targetDay, targetSlot, sourceDay, sourceSlot}` entry for each retained progression identity. Addresses are structural template positions and zero-based slot positions, not display order. The target's exact UUID and complete progression rule must equal that source slot's effective UUID and retained rule.

Exercise reference labels include their current display names for authoring; UUIDs remain authoritative. The source starter is the canonical example for the live store: do not invent catalog UUIDs or infer a progression key from a movement name. Reordering a step requires updating its carry addresses, not transplanting the old destination's key. A genuinely new progression identity omits its carry mapping and uses a unique key prefixed with the target `programVersionID` plus `.`. The preview explicitly identifies this reset. Existing literal keys can be shared across different UUIDs only through valid carry mappings; history remains UUID/profile isolated.

## Supported bounds

Revision files require v8 or a later imported program as their source. Version 1 supports the existing three independent clusters, 1–100 steps per cluster, 1–12 exercises per step, and 1–20 fallback sets. Each exercise reference is exactly one existing active catalog UUID; setup text remains in the exercise catalog, including intentionally empty notes. Progression rules support literal keys, UUID-derived movement keys, and UUID-scoped aliases already understood by the engine. Carry mappings retain the complete source rule, not just its current resolved key, so later manual substitutions preserve movement-following history. Repeated movements in one cluster's different steps are allowed, but exercises cannot collide within a step or across independently reachable clusters.

Counter resets/phase offsets, name-based references, new catalog entries, imported setup-note edits, changes to a carried identity rule, new cluster types, and new training mechanics are rejected. Rotation lengths and order may change while raw counters continue; the preview shows the resulting next step. New mechanics require code. The legacy Published Cycles importer is not exposed by this bridge.

## Persistence and recovery

Each imported template stores its immutable definition in a namespaced empty rotation-pool metadata marker beside its version identity marker. This uses the existing schema; no global registry or startup writes are needed. Runtime selections carry the decoded definition explicitly. Duplicate or malformed definition markers fail closed.

Activation revalidates the package and source fingerprint, refuses pending context edits and drafts, creates a unique retained `VACUUM INTO` snapshot, checks integrity, then inserts the new template and pointers and switches the active cycle in one save. No asynchronous suspension occurs between backup and activation. Save failure rolls back the visible cycle and durable store. Reapplying the identical active definition is a no-op. Old templates, pointers, completed sessions, occurrences, profiles, and overrides remain intact.

Completed and draft exports include the exact definition and referenced exercise catalog evidence for recovery. Existing catalog entries/notes are never overwritten. Consequently, export-only recovery into an already-seeded catalog does not replace custom or cleared notes for an existing UUID; exact note restoration requires the full-store backup. Notes are restored from export evidence when an exercise UUID is missing. Recovery preserves exact UUIDs even if seed entries have the same name; ambiguous name-only fallback is not guessed. Export recovery still requires contiguous cluster occurrence evidence, so a single late workout export is not a substitute for the full backup/history archive.

## Verification

`ProgramImportTests` covers parsing/read-only preview, draft/stale-transition rejection, backup/save failure, repeat activation, persistent reopen, actual imported completion, export/recovery with repeated hydration, and rotation wrap. Its opt-in copied-store test consumes `Documents/OpenLiftCopiedProgramImportStore/default.store`, verifies the draft block without application-field changes, then retires that draft only in a disposable fixture to test activation and history preservation. `ProgramImportUITests` checks the three-tab workout UI and absence of administration entry points. `scripts/test-program-agent.py` exercises actual private-file staging, warm URL activation without a process restart, exact-request replay, cold URL startup, powerless unsolicited URLs and application-field preservation in a named disposable simulator. `testPrepareIsolatedBridgeTransportFixture` supplies a synthetic completed-today store for that gate; the copied-phone test separately proves draft protection and scratch activation against real history.
