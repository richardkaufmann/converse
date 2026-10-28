#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
: "${CONVERSE_MAC_APP:?Set CONVERSE_MAC_APP to an isolated built Mac app bundle}"
fixture=$(mktemp -d /tmp/converse-ipad-interop.XXXXXX)
mkdir -p "$fixture/data"
CONVERSE_TEST_COMMAND=isolated-fixture CONVERSE_DATA_DIR="$fixture/data" "$CONVERSE_MAC_APP/Contents/MacOS/Converse" --ipad-home-fixture > "$fixture/home.log" 2>&1 &
fixture_pid=$!
cleanup() { touch "$fixture/data/stop"; wait "$fixture_pid" || true; }
trap cleanup EXIT INT TERM
for attempt in {1..200}; do
    if [[ -s "$fixture/data/port" ]]; then break; fi
    sleep 0.05
done
if [[ ! -s "$fixture/data/port" ]]; then cat "$fixture/home.log"; exit 1; fi
CONVERSE_MAC_INTEROP_PORT=$(cat "$fixture/data/port") "${DOTNET_COMMAND:-dotnet}" run --project windows/src/Converse.Core.Tests
