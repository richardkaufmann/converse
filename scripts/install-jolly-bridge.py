#!/usr/bin/env python3
"""Explicit one-time Jolly routing handoff. Never invoked by app startup/build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time
import urllib.request

def run(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--old-agent-plist")
    parser.add_argument("--old-entrypoint")
    parser.add_argument("--old-outbox")
    args = parser.parse_args()
    home = Path.home()
    support = home / "Library/Application Support/Converse Bridge"
    spool = home / "Library/Application Support/Converse/Jolly"
    old = plistlib.loads(Path(args.old_agent_plist).read_bytes()) if args.old_agent_plist else None
    token = Path(args.token_file).read_bytes().strip()
    if not token or len(token) > 65536:
        raise SystemExit("Missing or invalid existing bridge token.")
    pids = run(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:4691", "-sTCP:LISTEN"], False).stdout.split()
    for pid in pids:
        command = run(["/bin/ps", "-p", pid, "-o", "command="]).stdout
        if not args.old_entrypoint or args.old_entrypoint not in command:
            raise SystemExit("Port 4691 belongs to an unexpected process; no services changed.")
    if not args.activate:
        print("Prepared: replace approved bridge on 4691; preserve token and tunnel; import unread outbox; no fallback.")
        return
    os.umask(0o077)
    support.mkdir(parents=True, exist_ok=True)
    backup = support / ("handoff-" + time.strftime("%Y%m%d-%H%M%S"))
    backup.mkdir(mode=0o700)
    if old: shutil.copy2(args.old_agent_plist, backup / "previous-agent.plist")
    (support / "bridge.token").write_bytes(token + b"\n")
    (support / "bridge.token").chmod(0o600)
    shutil.copy2(Path(__file__).with_name("jolly_bridge.py"), support / "jolly_bridge.py")
    (spool / "outbox").mkdir(parents=True, exist_ok=True)
    imported = 0
    if args.old_outbox and Path(args.old_outbox).exists():
        shutil.copy2(args.old_outbox, backup / "previous-outbox.json")
        value = json.loads(Path(args.old_outbox).read_text())
        for entry in value.get("messages", []):
            if not isinstance(entry, dict) or entry.get("read") or not entry.get("text"): continue
            key = hashlib.sha256(json.dumps(entry, sort_keys=True).encode()).hexdigest()
            destination = spool / "outbox" / (key + ".json")
            if not destination.exists():
                destination.write_text(json.dumps({**entry, "id": key, "read": False})); imported += 1
    domain = "gui/" + str(os.getuid())
    if old:
        run(["launchctl", "disable", domain + "/" + old["Label"]])
        run(["launchctl", "bootout", domain + "/" + old["Label"]], False)
    for pid in pids:
        # Identity was checked above; re-check immediately before terminating.
        command = run(["/bin/ps", "-p", pid, "-o", "command="], False).stdout
        if args.old_entrypoint in command: os.kill(int(pid), signal.SIGTERM)
    for _ in range(50):
        if not run(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:4691", "-sTCP:LISTEN"], False).stdout.strip(): break
        time.sleep(.1)
    else: raise SystemExit("Previous listener did not stop. No replacement or fallback started.")
    label = "local.converse.jolly.bridge"
    plist = home / "Library/LaunchAgents" / (label + ".plist")
    doc = {"Label": label, "ProgramArguments": ["/usr/bin/python3", str(support / "jolly_bridge.py"), "--root", str(spool), "--token-file", str(support / "bridge.token")],
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "StandardOutPath": str(support / "bridge.log"), "StandardErrorPath": str(support / "bridge-error.log")}
    plist.write_bytes(plistlib.dumps(doc)); plist.chmod(0o600)
    run(["launchctl", "enable", domain + "/" + label])
    run(["launchctl", "bootstrap", domain, str(plist)])
    for _ in range(40):
        try:
            with urllib.request.urlopen("http://127.0.0.1:4691/health", timeout=2) as response:
                health = json.load(response)
            if health.get("service") == "converse-jolly":
                print("ACTIVE: Jolly routes exclusively to Converse.")
                print("Unread messages preserved:", imported)
                print("Backup:", backup)
                print("App available:", health.get("appAvailable", False))
                return
        except OSError: pass
        time.sleep(.25)
    raise SystemExit("Replacement failed health verification. Routing remains unavailable; no fallback was enabled.")

if __name__ == "__main__": main()
