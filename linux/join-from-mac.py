#!/usr/bin/env python3
"""Join a Linux Converse home to this Mac's current Converse group over SSH.

Usage: python3 linux/join-from-mac.py <ssh-destination> [--host ADDRESS]

The Mac app must be running and already in a group. This script only drives
the Linux side through `converse admin-request`; you still compare the
eight-part number and press Pair yourself in Converse Groups on the Mac.

Status: new; its status/discovery path is tested against a joined Linux home,
but the pairing path has not yet been run end to end on a fresh computer.
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import time
import uuid

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]


def admin(destination, linux_id, operation, payload, mutate=False):
    request = {
        "adminApiVersion": 1,
        "requestID": str(uuid.uuid4()),
        "operation": operation,
        "expectedDeviceID": linux_id,
        "operationID": str(uuid.uuid4()) if mutate else None,
        "payload": payload,
    }
    # Non-interactive SSH may not read the login profile, so name the binary.
    run = subprocess.run(SSH + ["--", destination, 'exec "$HOME/.local/bin/converse" admin-request'],
                         input=json.dumps(request) + "\n", text=True, capture_output=True, timeout=40)
    if run.returncode == 255:
        sys.exit("SSH to " + destination + " failed: " + run.stderr.strip())
    try:
        response = json.loads(run.stdout)
    except ValueError:
        sys.exit("Unexpected reply from Linux (is Converse installed?): " + (run.stderr or run.stdout).strip())
    if not response.get("ok"):
        error = response.get("error") or {}
        sys.exit(operation + " failed: " + str(error.get("code")) + " - " + str(error.get("message")))
    return response["result"]


def watch(arguments, seconds):
    """Run a never-ending dns-sd command briefly and return what it printed."""
    process = subprocess.Popen(["dns-sd"] + arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    time.sleep(seconds)
    process.terminate()
    return process.communicate()[0]


def this_mac_advertisement():
    local_host = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True).stdout.strip()
    names = sorted(set(re.findall(r"_converse\._tcp\.\s+(.+?)\s*$", watch(["-B", "_converse._tcp", "local."], 3), re.M)))
    for name in names:
        lookup = watch(["-L", name, "_converse._tcp", "local."], 2)
        target = re.search(r"can be reached at (\S+?)\.?:(\d+)", lookup)
        if not target or target.group(1).lower() != (local_host + ".local").lower():
            continue
        txt = dict(re.findall(r"(device|group|name)=((?:\\ |\S)+)", lookup))
        return name, int(target.group(2)), txt
    sys.exit("Couldn't find this Mac's Converse on Bonjour. Is Converse running on this Mac?")


def primary_ipv4():
    route = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
    interface = re.search(r"interface:\s*(\S+)", route)
    if interface:
        address = subprocess.run(["ipconfig", "getifaddr", interface.group(1)], capture_output=True, text=True).stdout.strip()
        if address:
            return address
    return socket.gethostbyname(socket.gethostname())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("destination", help="SSH destination or ~/.ssh/config alias for the Linux computer")
    parser.add_argument("--host", help="this Mac's address as Linux should dial it (default: primary IPv4)")
    options = parser.parse_args()

    status = admin(options.destination, None, "status.get", {})
    linux_id, linux_name = status["device"]["deviceID"], status["device"].get("name") or options.destination
    print("Linux home: " + linux_name + " [" + linux_id[:8] + "]")

    name, port, txt = this_mac_advertisement()
    mac_id, group_id = txt.get("device", ""), txt.get("group", "")
    group_name = txt.get("name", "").replace("\\ ", " ")
    if not re.fullmatch(r"[0-9a-f]{64}", mac_id) or not group_id:
        sys.exit("This Mac isn't in a Converse group yet. Create one in Converse Groups first.")
    if (status.get("fabric") or {}).get("groupID") == group_id:
        print(linux_name + " is already in " + group_name + ". Nothing to do.")
        return
    host = options.host or primary_ipv4()
    print("This Mac:   " + name + " at " + host + ":" + str(port) + ", group " + group_name)

    # The device ID is the SHA-256 of the public key, so it is also the full fingerprint.
    binding = admin(options.destination, linux_id, "pairing.join.begin", {
        "requestCorrelationID": str(uuid.uuid4()),
        "sponsorDeviceID": mac_id,
        "sponsorPublicKeyFingerprint": mac_id,
        "sponsorEndpoint": {"host": host, "port": port},
        "groupID": group_id,
    }, mutate=True)
    query = {"pairingID": binding["pairingID"], "requestCorrelationID": binding["requestCorrelationID"]}

    print("\nOn this Mac, open Converse > Converse Groups. " + linux_name + " is asking to join; press Review.")
    deadline = time.time() + 60
    while binding["state"] == "connecting" and time.time() < deadline:
        time.sleep(1)
        binding = admin(options.destination, linux_id, "pairing.join.status", query)
    if binding["state"] != "awaiting_user":
        sys.exit("Pairing didn't reach the comparison step (state: " + binding["state"] + "). "
                 "Check that Linux can reach " + host + ":" + str(port) + ", then run this again.")

    shown_binding = dict(binding)
    print("\nLinux shows this number:\n\n    " + binding["verificationCode"] + "\n")
    print("Compare ALL EIGHT parts with the number on the Mac. If they match, press Pair on the Mac.")
    answer = input("Do all eight parts match? Type yes to let " + linux_name + " join " + group_name + ": ")
    binding = admin(options.destination, linux_id, "pairing.join.status", query)
    if answer.strip().lower() != "yes":
        admin(options.destination, linux_id, "pairing.join.cancel", {"binding": binding}, mutate=True)
        sys.exit("Canceled. " + linux_name + " did not join.")
    if binding["state"] != "awaiting_user":
        sys.exit("The pairing request is no longer waiting (state: " + binding["state"] + "). Run this again.")
    # Never approve a replacement handshake after the user compared an older code.
    # updatedAt is observation metadata; all other fields bind the shown prompt.
    if any(binding.get(key) != value for key, value in shown_binding.items() if key != "updatedAt"):
        sys.exit("The pairing changed while you compared the number. Run this again and compare the new number.")
    admin(options.destination, linux_id, "pairing.join.confirm", {"binding": shown_binding}, mutate=True)

    for _ in range(60):
        fabric = admin(options.destination, linux_id, "status.get", {}).get("fabric") or {}
        if fabric.get("groupID") == group_id:
            print("\nDone! " + linux_name + " joined " + group_name + ". It now appears under Group in the sidebar.")
            return
        time.sleep(1)
    sys.exit("Linux confirmed, but hasn't joined yet. Make sure you pressed Pair on the Mac, then run this again.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nStopped.")
