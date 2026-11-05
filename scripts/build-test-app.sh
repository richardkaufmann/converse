#!/bin/zsh
# Build and install the developer's persistent, isolated Mac TEST edition.
set -euo pipefail
cd "${0:A:h:h}"
provider="${1:-Codex}"
case "$provider" in Codex|Claude|Muse) ;; *) print -u2 'Usage: scripts/build-test-app.sh Codex|Claude|Muse'; exit 2;; esac
source ./signing.sh
name="$provider Converse TEST"
source_app="$PWD/.build/$name.app"
destination="$HOME/Applications/$name.app"
# Never replace a running TEST app; its imports and account stores persist.
converse_require_stopped_app "$destination"
CONVERSE_TEST_PROVIDER="$provider" CONVERSE_APP_OUTPUT="$source_app" ./build.sh
codesign --verify --deep --strict "$source_app"
converse_require_stopped_app "$destination"
mkdir -p "$HOME/Applications"
stage=$(mktemp -d "$HOME/Applications/.converse-test.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr "$source_app" "$stage/$name.app"
codesign --verify --deep --strict "$stage/$name.app"
# Keep the previous TEST bundle for recovery, never a production bundle.
if [[ -e "$destination" ]]; then
  old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  [[ "$old_id" == "local.richard.Converse.Test.$provider" ]] || { print -u2 'Destination is not this provider’s TEST app; nothing replaced'; exit 2; }
  backup="$HOME/Library/Application Support/$name Builds"
  mkdir -p "$backup"
  previous=$(mktemp -d "$backup/previous.XXXXXXXX")
  mv "$destination" "$previous/$name.app"
fi
if ! mv "$stage/$name.app" "$destination"; then
  [[ -z "${previous:-}" ]] || mv "$previous/$name.app" "$destination"
  exit 1
fi
codesign --verify --deep --strict "$destination"
print -r -- "Installed $destination"
print -r -- "Profile: ~/Library/Application Support/$name"
print -r -- 'Use Reset TEST… in this app to restart NUX; normal launches preserve imports.'
