#!/usr/bin/env bash
# ***************
# Filename: view_waves.sh
# Author: Paul Barcelona
# Description: Opens a VCD waveform file in the Surfer waveform viewer.
# Used by the run scripts when VCD=1 SURFER=1 are set, or directly.
# Falls back to printing install instructions if Surfer is missing.
# Date: September 26, 2026
# ***************
# Usage: view_waves.sh <file.vcd> [extra surfer args...]
set -euo pipefail

VCD="${1:-}"
if [ -z "$VCD" ] || [ ! -f "$VCD" ]; then
  echo "[view_waves] usage: $0 <file.vcd>   (file not found: '${VCD}')" >&2
  echo "[view_waves] generate one first, e.g.:  VCD=1 ./run.sh" >&2
  exit 2
fi
shift

if command -v surfer >/dev/null 2>&1; then
  echo "[view_waves] opening $VCD in Surfer"
  exec surfer "$VCD" "$@"
fi

cat >&2 << MSG
[view_waves] Surfer is not installed (or not on PATH). The VCD is here:
    $(cd "$(dirname "$VCD")" && pwd)/$(basename "$VCD")
Install Surfer (https://surfer-project.org):
  - prebuilt binary:  https://gitlab.com/surfer-project/surfer/-/releases
  - from source:      cargo install --git https://gitlab.com/surfer-project/surfer surfer
  - no install:       open the VCD in the browser version at https://app.surfer-project.org
Any other VCD viewer (e.g. GTKWave) also works with this file.
MSG
exit 1
