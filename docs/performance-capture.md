# Investigating typing and scrolling stalls

On Mac, open **Converse → Settings → Debug**. **Record** keeps the most recent **30–600 seconds** of timing samples (default **60**). Press **Pause** after a stutter to freeze that buffer. **Off** stops recording, hides the title-bar pill, and turns off automatic recording. The title bar shows a red **RECORDING** pill while collecting and **PAUSED** while frozen. You can close Settings during recording.

**Record automatically on launch** defaults off in ordinary builds and on in developer TEST builds. The choice and history length are saved separately for each app edition. Richard's daily development profile can enable this once without changing defaults in public releases. Pausing does not change the launch preference; Off does.

**Export…** saves the last paused buffer to a chosen file for support. Nothing is uploaded. The frozen buffer is stored at `Performance Diagnostics/paused-performance.json` in the edition's data folder and survives restarting recording or relaunching the app. It is replaced on the next successful pause. The live rolling buffer is `Performance Diagnostics/performance.json`. A failed pause reports an error rather than offering an older file as the new capture.

For scripted launches, `CONVERSE_PERFORMANCE_DIAGNOSTICS=1` supplies the initial recording default when no launch preference is saved. Set it to `0` for an initially disabled TEST build. The analyzer supports schemas 1, 2 and 3. Windows UI timing is not instrumented. Mobile retains its existing controls and uses the same rolling recorder with the default 60-second window.

Run `python3 scripts/summarize-performance.py /path/to/performance.json` to compare:

- Main-queue scheduling delay and time from a keyboard event's timestamp until the composer handles it.
- Keyboard handling, text insertion and transcript rendering. Mac Parking Lots also record key delivery, key handling, text insertion and layout.
- Upward and downward mouse-wheel/trackpad scroll-event delivery and handler duration, separately for session transcripts (`sessionScrollDelivery`, `sessionScrollHandling`) and Parking Lots (`lotScrollDelivery`, `lotScrollHandling`), including momentum events. These aggregate both directions and do not record content or scroll positions.
- Archive snapshot creation, background encoding/writing, and synchronous checked saves (including waiting for the archive queue).
- Sidebar snapshot publication to connected devices.
- Mac-hosted Parking Lot edit handling, durable commit, acknowledgment encoding/queueing,
  and edit dispatch through local acknowledgment send completion.

The capture keeps samples whose completion times fall within the selected window, then computes counts, sums, maxima and six duration buckets from those retained samples. It includes the latest 512 events of at least 50 milliseconds. A secondary 50,000-sample safety cap bounds memory under exceptional event floods; dropped samples are disclosed and summaries then describe only retained samples. The file updates at most every five seconds during capture. File encoding and atomic writes run on a utility queue. Only one main-queue probe may be outstanding, so a blocked UI cannot accumulate probes. Disabled capture writes nothing. No message text, key characters, titles, session IDs, commands or credentials are recorded. Timestamps and app version/build are included. A main-queue probe still blocked at the deadline is recorded as an unfinished delay (a lower bound), rather than disappearing from the report. Scroll-handler duration does not measure the later display frame; these are not key-to-photon or frame-rate measurements.

Use the reported overlaps to choose the next measurement, not as proof of causality. A slow checked save alongside a main-queue delay suggests waiting for persistence; background writes alone do not establish a UI stall. Repeated transcript-render overlaps point toward rendering/layout work. Delays without an instrumented overlap need a main-thread stack sample or additional instrumentation. Sleep/wake and CPU scheduling contention can affect timings. The sampler runs every 250 milliseconds and can miss brief pauses; key delivery and operation timings complement it. Nested operation durations must not be added together.

Keep a baseline capture and a repeat capture after any fix under the same pane count, approximate transcript size and streaming load. Report the maximum and bucket counts, and whether a user-visible pause occurred. A fast idle capture does not prove that concurrent typing is fixed.


## Character and divider experiments (TEST builds)

