#!/usr/bin/env python3
"""Summarize a Converse bounded performance capture without private app data."""
import argparse
import json


def summarize(capture):
    if capture.get("schemaVersion") not in (1, 2, 3):
        raise ValueError("Unsupported performance capture schema")
    lines = [f"Converse {capture.get('version')} ({capture.get('build')})",
             f"Capture: {capture.get('startedAt')} to {capture.get('measuredAt')}",
             "Operation                 Count    Mean ms     Max ms    >50 ms"]
    for name, value in sorted(capture["summaries"].items(),
                              key=lambda row: row[1]["maximumMilliseconds"], reverse=True):
        count = value["count"]
        mean = value["totalMilliseconds"] / count if count else 0
        slow = sum(value["buckets"][3:])
        lines.append(f"{name:25} {count:6} {mean:10.2f} {value['maximumMilliseconds']:10.2f} {slow:9}")
    if "historySeconds" in capture:
        lines.append(f"\nRolling history: {capture['historySeconds']:g} seconds; samples dropped at capacity: {capture.get('droppedSamples', 0)}.")
    unfinished = capture.get("unfinishedMainQueueDelayMilliseconds")
    if unfinished is not None:
        lines.append(f"\nMain-queue probe still blocked at capture end: at least {unfinished:.1f} ms; excluded from completed-delay statistics.")
    events = capture["slowEvents"]
    if 'pendingRoundTrips' in capture:
        lines.append(f"\nRound trips still pending: {capture['pendingRoundTrips']}; dropped or abandoned: {capture.get('droppedRoundTrips', 0)}. Completed timings exclude these requests.")
    stalls = [event for event in events if event["operation"] in ("mainQueueDelay", "keyDelivery", "lotKeyDelivery", "lotScrollDelivery", "sessionScrollDelivery", "dragDelivery", "dragFrameWait", "resizeDraw")]
    lines.append(f"\nRetained delay events: {len(stalls)}; overwritten slow events: {capture['droppedSlowEvents']}")
    for stall in sorted(stalls, key=lambda event: event["milliseconds"], reverse=True)[:10]:
        end = stall["uptime"]
        start = end - stall["milliseconds"] / 1000
        overlapping = set()
        for event in events:
            if event["operation"] in ("mainQueueDelay", "keyDelivery", "lotKeyDelivery", "lotScrollDelivery", "sessionScrollDelivery", "dragDelivery", "dragFrameWait", "resizeDraw", "lotEditToAckProcessed", "groupMapApply", "lotAckSendFailed") or not event["mainThread"]:
                continue
            event_start = event["uptime"] - event["milliseconds"] / 1000
            if event_start < end and event["uptime"] > start:
                overlapping.add(event["operation"])
        lines.append(f"{stall['operation']} {stall['milliseconds']:.1f} ms at uptime {end:.3f}: "
                     + (", ".join(sorted(overlapping)) if overlapping else "no instrumented slow main-thread operation overlapped"))
    lines.append("\nOverlap is a lead, not proof of cause. Nested spans overlap; do not add their durations. "
                 "Scheduler contention and sleep/wake can also delay probes. The 250 ms sampler can miss short stalls; "
                 "key timings and instrumented spans provide additional evidence.")
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", help="Performance Diagnostics/performance.json")
    args = parser.parse_args()
    with open(args.capture, encoding="utf-8") as source:
        print(summarize(json.load(source)))
