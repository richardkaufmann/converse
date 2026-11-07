#!/usr/bin/env python3
"""Launch only a dedicated TEST app and retain the disposable capture profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--count", type=int, default=200)
    parser.add_argument("--interval", type=float, default=.05)
    parser.add_argument("--history-lines", type=int, default=0, help="Synthetic history lines in each pane (0..10000)")
    parser.add_argument("--mouse-hz", type=int, default=0, help="Synthetic tracking-eligible mouseMoved handler calls per second (0..120); not physical pointer motion")
    parser.add_argument("--web-image", action="store_true", help="Include a placeholder web image link; never fetched")
    parser.add_argument("--stall-ms", type=int, default=0, help="Positive control: suspend only the launched disposable process at 5 seconds")
    args = parser.parse_args()
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("ConverseNUXPreview"):
        raise SystemExit("Refusing to run: NUX mode overrides the disposable profile")
    if info.get("CFBundleIdentifier") != "local.richard.Converse.Test.CharacterProbe" or not info.get("ConverseTestProvider"):
        raise SystemExit("Refusing to run: use the dedicated CharacterProbe TEST bundle")
    if not 1 <= args.count <= 1000 or not .01 <= args.interval <= 1 or not 0 <= args.stall_ms <= 1000 or not 0 <= args.history_lines <= 10000 or not 0 <= args.mouse_hz <= 120:
        raise SystemExit("Count must be 1..1000, interval .01..1 seconds, stall 0..1000 ms, history 0..10000 lines")
    root = Path(tempfile.mkdtemp(prefix="converse-character-probe-"))
    (root / "character-probe-profile").touch()
    fixture = Path(__file__).resolve().with_name("character-provider.py")
    # Retain exact binaries and workload settings for reproducible A/B runs.
    (root / "workload.json").write_text(json.dumps({
        "count": args.count, "intervalSeconds": args.interval,
        "historyLines": args.history_lines, "positiveControlMilliseconds": args.stall_ms,
        "mouseHertz": args.mouse_hz, "webImage": args.web_image,
        "appSHA256": hashlib.sha256((app / "Contents/MacOS/Converse").read_bytes()).hexdigest(),
        "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "source": info.get("ConverseTestSource"),
        "systemLoadStart": os.getloadavg(),
        "endpoint": "synthetic key dispatch to visible AppKit glyph draw"
    }, indent=2) + "\n")
    env = dict(os.environ, CONVERSE_DATA_DIR=str(root), CONVERSE_CHARACTER_PROBE="1",
               CONVERSE_CHARACTER_PROVIDER=str(fixture), CONVERSE_CHARACTER_COUNT=str(args.count),
               CONVERSE_CHARACTER_INTERVAL=str(args.interval), CONVERSE_CHARACTER_HISTORY_LINES=str(args.history_lines), CONVERSE_PERFORMANCE_DIAGNOSTICS="1",
               CONVERSE_CHARACTER_MOUSE_HZ=str(args.mouse_hz), CONVERSE_CHARACTER_WEB_IMAGE="1" if args.web_image else "0",
               CONVERSE_TEST_COMMAND=str(fixture), CONVERSE_CLAUDE_LIVE_INPUT="0")
    with (root / "app.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/Converse")], env=env, stdout=log, stderr=subprocess.STDOUT)
        print(json.dumps({"pid": process.pid, "profile": str(root)}), flush=True)
        capture = root / "Performance Diagnostics/characters.json"
        started = time.monotonic()
        deadline = started + args.count * args.interval + 45
        stall_done = False
        try:
            while not capture.exists():
                if process.poll() is not None:
                    raise RuntimeError(f"Probe app exited {process.returncode}; see {root}/app.log")
                if time.monotonic() > deadline:
                    raise TimeoutError(f"No character capture; see {root}/app.log")
                if args.stall_ms and not stall_done and time.monotonic() - started >= 5:
                    stall_done = True
                    before = time.monotonic()
                    process.send_signal(signal.SIGSTOP)
                    try:
                        time.sleep(args.stall_ms / 1000)
                    finally:
                        process.send_signal(signal.SIGCONT)
                    (root / "positive-control.json").write_text(json.dumps({"kind": "whole-process suspension", "start": before, "end": time.monotonic()}))
                time.sleep(.25)
            report = json.loads(capture.read_text())
            if report.get("mouseStress", {}).get("hertz", 0) != args.mouse_hz or report.get("webImage", False) != args.web_image:
                raise RuntimeError("Probe binary did not apply the requested mouse/image workload; rebuild it")
            subprocess.run(["python3", str(fixture.with_name("summarize-characters.py")), str(capture), "--performance", str(root / "Performance Diagnostics/performance.json")], check=True)
            print(f"Retained capture: {capture}", flush=True)
        finally:
            # This PID was created here with this disposable profile. Never
            # locate or terminate another Converse/TEST process by name.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
