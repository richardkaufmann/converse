#!/usr/bin/env python3
"""Keep missing characters visible and summarize individual-character timings."""
import argparse
import json
import math


def correlate(row, capture):
    if row.get("drawn") is None:
        return []
    start, end = row["scheduled"], row["drawn"]
    return sorted({event["operation"] for event in capture["slowEvents"]
                   if event["mainThread"]
                   and event["operation"] not in ("mainQueueDelay", "keyDelivery", "dragDelivery", "resizeDraw", "dragFrameWait", "lotEditToAckProcessed", "groupMapApply", "lotAckSendFailed")
                   and event["uptime"] > start
                   and event["uptime"] - event["milliseconds"] / 1000 < end})


def summarize(report, capture=None):
    if report.get("schemaVersion") != 1:
        raise ValueError("Unsupported character capture schema")
    print(report["endpoint"])
    if "mouseStress" in report:
        mouse = report["mouseStress"]
        accounted = sum(mouse[key] for key in ["delivered", "skippedNoTracking", "skippedNoView"])
        print(f"Mouse stress: {mouse['hertz']} Hz; scheduled={mouse['scheduled']}, delivered={mouse['delivered']}, "
              f"no_tracking={mouse['skippedNoTracking']}, no_visible_view={mouse['skippedNoView']}, unaccounted={mouse['scheduled']-accounted}")
        print("  " + mouse['endpoint'])
        if accounted != mouse['scheduled'] or mouse['skippedNoView']:
            print("  INCOMPLETE mouse workload: do not claim a matched hover comparison.")
    expected = report["countPerLane"]
    for lane in ("input", "provider"):
        rows = [row for row in report["characters"] if row["lane"] == lane]
        for row in rows:
            if row.get("emitted") is not None and row.get("received") is not None and abs(row["received"] - row["emitted"]) > 60:
                raise ValueError("Clock mismatch or unbounded stall: do not interpret this capture as valid latency")
        sequences = [row["sequence"] for row in rows]
        if len(set(sequences)) != len(sequences) or any(n not in range(expected) for n in sequences):
            raise ValueError("Duplicate or out-of-range character sequence")
        drawn = sum(row.get("drawn") is not None for row in rows)
        print(f"{lane}: expected={expected}, recorded={len(rows)}, drawn={drawn}, missing_draw={expected-drawn}")
        for start, end in (("scheduled", "emitted"), ("emitted", "received"), ("received", "inserted"), ("emitted", "drawn"), ("received", "drawn"), ("scheduled", "drawn")):
            values = sorted((r[end] - r[start]) * 1000 for r in rows if r.get(start) is not None and r.get(end) is not None)
            if not values:
                continue
            if any(not math.isfinite(v) or v < 0 for v in values):
                raise ValueError(f"Invalid clock ordering: {lane} {start}->{end}")
            percentile = lambda p: values[max(0, math.ceil(p * len(values)) - 1)]
            print(f"  {start}->{end} n={len(values)} p50={percentile(.5):.2f} p95={percentile(.95):.2f} p99={percentile(.99):.2f} max={values[-1]:.2f} ms")
        frames = {}
        for row in rows:
            if row.get("drawn") is not None:
                frames[row["drawn"]] = frames.get(row["drawn"], 0) + 1
        print(f"  largest batch sharing a draw={max(frames.values(), default=0)} characters")
        if capture:
            slow = sorted((row for row in rows if row.get("drawn") is not None),
                          key=lambda row: row["drawn"] - row["scheduled"], reverse=True)[:5]
            for row in slow:
                operations = correlate(row, capture)
                print(f"  slow character {row['sequence']}: {(row['drawn']-row['scheduled'])*1000:.2f} ms; overlapping main-thread work: "
                      + (", ".join(operations) or "none recorded"))
    if capture:
        print(f"Correlation is temporal overlap, not causation; {capture['droppedSlowEvents']} slow events were overwritten.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("--performance", help="performance.json from the same run")
    args = parser.parse_args()
    capture = None
    if args.performance:
        with open(args.performance) as source:
            capture = json.load(source)
        if capture.get("schemaVersion") != 1:
            raise ValueError("Unsupported performance capture schema")
    with open(args.capture) as source:
        summarize(json.load(source), capture)
