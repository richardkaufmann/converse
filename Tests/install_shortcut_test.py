#!/usr/bin/env python3
"""Exercise the deferred installer's Dock repair with an isolated mock Dock."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path("install.sh").read_text()
cleanup = next(line for line in source.splitlines() if line.startswith("trap ") and " EXIT" in line)
repair = source.split("# Keep an existing Converse shortcut", 1)[1].split("\nHELPER", 1)[0]
with tempfile.TemporaryDirectory(prefix="converse-dock-test-") as temporary:
    root = Path(temporary)
    mock = root / "dockutil"
    mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['MOCK_DOCK_STATE']); s=json.loads(p.read_text())
if sys.argv[1]=='--list':
    if s['uri']: print(s['label']+'\\t'+s['uri']+'\\tpersistentApps')
elif sys.argv[1]=='--add':
    s['calls']+=1; p.write_text(json.dumps(s))
    if s['fail']: sys.exit(1)
    s['uri']=pathlib.Path(sys.argv[2]).as_uri()+'/'; p.write_text(json.dumps(s))
else: sys.exit(2)
''')
    mock.chmod(0o700)
    for name, initial, fail, expected_calls, expected_exit in [
        ("absent", "", False, 0, 0),
        ("correct", "correct", False, 0, 0),
        ("obsolete", "file:///old/Converse.app/", False, 1, 0),
        ("repair-failed", "file:///old/Converse.app/", True, 1, 1),
        ("demo-leaves-production", "file:///production/Converse.app/", False, 0, 0),
        ("demo-repairs-demo", "file:///old/Converse%20Demo.app/", False, 1, 0),
    ]:
        import json
        job = root / name
        job.mkdir()
        (job / "agent.plist").write_text("isolated fixture")
        destination = job / "Converse.app"
        uri = destination.as_uri() + "/"
        state = job / "dock.json"
        state.write_text(json.dumps(dict(uri=uri if initial == "correct" else initial, calls=0, fail=fail, label="Converse Demo" if name == "demo-repairs-demo" else "Converse")))
        environment = dict(os.environ, MOCK_DOCK_STATE=str(state), job=str(job), destination=str(destination),
                           dock_command=str(mock), status_file=str(job / "status.txt"), version="fixture", dock_label="Converse Demo" if name.startswith("demo-") else "Converse")
        run = subprocess.run(["/bin/zsh", "-c", "set -eu\n" + cleanup + "\n# Keep an existing Converse shortcut" + repair],
                             env=environment, capture_output=True, text=True)
        result = json.loads(state.read_text())
        assert run.returncode == expected_exit, (name, run.stderr)
        assert result["calls"] == expected_calls, name
        assert not (job / "agent.plist").exists(), name
        assert (job / "status.txt").read_text().startswith("INSTALLED:"), name
        if name == "demo-leaves-production":
            assert result["uri"] == initial, name
        elif not fail and initial:
            assert result["uri"] == uri, name
        print("PASS: Installer Dock " + name + " preserves intent and cleans deferred job")
