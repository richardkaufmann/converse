#!/bin/zsh
set -eu
cd "${0:A:h}"
CONVERSE_ARCHS='arm64 x86_64' ./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Converse.app/Contents/Info.plist)
release_root=".build/release"
staging=$(mktemp -d "${TMPDIR:-/tmp}/converse-release.XXXXXX")
mkdir -p "$release_root" "$staging/Converse"
ditto --norsrc --noextattr Converse.app "$staging/Converse/Converse.app"
cp README.txt "$staging/Converse/README.txt"
codesign --verify --deep --strict "$staging/Converse/Converse.app"
archive="$release_root/Converse-${version}-macOS-universal.zip"
ditto -c -k --norsrc --noextattr --keepParent "$staging/Converse" "$archive"
(cd "$release_root"; shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
printf 'Release: %s\n' "$archive"
