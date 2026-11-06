# Mobile Parking Lot editor development preview

This branch adds a native iPhone/iPad editor backed by a Mac home. Richard authorized private build 140 with editing enabled by default for Mac-hosted lots on iPhone/iPad. Windows remains on 139 for this trial. Automated tests still use isolated data.

## Outline behavior

Every heading and item with children can be expanded or collapsed independently. Opening a parent preserves its descendants' collapse choices. Collapse All shows headings; Expand All opens every level. Mac arrows have a wider gutter and click target, plus per-level context-menu actions. Mobile uses touch-sized disclosure buttons and an Outline menu.

## Implemented path

- A structured, versioned document preserves row IDs, hierarchy, tags, notes and ordered image hashes.
- Home persists the document before acknowledging an edit. Only one edit is in flight; queued typing coalesces.
- A competing take drains the current holder before granting a new epoch. Unknown versions and old clients are refused when editing is enabled.
- Connection loss freezes editing. Unconfirmed text remains available for manual copy, including after retake, and is never automatically replayed into a new epoch.
- Agent proposals pause and drain human edits, then show the precise resulting before/after state on the holder. Cancellation, expiry and holder changes invalidate review.
- Native editing includes text, Done, tags, nesting, moving, selection, structural copy/paste, comments, images and take-scoped Undo/Redo.
- Export produces a Mac-importable `.converse` file with hierarchy, tags, comments and optional images. The existing secret/personal-information scrubber is optional and on by default. Missing or corrupt images cause an explicit export error.

## Reproducible checks

Build the Mac fixture with `CONVERSE_APP_OUTPUT="$PWD/.build/MobileLotCheck.app" ./build.sh`, then run `CONVERSE_APP_OUTPUT="$PWD/.build/MobileLotCheck.app" ./test.sh`.

Run `CONVERSE_APP_OUTPUT="$PWD/.build/MobileLotCheck.app" CONVERSE_IPAD_SIMULATOR=<owned-simulator-uuid> ./iPad/test.sh --lot-editing`. This starts an isolated Mac home, pairs two independent mobile identities, edits and uploads an image, takes between holders while saving, then parks and retakes. It also captures native phone-width and tablet-width layouts in light and dark mode.

The isolated `--lot-editing-self-test` Mac command covers the shared operation queue, transport fencing, duplicate receipts, drained holder review and mobile-export compatibility. Approval commits the exact preview document, including generated row/comment IDs. `--lot-disclosure-preview <output-directory>` captures the native Mac outline in light and dark appearances. Both commands require `CONVERSE_TEST_COMMAND` and an isolated `CONVERSE_DATA_DIR`.

## Private trial scope and remaining checks

Build 140 enables mobile editing by default; `CONVERSE_EDITABLE_LOTS=0` is an override for legacy interop fixtures. This trial covers Mac-hosted lots edited from iPhone/iPad. Mac remote-viewer editing and Windows compatibility rollout remain separate work. Richard accepted testing on his devices before completing the remaining acceptance checks. Physical-device acceptance is currently blocked because BigPad is unavailable to Xcode; simulator tests do not replace background/network testing on a real device.

Follow-up work includes Mac remote-client integration and the supported-client upgrade path. During this private trial, exercise holder review and attachment/caret behavior on a real device, and check background/foreground, silent partitions, interrupted uploads and rotation. Pending edits are intentionally memory-only; a terminated mobile process cannot recover edits that never reached home. The editor displays saved versus unconfirmed state and offers manual Copy recovery while running.
