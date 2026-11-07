# Transcript render investigation (Mac 149)

The original diagnostic commit is `b4ac0cc`, based on release/149 `1dc455d`.
The follow-up branch `codex/transcript-prepared-cache` adds a candidate
optimization. The installed app and frozen release worktrees are unchanged.
No personal transcript content is included.

## Observed capture

A 90-second capture from 12:10:46–12:12:16 PST on November 7, 2026 recorded:

- Three slow transcript renders, approximately 1,048, 693 and 664 ms; 367 other
  renders were at most 8 ms.
- Maximum key delivery delay 697 ms and main-queue delay 996 ms.
- All 353 text-insertion measurements at most 4.14 ms.
- Two checked saves of 76 and 70 ms, distinct from the much longer render spans.
- Lot scrolling was sampled; session scrolling was not sampled in this run.

These spans identify rendering as a significant stall, but do not identify its
internal substage or prove that all three stalls were perceptible while typing.
The capture is preserved locally under the packaging worktree's ignored
`.build/release-evidence/stutter-1212/` directory.

## Synthetic experiment

Build normally, then run with fresh isolated data and a non-running provider:

```sh
CONVERSE_DATA_DIR="$(mktemp -d /tmp/converse-render-profile.XXXXXX)" \
CONVERSE_TEST_COMMAND=/usr/bin/false CONVERSE_RENDER_PROFILE=1 \
.build/Converse.app/Contents/MacOS/Converse --transcript-render-profile
```

The command refuses to run without the data-directory and test-command guards.
It creates only synthetic messages and exits before normal app startup. It
measures an initial render and three changes to the final message, at 100, 600
and 1,200 messages. The fixture uses formatted text and example.com links, no
images, and a native text view without a window or enclosing scroll view.

On the first run, final-message updates measured:

| Messages | History preparation | Storage replacement stage | Explicit layout stage |
| --- | --- | --- | --- |
| 100 | 23–25 ms | 2–3 ms | 0.4–0.8 ms |
| 600 | 80–83 ms | about 10 ms | about 0.4 ms |
| 1,200 | 166–291 ms | 23–33 ms | 0.4–0.6 ms |

These are observed ranges from three updates, not percentiles or a performance
threshold. Initial renders also pay full layout and one-time AppKit startup
costs. A separate sampled run includes both initial renders and updates; its
aggregate stack counts must not be presented as update-only attribution.

The renderer retains unchanged native layout, but prepares attributed bodies,
links, timestamps and message metadata across the entire history before
replacing only its changed suffix. This explains a repeatable scaling cost in
the synthetic test. It does not establish which substep caused the real
one-second stall. Full-window scrolling and editing acceptance are still needed.

The candidate below targets that repeated preparation. Further work must
preserve dynamic session labels, disclosure changes, images, copy content,
timestamps, selection and draft-relative caret positions. Compare the same
fixtures before and after; repeat the real multi-pane typing capture.

## Prepared-message cache candidate

The follow-up replaces the Markdown-only cache with immutable prepared message
bodies and their full Copy Message representations. The cache key includes the
complete message (including delays, role and timestamp), font size, collapse
and expansion state, and date environment. Name lookups used to prepare a
summary are recorded and rechecked before reuse, including unresolved names.
Locale preference notifications invalidate prepared timestamps even when the
locale identifier stays the same. Removed messages are pruned from the cache.
Images still use the existing file-metadata-aware attachment preparation path.

The native document and message metadata are still assembled on an update;
this change skips repeated Markdown, delay-marker, link and tooltip formatting
for unchanged messages. It does not eliminate all work proportional to history
size, or make first-time rendering incremental.

Set `CONVERSE_RENDER_PROFILE_LONG=1` on the same benchmark command for a
1,200-message fixture with four times the text per message and 400 delay
markers. This resembles the observed text volume and delay-marker count, but
does not reproduce the user's content, images, window geometry or concurrent
activity. It is an additional workload check, not a substitute for a real
typing and scrolling capture.

Final candidate benchmark results (three final-message updates per size):

| Messages | Baseline total stages | Candidate total stages | Candidate history preparation |
| --- | --- | --- | --- |
| 100 | 27–29 ms | 3.9–4.5 ms | 1.9–2.1 ms |
| 600 | 91–94 ms | 18.6–18.9 ms | 8.6–8.7 ms |
| 1,200 | 190–323 ms | 34.8–36.1 ms | 16.0–16.3 ms |

The larger fixture takes **118–126 ms** per update: preparation 43–48 ms,
replacement stage 73–76 ms, explicit layout about 1 ms. The replacement stage
includes prefix comparison and selection/typing-attribute maintenance, not
only the native storage call. There is no matched baseline run for this larger
fixture, so do not report an improvement ratio for it. Its first render takes
about 2.6 seconds. This leaves significant work at large history sizes and is
not evidence that the user's stutter is completely fixed.

## Validation

The candidate build succeeds. The conversation-layout self-test passes,
including fresh-render comparisons, draft hydration, changed-tail replacement,
hidden activity, selection, copying and following behavior.

The first full Mac gate failed at `A duplicate no-op Inject all command ID
is answered from its receipt, never applied twice` in unchanged
`DeviceSyncTests.swift:522–524`. Its handle was lost after interruption; the
captured FAIL is retained and has not been attributed to the renderer.

A subsequent diagnostic build and complete `./test.sh` run both exited 0.
Temporary logging around that same assertion captured identical JSON bytes
on the two sends, followed by `completed / Already recorded on home.`;
messages were unchanged and the session was not interrupted. The logging
patch is retained locally and removed from the proposed change. This pass
does not explain the earlier failure. Command retry binding is under separate
review; no assertion was relaxed.

Raw local output is in `.build/render-profile/`: `baseline.log`,
`cache-final-baseline.log`, `cache-long.log`, `sampled-run.log`,
`synthetic.sample.txt`, `cache-final-layout.log`, `cache-full-tests.log`,
`gate-failure.txt`, `retry-diagnostic-tests.log`,
`retry-diagnostic-result.json`, and the build logs. The focused layout suite
passed 78 checks. No installed-app acceptance or cross-platform release-gate
claim is made for this Mac renderer candidate.
