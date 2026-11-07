#!/bin/zsh
# Cross-platform command payload binding over real sockets: a Core
# (Windows/Linux) viewer against an isolated Mac home, then a Mac viewer
# against an isolated Core home. Each direction re-sends one command ID with
# exact, key-permuted and changed bytes. Never touches a production Group.
set -euo pipefail
cd "${0:A:h}/.."
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
dotnet="${DOTNET:-$(command -v dotnet || print ~/.dotnet/dotnet)}"
if [[ ! -x "$app/Contents/MacOS/Converse" ]]; then print -u2 'Build the Mac app first (./build.sh) or set CONVERSE_APP_OUTPUT.'; exit 2; fi
"$dotnet" build windows/src/Converse.Core.Tests -c Release -nologo -v q > /dev/null
core=("$dotnet" run --no-build --project windows/src/Converse.Core.Tests -c Release --)
mac_home=$(mktemp -d /tmp/converse-ipad-interop.XXXXXX)
core_home=$(mktemp -d /tmp/converse-command-binding.XXXXXX)
mkdir -p "$mac_home/data" "$core_home/home" "$core_home/viewer"
pids=()
cleanup() {
    touch "$mac_home/data/stop" "$core_home/home/stop"
    for pid in $pids; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM
wait_for() {
    for attempt in {1..600}; do
        if [[ -s "$1" ]]; then cat "$1"; return 0; fi
        if ! kill -0 "$2" 2>/dev/null; then cat "$3" >&2; return 1; fi
        sleep 0.05
    done
    print -u2 "Timed out waiting for $1"; return 1
}

print 'Windows/Linux viewer -> isolated Mac home'
CONVERSE_TEST_COMMAND=isolated-fixture CONVERSE_DATA_DIR="$mac_home/data" "$app/Contents/MacOS/Converse" --ipad-home-fixture > "$mac_home/home.log" 2>&1 &
pids+=$!
group_port=$(wait_for "$mac_home/data/group-port" $! "$mac_home/home.log")
"${core[@]}" --mac-command-interop 127.0.0.1 "$group_port"
touch "$mac_home/data/stop"

print 'Mac viewer -> isolated Windows/Linux Core home'
"${core[@]}" --core-command-home "$core_home/home" > "$core_home/home.log" 2>&1 &
pids+=$!
core_port=$(wait_for "$core_home/home/port" $! "$core_home/home.log")
CONVERSE_TEST_COMMAND=isolated-viewer CONVERSE_DATA_DIR="$core_home/viewer" "$app/Contents/MacOS/Converse" --core-command-interop 127.0.0.1 "$core_port"
touch "$core_home/home/stop"
wait
print "Core home applied titles: $(tr '\n' '|' < "$core_home/home/titles" 2>/dev/null)"
print "Isolated evidence: $mac_home $core_home"
