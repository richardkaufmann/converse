#!/usr/bin/env python3
"""Prepare an offline QA app without accessing protected user folders at runtime.

Run after ./build.sh. Launch the printed .app path manually or with native UI tools.
The app, fixtures, working folder and data all live in Application Support. This
helper never launches the app, requests permissions or copies real account data.
Use --approval-preview for a static permission UI preview; its choices are not
connected to a CLI. Actual approval round trips are checked by test.sh.
"""
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import uuid
import sys

repo = Path(__file__).resolve().parents[1]
built = Path(os.environ.get("CONVERSE_APP_OUTPUT", str(repo / ".build/Converse.app"))).resolve()
root = Path.home() / "Library/Application Support/Converse Developer QA"
app = root / "Converse Isolated QA.app"
contents = app / "Contents"
work = root / "Work"
data = root / "Data"
account = root / "fixture-codex-account"
running = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
if str(contents / "MacOS/ConverseNative") in [line.strip() for line in running]:
    raise SystemExit("Quit Converse Isolated QA before rebuilding its bundle.")
for directory in [contents / "MacOS", contents / "Resources", work, data, account, root / "Config", root / "RuntimeData"]:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(built / "Contents/MacOS/Converse", contents / "MacOS/ConverseNative")
shutil.copy2(built / "Contents/Resources/Converse.icns", contents / "Resources/Converse.icns")
shutil.copytree(built / "Contents/Resources/ProviderLogos", contents / "Resources/ProviderLogos", dirs_exist_ok=True)
shutil.copy2(repo / "Tests/provider_fixture.py", root / "provider_fixture.py")
info = plistlib.loads((built / "Contents/Info.plist").read_bytes())
info.update(CFBundleIdentifier="local.converse.IsolatedQA", CFBundleName="Converse Isolated QA", CFBundleDisplayName="Converse Isolated QA")
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
wrapper = contents / "MacOS/Converse"
wrapper.write_text("#!/bin/zsh\n" + ("export CONVERSE_QA_APPROVAL=1\n" if "--approval-preview" in sys.argv else "")
                   + ("export CONVERSE_QA_REMOTE=1\n" if "--remote-preview" in sys.argv or "--pairing-preview" in sys.argv else "")
                   + ("export CONVERSE_QA_PAIRING=1\n" if "--pairing-preview" in sys.argv else "") + "cd " + shlex.quote(str(work)) + "\n"
                   "export CONVERSE_TEST_COMMAND=offline-fixture\n"
                   "export XDG_CONFIG_HOME=" + shlex.quote(str(root / "Config")) + "\n"
                   "export XDG_DATA_HOME=" + shlex.quote(str(root / "RuntimeData")) + "\n"
                   "export CONVERSE_DATA_DIR=" + shlex.quote(str(data)) + "\n"
                   "exec " + shlex.quote(str(contents / "MacOS/ConverseNative")) +
                   " > " + shlex.quote(str(root / "app.log")) + " 2>&1\n")
wrapper.chmod(0o755)
archive = data / "sessions.json"
if not archive.exists():
    entry = dict(id=str(uuid.uuid4()), name="Offline Codex", engine="codex",
                 command="python3 " + shlex.quote(str(root / "provider_fixture.py")) + " codex",
                 directory=str(work), accountID="offline-codex", accountName="Offline QA", accountDirectory=str(account))
    sessions = [dict(id=str(uuid.uuid4()), entry=entry, title=title,
                     messages=[dict(id=str(uuid.uuid4()), role="assistant", text="Offline QA conversation. No live model requests.", images=[])],
                     draft="Draft for " + title, attachments=[], remoteID=None, started=False,
                     toolStatus=dict(model="fixture-sol", effort="high", access="read-only", usage="not reported"),
                     choices=dict(model="fixture-sol", effort="high", access="read-only"), pending=[])
                for title in ["Hover Alpha", "Hover Beta", "Hover Gamma"]]
    archive.write_text(json.dumps(dict(entries=[entry], sessions=sessions,
                         accounts=[dict(id="offline-codex", name="Offline QA", engine="codex", directory=str(account))], setupCompleted=True)))
# Refuse to reuse a QA archive accidentally configured for a live CLI or a
# protected working folder. Rebuild disposable QA data explicitly if needed.
saved = json.loads(archive.read_text())
for entry in saved["entries"] + [s["entry"] for s in saved["sessions"]]:
    assert entry["engine"] in ["codex", "claude", "muse"] and entry["command"] == "python3 " + shlex.quote(str(root / "provider_fixture.py")) + " " + entry["engine"], "QA command must use the offline fixture"
    assert Path(entry["directory"]).resolve().is_relative_to(root.resolve()), "QA working directory must be isolated"
    assert Path(entry["accountDirectory"]).resolve().is_relative_to(root.resolve()), "QA account must be isolated"
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
print(app)
