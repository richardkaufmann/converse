# Typing latency investigation, 2026-11-05

The reported failure is delayed typing in one pane while other sessions or agents are active. These findings narrow the sources of main-thread work; they do not establish that every stall is fixed.

## Evidence and changes

1. A five-second read-only sample of Richard's running **135** Mac process included `Store.saveSoon` → `saveChecked` → archive encoding on the main thread, and sidebar publication rebuilding Parking Lot link metadata. This is a sample of 135, not verification of 136. Build 136 already moves ordinary archive encoding/writes to `ArchiveWriter`; checked saves still wait for durable completion.
2. In source 136, `publishSidebarIfChanged` compared encoded snapshots including `homeSeq`. Sending a snapshot increments that sequence, so the next 250 ms poll sees a change caused by its own previous send. Idle peers therefore cause repeated publications, durable sequence writes, and receiver sidebar-cache writes.
3. `codex/input-latency` excludes the transport sequence from content comparison, uses `Equatable` rather than encoding JSON to compare, and shares one row snapshot across peers. It computes available lot-link IDs once per snapshot without building or sorting display labels for each lot. Forced snapshots on connection remain.
4. Routine `ConfigurationAudit.agentChanged` also encodes old/new agent configurations to calculate field differences and takes the audit I/O lock. A separate patch on `codex/audit-latency` is being validated to queue ordinary change diagnostics off main while retaining synchronous recovery and archive-save barriers.

## Validation

The sidebar regression runs through the encrypted fake-peer service harness. On the original 136 implementation, its assertion that 24 unchanged polls send no snapshots and advance no sequence fails. With the patch, it passes: **zero snapshots, unchanged sequence, 3.564 ms total** in the recorded run. This is a synthetic timing observation, not a user-visible latency percentile.

The fixed branch passes `./build.sh` and the full `./test.sh` (2,435 PASS lines). Existing checks cover real metadata changes, remote markers, current-Group link filtering, and reconnect behavior. The release driver must run the combined cross-platform gate because `DeviceTransport.swift` is shared with iOS.

Local evidence: `/tmp/codex-converse-main-2224.sample.txt`, `/tmp/codex-input-latency-baseline-tests.log`, `/tmp/codex-input-latency-tests.log`. These contain local diagnostic evidence and are not committed.

## Boundaries and next measurement

- Do not turn checked persistence into fire-and-forget work: delivery receipts, run budgets, and durable-before-execute ordering depend on its result. An asynchronous replacement needs an explicit continuation and failure/rollback design.
- Audit `enqueueSwitchboard`: its durable-before-provider-start comment now sits above ordinary asynchronous `save()`. It is a separate correctness question for the owner of the archive/switchboard change, not addressed by this sidebar patch.
- After integrating 136/137 and these changes, repeat sampling during actual typing plus agent/switchboard traffic. Compare a large-transcript fixture with an idle fixture; measure input-to-display and main-run-loop delays, rather than inferring responsiveness from total CPU or memory use. Retain drafts, selection and scroll positions throughout.
- Remote lot snapshots still follow their existing read-only protocol. Their planned exclusive editor protocol should publish structured content on change instead of periodically retransmitting unchanged documents; that work remains separate.
