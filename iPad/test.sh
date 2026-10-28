#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
simulator="${CONVERSE_IPAD_SIMULATOR:-$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for group in d["devices"].values() for x in group if "iPad Pro 13" in x["name"]),""))')}"
if [[ -z "$simulator" ]]; then print -u2 'Create an iPad simulator in Xcode first, or set CONVERSE_IPAD_SIMULATOR.'; exit 2; fi
if ! xcrun simctl list devices booted | rg -q "$simulator"; then xcrun simctl boot "$simulator"; fi
xcrun simctl bootstatus "$simulator" -b
interop_port=0
fixture=""
fixture_pid=""
cleanup() {
    if [[ -n "$fixture" ]]; then touch "$fixture/data/stop"; fi
    if [[ -n "$fixture_pid" ]]; then wait "$fixture_pid" || true; fi
}
trap cleanup EXIT INT TERM
if [[ "${1:-}" == --interop ]]; then
    app="${CONVERSE_APP_OUTPUT:-$PWD/.build/PinAndHelp/Converse.app}"
    if [[ ! -x "$app/Contents/MacOS/Converse" ]]; then print -u2 'Build the isolated Mac app first. Set CONVERSE_APP_OUTPUT to its bundle.'; exit 2; fi
    fixture=$(mktemp -d /tmp/converse-ipad-interop.XXXXXX)
    mkdir -p "$fixture/data"
    CONVERSE_TEST_COMMAND=isolated-fixture CONVERSE_DATA_DIR="$fixture/data" "$app/Contents/MacOS/Converse" --ipad-home-fixture > "$fixture/home.log" 2>&1 &
    fixture_pid=$!
    for attempt in {1..200}; do
        if [[ -s "$fixture/data/port" ]]; then interop_port=$(cat "$fixture/data/port"); break; fi
        if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$fixture/home.log"; exit 1; fi
        sleep 0.05
    done
    if [[ "$interop_port" == 0 ]]; then print -u2 'Isolated Mac home did not open its test port.'; exit 1; fi
    print "Isolated Mac home evidence: $fixture"
fi
TEST_RUNNER_CONVERSE_INTEROP_PORT="$interop_port" TEST_RUNNER_CONVERSE_TEST_COMMAND=isolated-tests xcodebuild -project iPad/Converse.xcodeproj -scheme Converse \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath .build/iPad CODE_SIGN_IDENTITY=- \
    CONVERSE_INTEROP_PORT="$interop_port" test
