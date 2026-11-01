#!/usr/bin/env bash
# Foreground demo home: never controls the installed production user service.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-serve}"
case "$mode" in
  serve|offline-status|preflight|admin-request|secret-stdin|--version|--about) ;;
  *) echo 'Demo supports foreground serve, status and admin commands; no service installation.' >&2; exit 64;;
esac
export CONVERSE_DEMO=1
export CONVERSE_LINUX_HOME="${CONVERSE_DEMO_HOME:-$HOME/.local/share/converse-demo-home}"
export CONVERSE_DEVICE_NAME="Converse Demo · $(hostname)"
export CONVERSE_LINUX_PORT=0
export CONVERSE_LINUX_SUPERVISOR=none
exec "$root/converse" "$@"
