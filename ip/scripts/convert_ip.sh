#!/usr/bin/env bash
# ***************
# Filename: convert_ip.sh
# Author: FPGA Cores 4 U
# Description: Moves one IP (or design) to SystemVerilog interfaces:
#   1. for each register map src/include/*_regs.json with a generated top,
#      annotates the logic's cfg_* / sts_* ports as <name>_if.core (regs);
#   2. regmap_gen.py writes <name>_if.sv, <name>_pkg.sv and the register block;
#   3. sv_ifconv.py converts src/*.sv, src/include/*_regs.sv and tb/*.sv
#      (annotated port groups -> interface ports, parents / testbenches);
#   4. regmap_gen.py again writes the top (u_regs + u_core via the interface);
#   5. buildf_ifaces.py adds the interface files to scripts/build.f and
#      tb/scripts/build.f.
#   It stops at the first error. Run the IP's tests afterwards (make test).
#   Usage: ip/scripts/convert_ip.sh <ip or design directory>
# Date: 2026-10-16
set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$(cd "$1" && pwd)"
shopt -s nullglob
for J in "$D"/src/include/*_regs.json; do
  read -r CORE CORE_FILE TOP NAME < <(python3 - "$J" <<'EOF'
import json, os, sys
j = sys.argv[1]; m = json.load(open(j))
core = m.get("core", m.get("ip", m["name"]))
src = os.path.dirname(os.path.dirname(j))
cp = os.path.normpath(os.path.join(os.path.dirname(j), m["core_file"])) if m.get("core_file") else os.path.join(src, core + ".sv")
print(core, cp, m.get("top", m.get("ip", m["name"]) + "_top") or "-", m["name"])
EOF
)
  if [ "$TOP" != "False" ] && [ "$TOP" != "-" ] && [ -f "$CORE_FILE" ] && grep -q '\bcfg_\w\+' "$CORE_FILE"; then
    python3 "$S/sv_annotate.py" "$CORE_FILE" "$CORE" regs "${NAME}_if.core" --same --if-file "src/include/${NAME}_if.sv" || true
  fi
  python3 "$S/regmap_gen.py" "$J" | sed 's/^/  /'
done
FILES=("$D"/src/*.sv "$D"/src/include/*_regs.sv "$D"/tb/*.sv)
python3 "$S/sv_ifconv.py" "${FILES[@]}"
for J in "$D"/src/include/*_regs.json; do python3 "$S/regmap_gen.py" "$J" | sed 's/^/  /'; done
BF=("$D"/scripts/build.f "$D"/tb/scripts/build.f)
python3 "$S/buildf_ifaces.py" "${BF[@]}" || true
# the logic's register ports must all be interface members
for J in "$D"/src/include/*_regs.json; do
  N="$(basename "$J" .json)"
  if [ -f "$D/src/include/${N}_if.sv" ]; then
    LEFT="$(grep -l "^\s*input\s\+logic.*\bcfg_\w\+\|^\s*output\s\+logic.*\bsts_\w\+" "$D"/src/*.sv 2>/dev/null | xargs grep -L "module ${N}\b" 2>/dev/null || true)"
    [ -z "$LEFT" ] || echo "  note: discrete cfg_/sts_ ports left in: $LEFT"
  fi
done
echo "convert_ip: $(basename "$D") done"
