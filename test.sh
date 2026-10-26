#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ ! -x Converse.app/Contents/MacOS/Converse ]]; then ./build.sh; fi
muse_path=$(command -v muse)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/converse-check.XXXXXX")
printf '#!/bin/zsh\nshift\nexec %q exec --provider echo --disable-reminders "$@"\n' "$muse_path" > "$test_dir/muse-echo"
chmod +x "$test_dir/muse-echo"
CONVERSE_DATA_DIR="$test_dir/data" CONVERSE_TEST_COMMAND="$test_dir/muse-echo" Converse.app/Contents/MacOS/Converse --self-test
printf 'Isolated test data: %s\n' "$test_dir"
