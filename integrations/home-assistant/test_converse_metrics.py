"""Focused checks for counting and omission semantics."""

from __future__ import annotations

import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from io import BytesIO

import converse_metrics as metrics


CONFIG = {"github_repo": "example/converse", "release_tag": "v0.6.3",
          "ha_url": "http://homeassistant.local:8123", "ha_token_file": "/unused",
          "entity_prefix": "example_converse", "dashboard_title": "Example Converse",
          "dashboard_slug": "example-converse"}


class MetricsTests(unittest.TestCase):
    def test_counts_and_pr_exclusion(self) -> None:
        def fake(url: str, **kwargs: object) -> tuple[object, dict[str, str]]:
            if url.endswith("/repos/example/converse"):
                return {"stargazers_count": 3, "subscribers_count": 2, "forks_count": 1}, {}
            if "/releases?" in url:
                return [{"tag_name": "v0.6.3", "assets": [
                    {"name": "Converse-macOS.zip", "download_count": 4},
                    {"name": "Converse-Windows-arm64.zip", "download_count": 5},
                    {"name": "Converse-hackathon-demo.mp4", "download_count": 1},
                    {"name": "Converse-macOS.zip.sha256", "download_count": 30}]}], {}
            if "/issues?" in url:
                return [{"labels": [{"name": "BUG"}]}, {"labels": [{"name": "enhancement"}]},
                        {"pull_request": {}, "labels": [{"name": "bug"}]}], {}
            if "/pulls?" in url:
                return [{"number": 9}], {}
            if "/traffic/views?" in url:
                return {"count": 82, "uniques": 1, "views": [{"timestamp": "2026-11-04T00:00:00Z", "count": 82, "uniques": 1}]}, {}
            if "/traffic/clones?" in url:
                return {"count": 644, "uniques": 48, "clones": []}, {}
            raise AssertionError(url)
        with patch.object(metrics, "json_request", side_effect=fake):
            values, detail = metrics.collect_github(CONFIG, "fake")
        self.assertEqual(values["release_downloads"], 10)
        self.assertEqual([values[x] for x in ("release_mac_downloads", "release_windows_downloads", "release_demo_downloads")], [4, 5, 1])
        self.assertEqual([values[x] for x in ("open_issues", "open_bugs", "open_prs")], [2, 1, 1])
        self.assertEqual([values[x] for x in ("views_14d", "viewers_14d", "clones_14d", "cloners_14d")], [82, 1, 644, 48])
        self.assertEqual(len(detail["release_assets"]), 3)

    def test_no_permission_does_not_publish_false_traffic_zero(self) -> None:
        def fake(url: str, **kwargs: object) -> tuple[object, dict[str, str]]:
            if url.endswith("/repos/example/converse"):
                return {"stargazers_count": 0, "subscribers_count": 0, "forks_count": 0}, {}
            if "/releases?" in url:
                return [{"tag_name": "v0.6.3", "assets": []}], {}
            if "/issues?" in url or "/pulls?" in url:
                return [], {}
            if "/traffic/" in url:
                raise HTTPError(url, 403, "forbidden", {}, BytesIO(b"{}"))
            raise AssertionError(url)
        with patch.object(metrics, "json_request", side_effect=fake):
            values, detail = metrics.collect_github(CONFIG, None)
        self.assertNotIn("views_14d", values)
        self.assertIn("traffic_unavailable", detail)
        self.assertNotIn("Traffic history", [card.get("title") for card in metrics.dashboard_config(CONFIG, set(values))["views"][0]["cards"]])

    def test_discord_optional(self) -> None:
        values, detail = metrics.collect_discord(CONFIG)
        self.assertEqual(values, {})
        self.assertIn("discord_unavailable", detail)

    def test_config_rejects_bad_entity_prefix(self) -> None:
        with self.assertRaises(ValueError):
            metrics.validate_config({**CONFIG, "entity_prefix": "../bad"})


if __name__ == "__main__":
    unittest.main()
