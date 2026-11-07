#!/usr/bin/python3
"""Offline Claude stream-json fixture: one character per fixed deadline."""
import json
import ctypes
import os
import sys
import time


# Python versions differ in the origin of time.monotonic() on macOS. Use the
# same Darwin uptime clock as ProcessInfo.systemUptime in the receiving app.
class Timespec(ctypes.Structure):
    _fields_ = [("seconds", ctypes.c_long), ("nanoseconds", ctypes.c_long)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.clock_gettime.argtypes = [ctypes.c_int, ctypes.POINTER(Timespec)]
libc.clock_gettime.restype = ctypes.c_int


def uptime():
    value = Timespec()
    if libc.clock_gettime(8, ctypes.byref(value)) != 0:  # CLOCK_UPTIME_RAW
        raise OSError(ctypes.get_errno(), "clock_gettime(CLOCK_UPTIME_RAW)")
    return value.seconds + value.nanoseconds / 1e9


def main():
    count = min(1000, max(1, int(os.environ.get("CONVERSE_CHARACTER_COUNT", "200"))))
    interval = min(1, max(0.01, float(os.environ.get("CONVERSE_CHARACTER_INTERVAL", "0.05"))))
    if "--input-format" in sys.argv:
        if not sys.stdin.readline():
            return
    start = uptime() + 0.25
    for sequence in range(count):
        scheduled = start + sequence * interval
        time.sleep(max(0, scheduled - uptime()))
        print(json.dumps({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "a"}},
            "character_probe": {"sequence": sequence, "scheduled": scheduled, "emitted": uptime()},
        }), flush=True)
    print(json.dumps({"type": "result", "subtype": "success", "result": "a" * count}), flush=True)


if __name__ == "__main__":
    main()
