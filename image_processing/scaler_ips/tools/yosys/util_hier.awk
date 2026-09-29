# ***************
# Filename: util_hier.awk
# Author: Paul Barcelona
# Description: Converts the output of Yosys "stat -tech xilinx -top <top>"
#   (utilization.rpt) into a hierarchical utilization table: one row per
#   instance of the design tree with totals that include everything below it,
#   plus a "(self)" row for logic that belongs to the module itself.
#   Columns: LUT (LUT1..LUT6 as logic), LUTRAM (distributed RAM and shift
#   registers), FF (all flip-flops and latches), CARRY (CARRY4/CARRY8),
#   MUXF (MUXF7/F8/F9), BRAM36 (RAMB36 + RAMB18/2 in RAMB36 units), DSP.
#   Parameterised module names ($paramod$<hash>\name) are shortened to the
#   module name; different parameterisations get a #n suffix.
#   Usage: awk -f util_hier.awk -v top=<top> utilization.rpt
# Date: 2026-09-26

function cat_of(t) {
  if (t ~ /^LUT[1-6]$/)                         return "LUT"
  if (t ~ /^(RAM(16|32|64|128|256|512)X|RAM32M|RAM64M|RAMS|RAMD|SRL)/) return "LUTRAM"
  if (t ~ /^(FD|LD)/)                           return "FF"
  if (t ~ /^CARRY/)                             return "CARRY"
  if (t ~ /^MUXF/)                              return "MUXF"
  if (t ~ /^RAMB36/)                            return "BRAM36"
  if (t ~ /^RAMB18/)                            return "BRAM18"
  if (t ~ /^DSP48/)                             return "DSP"
  if (t ~ /^(IBUF|OBUF|IOBUF|BUFG|BUFGCTRL|IBUFG|OBUFT)/) return "IO"
  return "OTHER"
}
function short(m,   n, h) {
  if (m in shortname) return shortname[m]
  n = m; h = ""
  if (m ~ /^\$paramod/) {
    n = m; sub(/^.*\\/, "", n)
    base_cnt[n]++
    if (base_cnt[n] > 1) h = "#" base_cnt[n]
  }
  shortname[m] = n h
  return shortname[m]
}
BEGIN { ncats = split("LUT LUTRAM FF CARRY MUXF BRAM36 DSP", cats, " ") }
/^=== design hierarchy ===/ { in_mod = 0; next }
/^=== .* ===$/ {
  mod = $0; sub(/^=== /, "", mod); sub(/ ===$/, "", mod)
  mods[mod] = 1; order[++nmods] = mod; in_mod = 1; next
}
in_mod && /^     [^ ]+ +[0-9]+$/ {
  t = $1; c = $2
  cells[mod, t] += c
  types[mod] = types[mod] " " t
  next
}
function total(m, k,   s, i, n, t, arr) {
  if ((m, k) in memo) return memo[m, k]
  s = self[m, k]
  n = split(types[m], arr, " ")
  for (i = 1; i <= n; i++) {
    t = arr[i]
    if (t in mods && !seen[m, t]++) s += cells[m, t] * total(t, k)
  }
  delete seen
  memo[m, k] = s
  return s
}
function row(label, m, mode,   k, v, line) {
  line = sprintf("%-46s", label)
  for (k = 1; k <= ncats; k++) {
    v = ((mode == "self") ? self[m, cats[k]] : total(m, cats[k])) + 0
    line = line sprintf(" %8s", (cats[k] == "BRAM36") ? sprintf("%.1f", v) : v)
  }
  print line
}
function walk(m, depth, count,   arr, n, i, t, label, haschild, pad) {
  pad = sprintf("%*s", 2 * depth, "")
  label = pad short(m) ((count > 1) ? sprintf(" (x%d)", count) : "")
  row(label, m, "total")
  n = split(types[m], arr, " "); haschild = 0
  for (i = 1; i <= n; i++) if (arr[i] in mods) haschild = 1
  if (haschild) row(pad "  (self)", m, "self")
  for (i = 1; i <= n; i++) {
    t = arr[i]
    if (t in mods && !done[m, t]++) walk(t, depth + 1, cells[m, t])
  }
}
END {
  # per-module own resources by category
  for (i = 1; i <= nmods; i++) {
    m = order[i]; n = split(types[m], arr, " ")
    for (j = 1; j <= n; j++) {
      t = arr[j]; if (t in mods) continue
      if (seen2[m, t]++) continue
      k = cat_of(t)
      if (k == "BRAM18") { self[m, "BRAM36"] += cells[m, t] / 2; continue }
      self[m, k] += cells[m, t]
    }
  }
  delete seen2
  if (!(top in mods)) { print "top module " top " not found in report"; exit 1 }
  hdr = sprintf("%-46s", "Instance")
  for (k = 1; k <= ncats; k++) hdr = hdr sprintf(" %8s", cats[k])
  print "Hierarchical utilization (Yosys synth_xilinx, totals include sub-instances)"
  print ""
  print hdr
  gsub(/./, "-", hdr); print hdr
  walk(top, 0, 1)
  print ""
  print "LUT = LUT1..LUT6 used as logic; LUTRAM = distributed RAM + SRL; BRAM36 counts"
  print "RAMB36 as 1 and RAMB18 as 0.5. Yosys does not place or route, so these are"
  print "pre-implementation estimates (Vivado will typically optimise further)."
}
