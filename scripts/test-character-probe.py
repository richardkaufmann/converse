#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("summary", ROOT / "summarize-characters.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class CharacterProbeTests(unittest.TestCase):
    def test_missing_and_batched_characters_remain_visible(self):
        report = {"schemaVersion": 1, "endpoint": "draw callback", "countPerLane": 3, "characters": [
            {"lane": "input", "sequence": 0, "scheduled": 1, "emitted": 1.01, "received": 1.02, "drawn": 1.5},
            {"lane": "input", "sequence": 1, "scheduled": 1.1, "emitted": 1.11, "received": 1.12, "drawn": 1.5},
            {"lane": "input", "sequence": 2, "scheduled": 1.2},
        ]}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            summary.summarize(report)
        self.assertIn("input: expected=3, recorded=3, drawn=2, missing_draw=1", output.getvalue())
        self.assertIn("provider: expected=3, recorded=0, drawn=0, missing_draw=3", output.getvalue())
        self.assertIn("largest batch sharing a draw=2 characters", output.getvalue())
        report["characters"][0]["received"] = 0
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "clock ordering"):
            summary.summarize(report)

    def test_correlations_exclude_background_work_and_nonoverlap(self):
        capture = {"slowEvents": [
            {"operation": "transcriptRender", "mainThread": True, "uptime": 1.4, "milliseconds": 100},
            {"operation": "archiveEncodeWrite", "mainThread": False, "uptime": 1.4, "milliseconds": 100},
            {"operation": "sidebarPublish", "mainThread": True, "uptime": 2.0, "milliseconds": 100},
        ]}
        self.assertEqual(summary.correlate({"scheduled": 1, "drawn": 1.5}, capture), ["transcriptRender"])

    def test_comparison_rejects_mismatches_and_discloses_missing_draws(self):
        spec = importlib.util.spec_from_file_location("comparison", ROOT / "compare-character-runs.py")
        comparison = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(comparison)
        workload = dict(count=2, intervalSeconds=.05, historyLines=500, positiveControlMilliseconds=0,
                        fixtureSHA256="fixture", endpoint="draw", appSHA256="a")
        report = {"characters": [{"lane": "input", "sequence": 0, "scheduled": 1, "drawn": 1.1}]}
        self.assertIn("INCOMPLETE", comparison.compare((workload, report), (workload, report)))
        with self.assertRaisesRegex(ValueError, "different workloads: historyLines"):
            comparison.compare((workload, report), (dict(workload, historyLines=0), report))
        with self.assertRaisesRegex(ValueError, "different workloads: mouseHertz"):
            comparison.compare((workload, report), (dict(workload, mouseHertz=60), report))
        with self.assertRaisesRegex(ValueError, "different workloads: webImage"):
            comparison.compare((workload, report), (dict(workload, webImage=True), report))

    def test_missing_mouse_dispatch_is_disclosed(self):
        report = dict(schemaVersion=1, endpoint="draw", countPerLane=1, characters=[],
                      mouseStress=dict(hertz=60, scheduled=3, delivered=1, skippedNoTracking=0,
                                       skippedNoView=1, endpoint="synthetic handler"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            summary.summarize(report)
        self.assertIn("unaccounted=1", output.getvalue())
        self.assertIn("INCOMPLETE mouse workload", output.getvalue())

    def test_hover_comparison_requires_tracking_initialization(self):
        spec = importlib.util.spec_from_file_location("comparison", ROOT / "compare-character-runs.py")
        comparison = importlib.util.module_from_spec(spec); spec.loader.exec_module(comparison)
        workload = dict(count=1, intervalSeconds=.05, historyLines=500, positiveControlMilliseconds=0,
                        fixtureSHA256="fixture", endpoint="draw", appSHA256="a", mouseHertz=60, webImage=True)
        report = dict(characters=[], mouseStress=dict(scheduled=3, delivered=0, skippedNoTracking=3, skippedNoView=0))
        self.assertIn('INVALID hover comparison', comparison.compare((workload, report), (workload, report)))
        report['mouseStress']['trackingInitialized'] = True
        self.assertNotIn('INVALID hover comparison', comparison.compare((workload, report), (workload, report)))

    def test_fixture_streams_individual_characters_with_fixed_deadlines(self):
        env = dict(os.environ, CONVERSE_CHARACTER_COUNT="3", CONVERSE_CHARACTER_INTERVAL="0.01")
        result = subprocess.run([str(ROOT / "character-provider.py"), "--input-format", "stream-json"],
                                input='{"type":"user"}\n', text=True, capture_output=True, env=env, check=True, timeout=5)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(rows), 4)
        for index, row in enumerate(rows[:3]):
            self.assertEqual(row["event"]["delta"]["text"], "a")
            probe = row["character_probe"]
            self.assertEqual(probe["sequence"], index)
            self.assertGreaterEqual(probe["emitted"], probe["scheduled"])
            self.assertLess(abs(probe["emitted"] - time.clock_gettime(time.CLOCK_UPTIME_RAW)), 5)
            self.assertAlmostEqual(probe["scheduled"] - rows[0]["character_probe"]["scheduled"], index * .01, places=6)


if __name__ == "__main__":
    unittest.main()
