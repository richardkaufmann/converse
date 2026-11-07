"""Compatibility and incomplete-stall reporting for exported diagnostics."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "performance_summary", Path(__file__).resolve().parents[1] / "scripts/summarize-performance.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class PerformanceSummaryTests(unittest.TestCase):
    def capture(self, **changes):
        value = dict(schemaVersion=1, version="test", build="test", startedAt="start",
                     measuredAt="end", summaries={}, slowEvents=[], droppedSlowEvents=0)
        return dict(value, **changes)

    def test_legacy_mobile_capture_still_reads(self):
        self.assertIn("Converse test (test)", summary.summarize(self.capture()))

    def test_unfinished_probe_is_a_lower_bound_not_a_completed_event(self):
        text = summary.summarize(self.capture(schemaVersion=2,
                                 unfinishedMainQueueDelayMilliseconds=125.5))
        self.assertIn("at least 125.5 ms", text)
        self.assertIn("excluded from completed-delay statistics", text)
        self.assertIn("Retained delay events: 0", text)

    def test_lot_delivery_is_a_delay_not_its_own_cause(self):
        events = [dict(operation="lotScrollDelivery", uptime=3, milliseconds=90, mainThread=True)]
        text = summary.summarize(self.capture(schemaVersion=2, slowEvents=events))
        self.assertIn("Retained delay events: 1", text)
        self.assertIn("lotScrollDelivery 90.0 ms", text)
        self.assertIn("no instrumented slow main-thread operation overlapped", text)

    def test_unknown_schema_rejected(self):
        with self.assertRaises(ValueError):
            summary.summarize(self.capture(schemaVersion=999))


if __name__ == "__main__":
    unittest.main()