The character probe is opt-in and requires a TEST bundle, an explicit disposable
`CONVERSE_DATA_DIR` containing a `character-probe-profile` marker, and
`CONVERSE_CHARACTER_PROBE=1`. Set `CONVERSE_CHARACTER_PROVIDER` to the absolute
path of `scripts/character-provider.py`. Optional `CONVERSE_CHARACTER_COUNT`
(default 200, maximum 1000) and `CONVERSE_CHARACTER_INTERVAL` (default 0.05 seconds)
control both lanes. Enable `CONVERSE_PERFORMANCE_DIAGNOSTICS=1` for correlation.

The experiment creates separate typing and streaming panes. Input deadlines are
scheduled off the main thread without waiting for the previous character. A real
subprocess emits individual `a` deltas through the ordinary Claude adapter. The
probe records each character separately, including scheduled time, emission,
main-thread receipt, input insertion and first observed visible-glyph draw.
`Performance Diagnostics/characters.json` is saved ten seconds after the input
schedule ends. Run `scripts/summarize-characters.py` on it for missing counts,
per-character percentiles and characters batched into the same draw. A missing
provider row also counts as missing; it never disappears from the denominator.

This measures synthetic key dispatch, not physical keyboard delivery. The endpoint
is an AppKit draw callback for a glyph intersecting the visible dirty region,
not physical monitor presentation. Covered/offscreen glyphs remain missing.
The provider's macOS monotonic timestamps must have consistent ordering with the
app's uptime; the summarizer rejects negative intervals rather than hiding them.

Divider diagnostics include event delivery, handler time, first queued drag to
resize application, native split-view application, wrapping thaw and first visible
transcript draw after a resize. Multiple resizes before a draw retain the oldest
pending timestamp. This is per-pane draw latency, not proof that every pane or the
physical screen has finished presenting. Compare continuous drag, held-button
pause, release and release outside the handle, with short and long transcripts.

Keep production data and real Parking Lots out of the disposable profile. Compare
an idle run with concurrent session streaming, switchboard traffic, images and
disposable lot changes; also compare a stationary pointer with pointer motion over
the transcript. Preserve identical character cadence and count between runs.

Build the dedicated probe with `CONVERSE_TEST_PROVIDER=Codex CONVERSE_CHARACTER_PROBE_BUILD=1 CONVERSE_APP_OUTPUT="$PWD/.build/Character Probe.app" ./build.sh`, then run `python3 scripts/run-character-probe.py '.build/Character Probe.app' --count 1000 --history-lines 500`. History is generated fixture text in both panes, and its line count is retained in the character report. Place the pointer over the streaming pane for the hover/autoscroll comparison. Use the same window size, pointer location, count, cadence and history for both builds; retain a separate short-history control. This workload does not yet create real switchboard, image-generation or lot-edit traffic.

`run-character-probe.py` retains `workload.json` beside the captures, including binary and fixture hashes. Compare two retained profile folders with `python3 scripts/compare-character-runs.py PROFILE_A PROFILE_B`. It rejects mismatched cadence, counts, history, fixture or positive-control settings, and explicitly flags incomplete draws. Keep window geometry, pointer placement and competing activity consistent too; those external conditions are not established by matching JSON settings. Repeat in reversed order. Stack sampling perturbs the run, so keep exploratory sampled captures separate from unsampled timing comparisons.

Character summaries separate schedule-to-draw, emission-to-draw and main-thread receipt-to-draw. A delayed synthetic generator can increase schedule-to-draw without an equivalent application delay; retain the emission and receipt stages when interpreting stalls.

For a controlled hover-handler stress case, add `--mouse-hz 60`, optionally with
`--web-image`. This schedules synthetic `mouseMoved` handler calls on the streaming
pane only while it owns an active move-tracking area. The report records scheduled,
delivered, skipped-without-tracking and skipped-without-a-visible-view counts. It
does not move the real pointer, fetch the placeholder image, or prove that natural
autoscroll generates those events. Use it to compare handler cost and tracking
eligibility; retain the real-pointer/autoscroll experiment as a separate check.
The fixture explicitly initializes tracking after the target view joins a window
and records `trackingInitialized`. A comparison without that evidence is invalid:
one build can otherwise receive no synthetic events merely because AppKit has not
refreshed its tracking areas. Check delivered/skipped counts against the intended
scenario before interpreting latency differences.
Eligibility checks the response-image area itself. AppKit can install other
move-tracking areas owned by the same text view; those must not stand in for the
area this experiment is meant to exercise.
Window frame, visibility, key status and actual pointer coordinates are sampled
every 100 input characters so changed geometry is visible in the retained report.

