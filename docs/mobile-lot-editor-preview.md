# Mobile Parking Lot editor

Build 142 prepares the native iPhone/iPad editor for release, following Richard’s successful iPad editing and reconnect checks in private 140. Mac hosts the document. Windows 141 can take a read-only view with the same exclusive display ownership. Automated tests use isolated data.

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

## Release scope and acceptance

Editing is enabled by default; `CONVERSE_EDITABLE_LOTS=0` supports legacy interop fixtures. iPhone/iPad edit Mac-hosted lots; Windows 141 displays them read-only. Mac remote-client editing and Windows lot hosting/editing remain future work.

The mobile controls remove per-row circles, use row or selection ellipsis menus, and support two-finger text sizing. Lot cars, the blue shoe and agent markers match the Mac. A clean lot resumes conditionally after reconnect; unconfirmed edits require explicit recovery and never replay automatically.

Physical iPhone acceptance is required for this release: editing, multi-selection, menus, pinch, rotation, background/foreground, network loss, and taking between Mac/iPad/iPhone. Simulator passes do not substitute for those checks. Pending edits are memory-only: a terminated mobile process cannot recover changes that never reached home. Wait for Saved on home before quitting, or copy unconfirmed text while the process is running.

## Mobile entry controls

New item… and New Heading… remain visible in the outline. Return creates an item, Command-Return adds a line, and entry menus provide insertion and Move to heading. A trackpad drag crossing an entry boundary selects a row range; within-entry dragging remains native text selection. Direct-touch selection remains available through Select. Outdent is disabled at the outermost item level.

Atomic batch edits use edit protocol v2. Update the Mac home and mobile editor together; a v1 editor/home cannot take an editable lot from v2. Read-only Windows viewing keeps its existing read capability. A batch validates each ordinary operation, commits once, and permits one-step Undo; it cannot wrap an arbitrary row replacement.
