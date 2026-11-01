#!/bin/zsh
# Build paired production/demo artifacts from one checkout and VERSION.json.
set -euo pipefail
cd "${0:A:h}/.."
version=$(python3 -c 'import json;print(json.load(open("VERSION.json"))["build"])')
root="$PWD/.build/round$version"
mkdir -p "$root"
case "${1:-mac}" in
 mac)
  CONVERSE_APP_OUTPUT="$root/Converse.app" CONVERSE_ARCHS='arm64 x86_64' ./build.sh
  ./scripts/make-mac-demo.sh "$root/Converse.app" "$root/Converse Demo.app"
  ;;
 ios)
  for edition in production demo; do
    extra=()
    if [[ "$edition" == demo ]]; then extra=(CONVERSE_DEMO=1 PRODUCT_BUNDLE_IDENTIFIER=app.kaoslabs.Converse.Demo); fi
    xcodebuild -project iPad/Converse.xcodeproj -scheme Converse -configuration Release -destination 'generic/platform=iOS' -archivePath "$root/iOS-$edition.xcarchive" -derivedDataPath "$root/iOS-$edition" "${extra[@]}" CODE_SIGNING_ALLOWED=NO archive
  done
  ;;
 linux)
  for rid in linux-x64 linux-arm64; do
    ./linux/build.sh "$rid"
    mkdir -p "$root/$rid" "$root/$rid-demo"
    cp .build/linux/$rid/* "$root/$rid/"
    cp .build/linux/$rid/* "$root/$rid-demo/"
    cp linux/demo.sh "$root/$rid-demo/converse-demo"
  done
  ;;
 *) print -u2 'Use mac, ios or linux. Windows: windows/build-round.ps1'; exit 64;;
esac