## Remote Parking Lot edits

Mac capture reports `lotEditHandling` from dispatch into the validated lot-edit
handler to its return, `lotEditCommit` for the durable commit, and
`lotAckEncodeQueue` for encoding, encryption and queueing the acknowledgment.
`lotEditToAckProcessed` extends from handler entry until Network.framework has
processed all acknowledgment chunks locally. A failed send is counted separately
as `lotAckSendFailed`. Retries that reuse a saved receipt produce an acknowledgment
timing but no new commit timing. Nested intervals must not be added together.

This is host-side turnaround, not an iPad round trip. The receive callback itself
uses the main queue, so these spans exclude waiting before that callback, inbound
transfer/decryption, and authority checks before the edit handler. Send completion
does not establish receipt or redraw on the iPad. The asynchronous turnaround spans
are excluded from the summarizers' list of potentially blocking main-thread work.
In-process transport fixtures complete at their mock sink, not a real network.

On Mac, typing into a Parking Lot adds substages nested inside `lotKeyHandling` and
`lotTextInsertion`: `lotProjectionEdit`, `lotRowsCommit` (containing `lotValidate`,
`lotNormalize`, `lotSnapshotCheck`, `lotEncodeWrite`, `lotUndoRegister`, `lotPublish`
and `lotSeenWrite`), `lotRender` (containing `lotProjectionBuild`, `lotAttributes`,
`lotStorageApply`, `lotSelection`, `lotCommentButtons` and `lotScrollVisible`), plus
`lotSubstitution`, `lotImageSpacing` and `lotDraw`. `Converse --lot-typing-profile`,
with `CONVERSE_DATA_DIR` set, types into synthetic 130- and 500-row lots in the real
pane and prints each stage's cost per keystroke; `CONVERSE_LOT_PROFILE_KEYS` and
`CONVERSE_LOT_PROFILE_PAUSE` lengthen a run so a sampler can attach.

View → Group records `groupMapCapture` (its bounded Store snapshot on the main
thread), `groupMapBuild` (graph, diff and encode on a worker) and `groupMapApply`
(the asynchronous round trip into the page, excluded from the summarizers' blocking
list). None of them runs while the window is closed or hidden.

To measure the delay a person sees on iPad, also instrument its local edit/queue,
send-to-matching-ack interval, and acknowledgment-to-visible-update interval.
Match acknowledgment IDs locally without recording lot contents. Calculate each
duration on one device's monotonic clock; never subtract Mac uptime from iPad
uptime. Comparing the iPad round trip with Mac handling distinguishes host work
from the remaining transport/scheduling delay, but does not by itself isolate
one-way network latency.

On iPad/iPhone, **About Converse → Performance diagnostics** starts capture and
exports the JSON. `lotRoundTrip` runs from first send of a mutation through a
validated matching acknowledgment and its queue update; retries keep the original
start time. Unmatched, outstanding and abandoned requests are not silently treated
as fast: the capture reports pending/dropped counts. Matching UUIDs stay in memory
and are never exported. Starting a new capture discards old matching state.

`lotLocalEdit` measures enqueueing and projecting an edit locally. `lotAckApply`
measures acknowledgment decoding, validation and local queue updates.
`lotInputToChange` measures an accepted UITextView input delegate call through its
text-change callback; a paste or IME operation can contain multiple characters.
`lotTextUpdate` measures updating a row's UIKit view, and `lotTextLayout` its sizing
calculation. These are event and operation timings, not physical key-to-photon or
acknowledgment-to-visible-glyph measurements. The 250 ms main-queue probe supplies
additional evidence of scheduling stalls. App suspension can delay probes; keep
controlled comparisons in the foreground.
