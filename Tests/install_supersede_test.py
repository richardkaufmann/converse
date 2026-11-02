#!/usr/bin/env python3
"""Two queued updates racing must elect the newest build as single winner.

Regression test for the 109-vs-110 morning where two install helpers both
reached INSTALLED and the older build won the destination. Drives the real
install.sh template (never a copy of its logic) with an isolated HOME, a
stubbed codesign/launchctl, and fake .app bundles, then runs both generated
helpers concurrently.
"""
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def make_app(path: Path, build: int, version: str) -> None:
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    with open(contents / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleVersion": str(build),
                       "CFBundleShortVersionString": version,
                       "CFBundleDisplayName": "Converse"}, handle)
    (contents / "MacOS" / "Converse").write_text(f"fake binary build {build}\n")


def stage(env: dict, source: Path, destination: Path) -> Path:
    """Run install.sh so it stages a job and (falsely) queues it via stubs."""
    before = {job.stat().st_mtime_ns for job in
              (Path(env["HOME"]) / "Library/Application Support/Converse Updates").glob("install.*")}
    # install.sh bakes the physical destination path (${destination:A}), so the
    # fake "running process" report must use the fully resolved form.
    baked = os.path.realpath(destination)
    run = subprocess.run(["/bin/zsh", str(REPO / "install.sh"), str(destination)],
                         env={**env, "CONVERSE_APP_OUTPUT": str(source),
                              "STUB_RUNNING_COMM": f"{baked}/Contents/MacOS/Converse"},
                         capture_output=True, text=True, cwd=REPO, timeout=120)
    assert "Update queued." in run.stdout, (run.stdout, run.stderr)
    jobs = [job for job in
            (Path(env["HOME"]) / "Library/Application Support/Converse Updates").glob("install.*")
            if job.stat().st_mtime_ns not in before]
    assert len(jobs) == 1, [str(job) for job in jobs]
    return jobs[0]


def helper_status(job: Path) -> str:
    return (job / "status.txt").read_text().splitlines()[0]


def dest_build(destination: Path) -> str:
    with open(destination / "Contents" / "Info.plist", "rb") as handle:
        return plistlib.load(handle)["CFBundleVersion"]


def make_env(root: Path) -> dict:
    stubs = root / "stubs"
    stubs.mkdir()
    (stubs / "codesign").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "codesign").chmod(0o700)
    # ps claims the destination app is still running so install.sh defers to
    # launchd; the stub launchctl then accepts the queue without touching the
    # real user domain. The generated helper is executed directly afterwards.
    (stubs / "ps").write_text("#!/bin/sh\necho \"$STUB_RUNNING_COMM\"\n")
    (stubs / "ps").chmod(0o700)
    (stubs / "launchctl").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "launchctl").chmod(0o700)
    # Hide the real dockutil: an empty listing keeps the helper's Dock repair
    # inert (covered separately by install_shortcut_test.py).
    (stubs / "dockutil").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "dockutil").chmod(0o700)
    home = root / "home"
    home.mkdir()
    return {**os.environ, "HOME": str(home),
            "PATH": str(stubs) + os.pathsep + os.environ["PATH"]}


def run_helpers_concurrently(env: dict, jobs):
    helper_env = {**env, "STUB_RUNNING_COMM": ""}
    procs = [subprocess.Popen(["/bin/zsh", str(job / "install.command")],
                              env=helper_env) for job in jobs]
    for proc in procs:
        assert proc.wait(timeout=180) in (0, 1, 3), proc.returncode


with tempfile.TemporaryDirectory(prefix="converse-supersede-test-") as temporary:
    root = Path(temporary)
    env = make_env(root)
    src109 = root / "src109.app"
    src110 = root / "src110.app"
    make_app(src109, 109, "0.5.84")
    make_app(src110, 110, "0.5.85")
    destination = root / "Applications" / "Converse.app"
    make_app(destination, 108, "0.5.83")

    # Stage the older build first so it would naturally win a naive race.
    job109 = stage(env, src109, destination)
    job110 = stage(env, src110, destination)

    run_helpers_concurrently(env, [job109, job110])

    assert dest_build(destination) == "110", dest_build(destination)
    assert not (destination / "Converse.app").exists(), "nested install from interleaved move"
    statuses = {helper_status(job109), helper_status(job110)}
    assert helper_status(job110).startswith("INSTALLED:"), helper_status(job110)
    assert helper_status(job109).startswith("SUPERSEDED:"), helper_status(job109)
    print("PASS: concurrent 109-vs-110 race installs 110 once and older stands down")

    # An older build queued after the newer one installed must not touch it.
    before = (destination / "Contents" / "MacOS" / "Converse").read_bytes()
    job109b = stage(env, src109, destination)
    run = subprocess.run(["/bin/zsh", str(job109b / "install.command")],
                         env={**env, "STUB_RUNNING_COMM": ""},
                         capture_output=True, text=True, timeout=180)
    assert run.returncode == 3, (run.returncode, run.stderr)
    assert helper_status(job109b).startswith("SUPERSEDED:"), helper_status(job109b)
    assert (destination / "Contents" / "MacOS" / "Converse").read_bytes() == before
    assert dest_build(destination) == "110"
    print("PASS: older build against newer install stands down without touching it")
