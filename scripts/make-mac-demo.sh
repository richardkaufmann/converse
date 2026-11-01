#!/bin/zsh
# Same executable and Help; distinct signed identity, credentials and profile.
set -euo pipefail
cd "${0:A:h}/.."
source ./signing.sh
source_app="${1:A}"
demo_app="${2:A}"
[[ "$source_app" != "$demo_app" ]] || exit 2
converse_require_stopped_app "$demo_app"
[[ ! -e "$demo_app" ]] || { print -u2 'Demo destination exists; choose a fresh build path.'; exit 2; }
codesign --verify --deep --strict "$source_app"
ditto "$source_app" "$demo_app"
plist="$demo_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.richard.Converse.Demo' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Converse Demo' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Converse Demo' "$plist"
/usr/libexec/PlistBuddy -c 'Add :ConverseNUXPreview bool true' "$plist"
/usr/libexec/PlistBuddy -c 'Add :ConverseDemo bool true' "$plist"
identity=$(converse_signing_identity)
args=()
if [[ "$identity" != - ]]; then args=(--options runtime --timestamp); fi
codesign --force --entitlements Resources/Converse.entitlements "${args[@]}" --sign "$identity" "$demo_app"
codesign --verify --deep --strict "$demo_app"
