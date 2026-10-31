#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

rid="${1:-linux-x64}"
case "$rid" in
  linux-x64|linux-arm64) ;;
  *)
    echo "usage: ./linux/build.sh [linux-x64|linux-arm64]" >&2
    exit 64
    ;;
esac

if command -v dotnet >/dev/null 2>&1; then
  dotnet_bin="dotnet"
elif [[ -x "$HOME/.dotnet/dotnet" ]]; then
  dotnet_bin="$HOME/.dotnet/dotnet"
else
  echo "dotnet 8 SDK not found" >&2
  exit 1
fi

read -r product_version product_build < <(
  python3 -c 'import json; data=json.load(open("VERSION.json")); print(data["version"], data["build"])'
)
source_commit="$(git rev-parse HEAD 2>/dev/null || true)"
output=".build/linux/$rid"
rm -rf "$output"
mkdir -p "$output"

publish_dir=".build/linux/publish-$rid"
rm -rf "$publish_dir"
"$dotnet_bin" publish linux/src/Converse.Linux/Converse.Linux.csproj \
  -c Release \
  -r "$rid" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DebugType=None \
  -p:Version="$product_version" \
  -p:InformationalVersion="$product_version+$product_build" \
  -p:ConverseSourceCommit="$source_commit" \
  -o "$publish_dir"

install -m 700 "$publish_dir/Converse.Linux" "$output/converse"
# Keep the established bundle file allowlist compatible with installed updaters.
# Both notices travel in LICENSE; the GPL text itself remains unchanged.
cat LICENSING.md LICENSE > "$output/LICENSE"
cp VERSION.json "$output/"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$output/converse"
else
  shasum -a 256 "$output/converse"
fi
printf 'Built %s (source %s)\n' "$output/converse" "${source_commit:-unknown}"
