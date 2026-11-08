# Galleries, portrait direction and partial inputs

View → Galleries opens a picker with per-agent assessment and portrait columns and select-all checkboxes. System Monitor is an assessment-only row. Show Gallery closes the picker and opens an independent window. Repeating the command creates another gallery; closing its red button ends that gallery's demand. The older Assessments and Portraits menu commands open galleries containing all visible agents of that type.

Cards reflow as the window changes width. Drag a card by its handle (or use the handle's Move earlier/later menu) to reorder it. The corner expansion button fills the window with that card; the grid button or Escape returns. A subtle circular arrow refreshes the selected content. Revision/hash labels are omitted from gallery cards. Assessments show Current for a successful, non-seeded check less than five minutes old, then compact elapsed time; facts retain their individual observation times and missing-data notes.

Portrait demand is tracked per window and selected agent. Overlapping windows coalesce through the existing portrait service; hiding, minimizing or closing one removes its demand without disrupting other windows. Already-running generation may finish. An explicit Refresh is a one-shot user request: it keeps its force when joining queued work and may finish after the window closes. Explicit rate-limited requests do not create background retry timers; only visible-window demand schedules automatic retries. Waiting window-only jobs stop when their last viewer disappears. Ordinary agent turns do not generate portraits without demand.

Cached visibility requests inspect only metadata, without reading or decoding PNGs. Missing-input rows precede model facts in cards and remote widgets. Revoked lot counts and input-failure names are filtered out of cards, widgets and portrait prompts immediately.

The version-2 portrait template removes the forced character/headshot composition and common teal/amber palette. It carries up to 4,000 characters of objective context and the owner art direction, preserves both stored text fields, and follows the chosen scene/subject/medium. Objective and assessment-problem changes also invalidate the cache. Unknown components get localized question marks; real facts stay in the assessment. The image API receives text, not pixels of referenced files, and the prompt says so explicitly.

A Discord read failure, unreadable permitted Parking Lot, or failed Home Assistant input is recorded as an Unavailable row while the remaining assessment proceeds. Cancellation and access-change checks remain enforced. Invalid overall model action formats and unavailable model credentials still fail: they cannot produce trustworthy output. An art-direction-only save preserves current runtime state and unrelated connector configuration; concurrent settings changes require a reload.

System Monitor samples the computer executing Converse every five seconds on a utility queue. It makes no model calls, subprocess launches or remote requests. CPU is a delta of host CPU ticks across all cores (the first sample is unknown), load averages are 1/5/15-minute runnable demand, VM counters use the actual page size, and swap comes from vm.swapusage. Resident-plus-compressed includes anonymous resident, wired and compressed storage pages; it is deliberately not labeled Activity Monitor's Memory Used. File-backed pages are reported separately, never treated as free. Pressure comes from the kernel pressure level, not a RAM-use heuristic; unavailable keys show Unavailable.

API evidence: the installed macOS SDK's mach/host_info.h, mach/vm_statistics.h and dispatch/source.h, and Apple's XNU pressure documentation and implementation:
- https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c

Scope: native Mac gallery UI. This does not add gallery windows to Windows/iOS or alter the frozen 152 release. Real portrait aesthetics and connector image delivery still require live acceptance; fixtures only verify mechanics and prompt construction.

## Validation, November 8

- Mac arm64 build with the Codex TEST identity passed using settled sources and `.build/GalleryPreview.app`.
- Focused `--gallery-self-test`: 117 PASS, exit 0. Covers prompt and owner-text preservation, partial inputs, freshness, queued explicit Refresh, close while queued, deferred cancellation, cache visibility without image loads, missing-input priority and revocation, portrait-only saves, native hosting at widths 1100/390/620, and live host sampling.
- The native harness activates its own accessory application and drains AppKit events so visibility and occlusion match an interactive application. Real window hide/minimize/restore/close checks pass; closing the last gallery stops portrait demand and host sampling.
- Full `test.sh`: exit 0, 3,723 native PASS checks plus all Python checks. The gate now includes `--gallery-self-test` in a separate disposable profile. The earlier 3,595-check gate did not include that separate hosting/monitor command.
- Native AppKit captures were inspected for the three-column gallery and checkbox picker, plus offscreen cards at 390px. Host sampling checks require a new sample with populated VM/swap fields rather than the default physical-memory value.
- All checks use fresh temporary data directories. No production installation or publication.
- Still needs real-user acceptance: pointer drag/reorder, expand/return, and live portrait appearance. Screening Room PNG delivery is a separate pending request, not a passing result of these tests.
