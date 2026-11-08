# Mac 149 concurrent Parking Lot edits

A reported incident saved a session transaction, then at the next revision lost
that transaction's updates and added heading/items while retaining preceding
human edits. The original intermediate snapshots and keystroke history are not
available. A save receipt is present in the conversation. The incident remains
unresolved; this investigation does not establish that the user invoked Undo.

## Isolated native reproduction

Based on release/149 `1dc455d`, without production data or network connections:

```sh
CONVERSE_DATA_DIR="$(mktemp -d /tmp/converse-lot-concurrent-run.XXXXXX)" \
CONVERSE_TEST_COMMAND=/usr/bin/false \
.build/Converse.app/Contents/MacOS/Converse --lot-concurrent-self-test
```

The probe edits item A through the native text view, applies a session transaction
updating B and adding a heading plus child, then types into A again. It tests both
an intentionally stale pane (no intervening render) and a refreshed pane. It also
characterizes shared Undo separately and reloads the saved fixture from disk.

Build and probe exited 0; 10 checks passed:

- Stale-pane typing rejects the stale revision, preserves all session changes,
  reports a conflict, and refreshes the pane. A subsequent keystroke succeeds.
- Refreshed-pane typing preserves both authors' changes.
- Saved documents match the in-memory result after reopening.
- Shared Undo immediately after a session transaction removes that entire newest
  transaction at the next revision and preserves earlier human work. This
  reproduces the reported *shape*, not the proven cause, of the incident.

`ParkingLotEditor.Coordinator.save` passes the displayed revision to
`ParkingLotStore.replaceUserRows`, which rejects stale revisions. The library
caches one store per lot. `persist` registers session transactions in the same
UndoManager as human edits; the existing native suite explicitly expects Undo
to reverse another writer's newest change before earlier typing.

The isolated result rules out the simplest stale-native-pane overwrite in this
interleaving. It does not cover every UI event, multiple processes, or establish
the historical cause. The initial release hold was lifted by Richard on November 7
(see the decision below); the incident itself remains open. Do not treat the
characterization checks as acceptance criteria for the future Undo behavior.

Local evidence: `.build/lot-concurrent/build.log`, `tests.log`, `result.json`.

## Owner decision, November 7

Richard does not remember invoking Undo during the incident. That neither proves
nor excludes Undo as its cause. He chose native Undo that affects only his own
edits, preserving session/agent changes. Overlapping changes must produce a
conflict rather than restore an old whole-document snapshot. Simply omitting
external transactions from registration is insufficient: the existing earlier
user Undo entries still require the entire document to match their old snapshot.

Richard explicitly lifted the blanket release hold and requested moving forward
with a tested new release while this investigation continues afterward. Round
150 may proceed with reviewed, passing changes. This is a deferred open issue,
not a claim that the data-loss report or Undo behavior has been fixed.

Follow-up acceptance must cover user Undo/Redo across unrelated external changes,
same-row conflicts, external additions/deletions and structure changes, plus
substitution Backspace and a file-link drop. In particular, test an external save
while a native Undo group is open: no session transaction may become part of the
user's substitution Undo. Retain the stale-pane rejection and persisted-file
checks from this probe. Windows Parking Lots remain read-only.


## Independent follow-up review, November 7, round 152

Claude's per-author Undo commit `e73f404` was integrated as `ef5d774`.
Converse Development reviewed the inverse-by-row implementation and independently
ran the existing focused native `--lot-undo-self-test` from that clean branch's
built app, copied into an isolated QA bundle and profile: exit 0, 55 PASS lines.
This is independent execution of the supplied regression tests, not independent
build provenance or a physical-device acceptance test.

The regression checks preserve stale-pane rejection and persisted-file equality,
then verify human-only Undo/Redo across external edits, same-row conflicts,
external additions/deletions/moves, substitutions and file-link drops, including
an external transaction inside an open native Undo group. External saves no
longer register Undo; each human inverse applies to the current document by ID.
Conflicts use a nonblocking notice. This addresses the reproduced shared-Undo
rollback path; it does not establish the cause of Richard's historical loss.

Remaining qualifications: iPad's separate whole-document history remains unchanged
and is cleared on proposal/lease changes; Mac history clears on device lease
handoff; same-row conflicts are deliberately conservative; groups can partially
undo their nonconflicting entries. Those are not claims of full cross-device
per-author history.

A separate confirmed gap remains in the native stale-save rejection path:
`Coordinator.save` stores its revision mismatch in `lot.error`, and `preview`
refuses agent transactions while that field is nonempty. The follow-up branch
`codex/lot-stale-notice-152` uses a typed stale-user-edit error routed to `notice`;
actual persistence/authority failures keep the blocking error behavior. Added
checks attempt a current-revision agent transaction immediately after rejection,
verify notice clearing on successful typing, and retain real-save-failure blocking.
Build and focused native Undo gates passed (59 PASS lines, exit 0), including the new stale-rejection and real-save-failure checks. Two full-suite attempts stopped at the existing real Bonjour TXT discovery test with Network.NWError -65563 ServiceNotRunning. No full-suite pass is claimed for this branch; independent review and combined release gates remain required.
