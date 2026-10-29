#!/bin/zsh
set -eu
cd "${0:A:h}"
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
app="${app:A}"
export CONVERSE_APP_OUTPUT="$app"
if [[ ! -x "$app/Contents/MacOS/Converse" ]]; then ./build.sh; fi
muse_path=$(command -v muse)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/converse-check.XXXXXX")
printf '#!/bin/zsh\nshift\nexec %q exec --provider echo --disable-reminders "$@"\n' "$muse_path" > "$test_dir/muse-echo"
chmod +x "$test_dir/muse-echo"
test_mode=--self-test
if [[ "${1:-}" == --providers-only ]]; then test_mode=--provider-self-test; fi
CONVERSE_DATA_DIR="$test_dir/data" CONVERSE_TEST_COMMAND="$test_dir/muse-echo" "$app/Contents/MacOS/Converse" "$test_mode"
python3 Tests/install_shortcut_test.py
python3 Tests/help_content_test.py
python3 Tests/jolly_bridge_test.py
printf 'Isolated test data: %s\n' "$test_dir"
