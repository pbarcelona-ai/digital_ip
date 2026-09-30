#!/usr/bin/env bash
# ***************
# Filename: lib.sh
# Author: Paul Barcelona
# Description: Shared shell helpers - resolve an IP name from ips.csv
#   and expand its build.f into a file list.
# Date: 2026-09-29
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# lookup <ip>  -> sets CAT TOP TB ; exits when the IP is unknown
lookup() {
  local line
  line="$(grep -E "^$1," "$SCRIPT_DIR/ips.csv" || true)"
  [ -n "$line" ] || { echo "unknown IP '$1' (see scripts/ips.csv)"; exit 2; }
  IFS=, read -r _ CAT TOP <<< "$line"; TB="$1_tb"
  IPDIR="$REPO/$CAT/$1"
}

# filelist <ip> [manifest] -> absolute paths from a manifest relative to IPDIR.
# Supports comments; simulator directives are handled by the caller if needed.
filelist() {
  local line manifest="${2:-scripts/build.f}"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%//*}"; line="$(echo "$line" | xargs || true)"
    [ -z "$line" ] && continue
    case "$line" in +*) continue ;; esac
    echo "$IPDIR/$line"
  done < "$IPDIR/$manifest"
}
