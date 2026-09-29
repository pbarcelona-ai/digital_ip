#!/usr/bin/env bash
# ***************
# Filename: run_checked.sh
# Author: Paul Barcelona
# Description: Runs a command and decides pass/fail from its OUTPUT, not
# just its exit status: the testbenches print PASS/FAIL markers but
# vvp exits 0 either way. Passes only if the command exits 0, the PASS
# regex appears in the log, and (optionally) the FAIL regex does not.
# Logs go to ci/logs/<name>.log for artifact upload.
# Date: September 26, 2026
# ***************
# Usage: ci/run_checked.sh <name> <pass-regex> <fail-regex|-> -- <command...>
set -uo pipefail
NAME="$1"; PASS_RE="$2"; FAIL_RE="$3"; shift 3
[ "$1" = "--" ] && shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/ci/logs"
LOG="$ROOT/ci/logs/$NAME.log"

echo "::group::$NAME"
"$@" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
echo "::endgroup::"

STATUS=0
if [ "$RC" -ne 0 ]; then echo "[$NAME] FAILED: command exited $RC"; STATUS=1; fi
if ! grep -Eq -- "$PASS_RE" "$LOG"; then echo "[$NAME] FAILED: pass marker /$PASS_RE/ not found"; STATUS=1; fi
if [ "$FAIL_RE" != "-" ] && grep -Eq -- "$FAIL_RE" "$LOG"; then
  echo "[$NAME] FAILED: fail marker /$FAIL_RE/ found:"; grep -En -- "$FAIL_RE" "$LOG" | head -5; STATUS=1
fi
[ "$STATUS" -eq 0 ] && echo "[$NAME] OK"
exit $STATUS
