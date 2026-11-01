#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 Tests/linux_join_helper_test.py
python3 Tests/demo_launcher_test.py

if command -v dotnet >/dev/null 2>&1; then
  dotnet_bin="dotnet"
elif [[ -x "$HOME/.dotnet/dotnet" ]]; then
  dotnet_bin="$HOME/.dotnet/dotnet"
else
  echo "dotnet 8 SDK not found" >&2
  exit 1
fi

"$dotnet_bin" run --project linux/tests/Converse.Linux.Contract.Tests -c Release -- "$repo_root"
"$dotnet_bin" run --project linux/tests/Converse.Linux.Tests -c Release
"$dotnet_bin" run --project windows/src/Converse.Core.Tests -c Release
