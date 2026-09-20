# Program revision files

**Cycle → Program Updates → Import or Export Program Revision** adds a revision to the running clustered engine without an app rebuild. Import and preview do not write the store. **Back Up and Apply Revision** is the only activation action. Installation and startup do not apply revisions.

## Authoring

Use **Export Revision Starter** to save JSON containing the active program's effective selections, exact catalog UUIDs, template fallback counts, progression identities, and current raw cluster counters. This includes persistent exercise substitutions. Discuss the change, edit this file, and import it for review. A starter unchanged except its next version/name is a behavior-preserving revision. Export again if a cluster completes before activation; stale counter expectations are rejected.

The preview lists the next selection of each cluster, rotation-length changes, set-default and progression changes, and every step of the proposed rotation with existing setup notes. Template fallback counts do not override qualifying completed-effort counts. Apply is blocked by any Fixed or Adaptive draft, including an empty draft; the draft is never discarded.

The file contract is `formatVersion: 1`:

- `sourceProgramVersionID`: exact currently active version.
- `definition`: the Codable `ClusterProgramDefinition`. Target versions are monotonically increasing integers 9–999999 under `openlift.clustered-hypertrophy.vN`; `identityKey` is `openlift_clustered_hypertrophy_vN`.
- `counters`: exactly one entry per `cluster-1`, `cluster-2`, and `cluster-3`, with `expectedPosition` and `resumePosition` both equal to the current raw counter.
- `carry`: one `{targetDay, targetSlot, sourceDay, sourceSlot}` entry for each retained progression identity. Addresses are structural template positions and zero-based slot positions, not display order. The target's exact UUID and complete progression rule must equal that source slot's effective UUID and retained rule.

Exercise reference labels include their current display names for authoring; UUIDs remain authoritative. The source starter is the canonical example for the live store: do not invent catalog UUIDs or infer a progression key from a movement name. Reordering a step requires updating its carry addresses, not transplanting the old destination's key. A genuinely new progression identity omits its carry mapping and uses a unique key prefixed with the target `programVersionID` plus `.`. The preview explicitly identifies this reset. Existing literal keys can be shared across different UUIDs only through valid carry mappings; history remains UUID/profile isolated.

## Supported bounds

Revision files require v8 or a later imported program as their source. Version 1 supports the existing three independent clusters, 1–100 steps per cluster, 1–12 exercises per step, and 1–20 fallback sets. Each exercise reference is exactly one existing active catalog UUID; setup text remains in the exercise catalog, including intentionally empty notes. Progression rules support literal keys, UUID-derived movement keys, and UUID-scoped aliases already understood by the engine. Carry mappings retain the complete source rule, not just its current resolved key, so later manual substitutions preserve movement-following history. Repeated movements in one cluster's different steps are allowed, but exercises cannot collide within a step or across independently reachable clusters.

Counter resets/phase offsets, name-based references, new catalog entries, imported setup-note edits, changes to a carried identity rule, new cluster types, and new training mechanics are rejected. Rotation lengths and order may change while raw counters continue; the preview shows the resulting next step. New mechanics require code. The legacy Published Cycles importer remains separate and is not the clustered revision path.

## Persistence and recovery

Each imported template stores its immutable definition in a namespaced empty rotation-pool metadata marker beside its version identity marker. This uses the existing schema; no global registry or startup writes are needed. Runtime selections carry the decoded definition explicitly. Duplicate or malformed definition markers fail closed.

Activation revalidates the package and source fingerprint, refuses pending context edits and drafts, creates a unique retained `VACUUM INTO` snapshot, checks integrity, then inserts the new template and pointers and switches the active cycle in one save. No asynchronous suspension occurs between backup and activation. Save failure rolls back the visible cycle and durable store. Reapplying the identical active definition is a no-op. Old templates, pointers, completed sessions, occurrences, profiles, and overrides remain intact.

Completed and draft exports include the exact definition and referenced exercise catalog evidence for recovery. Existing catalog entries/notes are never overwritten. Consequently, export-only recovery into an already-seeded catalog does not replace custom or cleared notes for an existing UUID; exact note restoration requires the full-store backup. Notes are restored from export evidence when an exercise UUID is missing. Recovery preserves exact UUIDs even if seed entries have the same name; ambiguous name-only fallback is not guessed. Export recovery still requires contiguous cluster occurrence evidence, so a single late workout export is not a substitute for the full backup/history archive.

## Verification

`ProgramImportTests` covers parsing/read-only preview, draft/stale-transition rejection, backup/save failure, repeat activation, persistent reopen, actual imported completion, export/recovery with repeated hydration, and rotation wrap. Its opt-in copied-store test consumes `Documents/OpenLiftCopiedProgramImportStore/default.store`, verifies the draft block without application-field changes, then retires that draft only in a disposable fixture to test activation and history preservation. `ProgramImportUITests` uses the actual system file picker, preview/apply button, cold launch, and workout completion in an isolated persistent UI fixture.
