# Transcript render investigation (Mac 149)

This branch is a diagnostic experiment based on release/149 `1dc455d`, not a
performance fix or a release candidate. The installed app and frozen release
worktrees are unchanged. No personal transcript content is included.

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

Next: measure the history-preparation substeps, then evaluate reusing unchanged
prepared blocks. Preserve dynamic session labels, disclosure changes, images,
copy content, timestamps, selection and draft-relative caret positions. Compare
the same fixtures before and after; repeat the real multi-pane typing capture.

## Validation

The diagnostic build succeeds. The existing conversation-layout self-test
passes, including draft hydration, changed-tail replacement, hidden activity,
selection, copying and following behavior. This branch has not had a full
release gate. Raw local output is in `.build/render-profile/` (`baseline.log`,
`sampled-run.log`, `synthetic.sample.txt`, `layout-tests.log`, `build.log`).
