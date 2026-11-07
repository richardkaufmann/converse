# Investigating typing and scrolling stalls

On Mac, open **Converse → Settings → Debug** and enable **performance telemetry**. Set **Start in** (0–60 seconds) and **Run for** (5–300 seconds), then press **Go**. Return to the affected pane and type or scroll normally. You can close Settings; the capture continues and stops automatically. **Cancel** or turning telemetry off cancels the pending or active run. Telemetry starts disabled on the next app launch.

**Export** is disabled until a capture finishes and its final JSON file has saved successfully. It opens a save dialog; nothing is uploaded. Starting another run clears the previous export selection. Each run has a separate file under the current edition's `Performance Diagnostics/Runs` folder, so a failed write cannot export a stale capture. Production, Demo and TEST use their own data folders.

For scripted launches, `CONVERSE_PERFORMANCE_DIAGNOSTICS=1` retains the continuous recorder at `Performance Diagnostics/performance.json`. The old persisted General-page toggle no longer enables continuous recording at launch. The analyzer reads both the mobile schema 1 and Mac schema 2 captures. Windows UI timing is not instrumented.

Run `python3 scripts/summarize-performance.py /path/to/performance.json` to compare:

- Main-queue scheduling delay and time from a keyboard event's timestamp until the composer handles it.
- Keyboard handling, text insertion and transcript rendering. Mac Parking Lots also record key delivery, key handling, text insertion and layout.
- Upward and downward mouse-wheel/trackpad scroll-event delivery and handler duration, separately for session transcripts (`sessionScrollDelivery`, `sessionScrollHandling`) and Parking Lots (`lotScrollDelivery`, `lotScrollHandling`), including momentum events. These aggregate both directions and do not record content or scroll positions.
- Archive snapshot creation, background encoding/writing, and synchronous checked saves (including waiting for the archive queue).
- Sidebar snapshot publication to connected devices.
- Mac-hosted Parking Lot edit handling, durable commit, acknowledgment encoding/queueing,
  and edit dispatch through local acknowledgment send completion.

The capture keeps aggregate counts, sums, maxima and six duration buckets for every instrumented operation, plus the latest 512 events of at least 50 milliseconds. The file updates at most every five seconds during capture. File encoding and atomic writes run on a utility queue. Only one main-queue probe may be outstanding, so a blocked UI cannot accumulate probes. Disabled capture writes nothing. No message text, key characters, titles, session IDs, commands or credentials are recorded. Timestamps and app version/build are included. A main-queue probe still blocked at the deadline is recorded as an unfinished delay (a lower bound), rather than disappearing from the report. Scroll-handler duration does not measure the later display frame; these are not key-to-photon or frame-rate measurements.

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
