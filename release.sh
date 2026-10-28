#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source ./signing.sh
skip_build=0
if [[ "${1:-}" == --skip-build && $# == 1 ]]; then
  skip_build=1
elif (( $# != 0 )); then
  print -u2 'Usage: ./release.sh [--skip-build]'
  exit 2
fi
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
app="${app:A}"
export CONVERSE_APP_OUTPUT="$app"
converse_require_stopped_app "$app"
if (( ! skip_build )); then
  signing_identity=$(converse_signing_identity)
  if [[ "$signing_identity" == - ]]; then
    print -u2 'A release requires a valid Developer ID Application identity. Use ./build.sh for a local ad-hoc build.'
    exit 1
  fi
  CONVERSE_SIGN_IDENTITY="$signing_identity" CONVERSE_ARCHS='arm64 x86_64' ./build.sh
fi
codesign --verify --deep --strict "$app"
signature=$(codesign --display --verbose=4 "$app" 2>&1)
if ! print -r -- "$signature" | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
  print -u2 'Release refused: the app is not Developer ID Application signed.'
  exit 1
fi
if ! print -r -- "$signature" | /usr/bin/grep -q 'flags=.*runtime'; then
  print -u2 'Release refused: hardened runtime is missing.'
  exit 1
fi
if ! print -r -- "$signature" | /usr/bin/grep -q '^Timestamp='; then
  print -u2 'Release refused: secure signing timestamp is missing.'
  exit 1
fi
architectures=" $(lipo -archs "$app/Contents/MacOS/Converse") "
if [[ "$architectures" != *' arm64 '* || "$architectures" != *' x86_64 '* ]]; then
  print -u2 'Release refused: both arm64 and x86_64 architectures are required.'
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
release_root=".build/release"
staging=$(mktemp -d "${TMPDIR:-/tmp}/converse-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$release_root" "$staging/Converse"
notary_profile="${CONVERSE_NOTARY_PROFILE:-ConverseNotary}"
if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
  ditto -c -k --keepParent "$app" "$staging/notarization.zip"
  result="$release_root/Converse-${version}-notarization.json"
  xcrun notarytool submit "$staging/notarization.zip" --keychain-profile "$notary_profile" --wait --output-format json > "$result"
  notary_status=$(/usr/bin/plutil -extract status raw -o - "$result")
  submission_id=$(/usr/bin/plutil -extract id raw -o - "$result")
  log="$release_root/Converse-${version}-notarization-log.json"
  xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" "$log"
  if [[ "$notary_status" != Accepted ]]; then
    print -u2 "Notarization was $notary_status. Review $log; no release ZIP was created."
    exit 1
  fi
  xcrun stapler staple "$app"
fi
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto "$app" "$staging/Converse/Converse.app"
cp README.txt LICENSE "$staging/Converse/"
codesign --verify --deep --strict "$staging/Converse/Converse.app"
xcrun stapler validate "$staging/Converse/Converse.app"
archive="$release_root/Converse-${version}-macOS-universal.zip"
ditto -c -k --keepParent "$staging/Converse" "$staging/release.zip"
mv "$staging/release.zip" "$archive"
(cd "$release_root"; shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
printf 'Release: %s\n' "$archive"
