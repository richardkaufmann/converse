#!/usr/bin/env python3
"""Install the optional Converse HA collector as a five-minute macOS LaunchAgent."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from converse_metrics import validate_config
import json


LABEL = "app.kaoslabs.converse-home-assistant-metrics"
SOURCE = Path(__file__).with_name("converse_metrics.py")
DESTINATION = Path.home() / "Library/Application Support/Converse HA Metrics"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")


def install(config_file: Path) -> dict[str, str]:
    config_file = config_file.expanduser().resolve()
    config = json.loads(config_file.read_text(encoding="utf-8"))
    validate_config(config)
    if config_file.stat().st_mode & 0o077:
        raise ValueError("Collector config must be owner-only (mode 0600)")
    DESTINATION.mkdir(parents=True, exist_ok=True)
    script = DESTINATION / SOURCE.name
    shutil.copy2(SOURCE, script)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(script), "collect", "--config", str(config_file)],
        "WorkingDirectory": str(DESTINATION),
        "RunAtLoad": True,
        "StartInterval": 300,
        "ProcessType": "Background",
        "StandardOutPath": str(DESTINATION / "collector.out.log"),
        "StandardErrorPath": str(DESTINATION / "collector.err.log"),
    }
    temporary = PLIST.with_suffix(".plist.tmp")
    with temporary.open("wb") as stream:
        plistlib.dump(payload, stream)
    os.replace(temporary, PLIST)
    domain = "gui/" + str(os.getuid())
    subprocess.run(["launchctl", "bootout", domain, str(PLIST)], capture_output=True, check=False)
    subprocess.run(["launchctl", "bootstrap", domain, str(PLIST)], capture_output=True, check=True)
    status = subprocess.run(["launchctl", "print", domain + "/" + LABEL], capture_output=True, text=True, check=True)
    if str(script) not in status.stdout:
        raise RuntimeError("LaunchAgent did not register the installed collector")
    return {"label": LABEL, "script": str(script), "config": str(config_file), "plist": str(PLIST)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(install(args.config), indent=2))


if __name__ == "__main__":
    main()
