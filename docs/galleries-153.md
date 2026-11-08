# Galleries, portrait direction and partial inputs

View → Galleries opens a picker with per-agent assessment and portrait columns and select-all checkboxes. System Monitor is an assessment-only row. Show Gallery closes the picker and opens an independent window. Repeating the command creates another gallery; closing its red button ends that gallery's demand. The older Assessments and Portraits menu commands open galleries containing all visible agents of that type.

Cards reflow as the window changes width. Drag a card by its handle (or use the handle's Move earlier/later menu) to reorder it. The corner expansion button fills the window with that card; the grid button or Escape returns. A subtle circular arrow refreshes the selected content. Revision/hash labels are omitted from gallery cards. Assessments show Current for a check less than five minutes old, then compact elapsed time; facts retain their individual observation times and missing-data notes.

Portrait demand is tracked per window and selected agent. Overlapping windows coalesce through the existing portrait service; hiding, minimizing or closing one removes its demand without disrupting other windows. Already-running generation may finish. Waiting window-only jobs stop when their last viewer disappears. Ordinary agent turns do not generate portraits without demand.

The version-2 portrait template removes the forced character/headshot composition and common teal/amber palette. It carries up to 4,000 characters of objective context and the owner art direction, preserves both stored text fields, and follows the chosen scene/subject/medium. Objective and assessment-problem changes also invalidate the cache. Unknown components get localized question marks; real facts stay in the assessment. The image API receives text, not pixels of referenced files, and the prompt says so explicitly.

A Discord read failure, unreadable permitted Parking Lot, or failed Home Assistant input is recorded as an Unavailable row while the remaining assessment proceeds. Cancellation and access-change checks remain enforced. Invalid overall model action formats and unavailable model credentials still fail: they cannot produce trustworthy output. An art-direction-only save preserves current runtime state and unrelated connector configuration; concurrent settings changes require a reload.

System Monitor samples the computer executing Converse every five seconds on a utility queue. It makes no model calls, subprocess launches or remote requests. CPU is a delta of host CPU ticks across all cores (the first sample is unknown), load averages are 1/5/15-minute runnable demand, VM counters use the actual page size, and swap comes from vm.swapusage. Resident-plus-compressed includes anonymous resident, wired and compressed storage pages; it is deliberately not labeled Activity Monitor's Memory Used. File-backed pages are reported separately, never treated as free. Pressure comes from the kernel pressure level, not a RAM-use heuristic; unavailable keys show Unavailable.

API evidence: the installed macOS SDK's mach/host_info.h, mach/vm_statistics.h and dispatch/source.h, and Apple's XNU pressure documentation and implementation:
- https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c

Scope: native Mac gallery UI. This does not add gallery windows to Windows/iOS or alter the frozen 152 release. Real portrait aesthetics and connector image delivery still require live acceptance; fixtures only verify mechanics and prompt construction.

## Validation, November 8

- Clean Mac arm64 build with the Codex TEST identity passed. The first compilation was superseded; a later attempt correctly failed because a source changed during compilation. The reported passing build used settled sources.
- Focused `--gallery-self-test`: 102 PASS, exit 0. Covers owner text preservation and prompt context, partial Discord input, freshness boundaries, portrait cache/demand overlap, portrait-only saves and concurrent edits, native hosting at widths 1100/390/620, and host memory/swap reads.
- Full `test.sh` using that preview bundle: exit 0, 3,595 PASS lines, including the Python checks.
- Native AppKit captures inspected for the three-column gallery and checkbox picker; offscreen cards inspected at 390px width. The offscreen capture has a transparent background, so the picker was also checked through an actual window capture. The metrics card in the fixture render precedes sampling; a separate sampler check verifies its readings.
- Production remains unchanged. `scripts/build-test-app.sh Codex` refused to replace the already-running TEST application; built `.build/GalleryPreview.app` with the same TEST identity instead. Do not launch it against the existing TEST profile while that app is running. All checks used fresh temporary data directories.
- Still needs real-user acceptance: pointer drag/reorder, expand/return, multi-window visibility behavior, and live portrait appearance. Screening Room PNG delivery is a separate pending request, not a passing result of these tests.
