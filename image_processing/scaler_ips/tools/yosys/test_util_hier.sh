#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test_util_hier.sh - regression test for tools/yosys/util_hier.awk
#
# Runs the utilization formatter on real Yosys "stat" reports and compares the
# output with the stored expected tables, once for every awk implementation
# found on this machine (awk, gawk, mawk, original-awk / BWK awk as shipped
# with macOS, busybox awk). The fixtures cover both report layouts:
#   yosys033_*  old layout   (Yosys 0.33: "FDCE    154")
#   yosys069_*  new layout   (Yosys 0.69: "154   FDCE" plus banner lines)
# It also checks that an unrecognised report makes the script fail loudly
# instead of printing a table of zeros.
#
# Usage: tools/yosys/test_util_hier.sh          exit status 0 = all passed
#        AWKS="gawk mawk" tools/yosys/test_util_hier.sh   (choose awks)
# Works with bash 3.2 (macOS) and later. To refresh the expected files after an
# intentional format change, delete them and run:  tools/yosys/test_util_hier.sh -update
# -----------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWKFILE="$HERE/util_hier.awk"
FIX="$HERE/test"
UPDATE=0; [ "${1:-}" = "-update" ] && UPDATE=1

# candidate awk programs; "busybox awk" needs two words, so keep them as strings
CANDIDATES=${AWKS:-"awk gawk mawk original-awk nawk busybox"}
found=()
for a in $CANDIDATES; do
  if [ "$a" = busybox ]; then
    command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{exit 0}' >/dev/null 2>&1 && found+=("busybox awk")
  else
    command -v "$a" >/dev/null 2>&1 && found+=("$a")
  fi
done
[ ${#found[@]} -gt 0 ] || { echo "test_util_hier: no awk found" >&2; exit 2; }

fail=0; n=0
for rpt in "$FIX"/*.rpt; do
  base="${rpt%.rpt}"
  top="$(basename "$base" | sed 's/^yosys[0-9]*_//')"
  if [ $UPDATE = 1 ] || [ ! -f "$base.expected" ]; then
    awk -f "$AWKFILE" -v top="$top" "$rpt" > "$base.expected" && echo "updated $(basename "$base").expected"
    continue
  fi
  for a in "${found[@]}"; do
    n=$((n + 1))
    # word splitting of $a is intentional ("busybox awk")
    if $a -f "$AWKFILE" -v top="$top" "$rpt" 2>/dev/null | cmp -s - "$base.expected"; then
      printf "  ok    %-14s %s\n" "$a" "$(basename "$rpt")"
    else
      printf "  FAIL  %-14s %s\n" "$a" "$(basename "$rpt")"; fail=$((fail + 1))
    fi
  done
done

# negative test: garbage input must produce an error, not zeros
for a in "${found[@]}"; do
  n=$((n + 1))
  out="$(printf '=== top ===\n\n   Number of cells:      3\n     something odd here\n' | $a -f "$AWKFILE" -v top=top 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q "unsupported"; then
    printf "  ok    %-14s unrecognised report is rejected\n" "$a"
  else
    printf "  FAIL  %-14s unrecognised report was NOT rejected (rc=%s)\n" "$a" "$rc"; fail=$((fail + 1))
  fi
done

echo "test_util_hier: $((n - fail))/$n passed (${#found[@]} awk implementation(s): ${found[*]})"
[ $fail -eq 0 ]
