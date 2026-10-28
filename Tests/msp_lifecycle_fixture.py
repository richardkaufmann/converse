#!/usr/bin/env python3
"""Offline MSP host with a real lock and intentionally slow release on exit."""
import json
import pathlib
import signal
import sys
import time

folder = pathlib.Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
lock = folder / "session.lock"
owned = False
session = None
signal.signal(signal.SIGTERM, lambda *_: None)

def emit(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

try:
    for line in sys.stdin:
        message = json.loads(line)
        method, params, rid = message.get("method"), message.get("params", {}), message.get("id")
        if method in ("initialize", "session/read"):
            emit(id=rid, result={})
        elif method == "session/resume":
            session = params["sessionId"]
            try:
                lock.mkdir()
                owned = True
                emit(id=rid, result={})
            except FileExistsError:
                emit(id=rid, error=dict(code=-32020, message=f"session {session} is already in use", data=dict(kind="sessionInUse")))
        elif method == "turn/start":
            assert owned
            text = params["displayText"]
            with (folder / "submitted.jsonl").open("a") as log:
                log.write(json.dumps(text) + "\n")
            emit(id=rid, result=dict(turnId=params["commandId"]))
            emit(method="item/completed", params=dict(sessionId=session, item=dict(itemId="answer", kind="agentMessage", text="answer: " + text)))
            emit(method="turn/completed", params=dict(sessionId=session, terminal="completed"))
finally:
    if owned:
        time.sleep(0.4)
        lock.rmdir()
