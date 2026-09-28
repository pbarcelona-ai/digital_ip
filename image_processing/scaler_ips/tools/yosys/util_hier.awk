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
#   Parameterised module names ($paramod<hash>\name) are shortened to the
#   module name; different parameterisations get a #n suffix.
#
#   Two report layouts are understood (they differ by Yosys version):
#     old (Yosys 0.33):    "     FDCE                          154"
#     new (Yosys 0.69):    "      154   FDCE"   (count first, plus banner
#                          lines such as "+----Local Count ..." and
#                          "168 cells" / "1 submodules" summary lines)
#   The script prints an error and exits with status 1 when the top module
#   has no recognisable cell lines at all, so an unsupported report format
#   can never produce a silent table of zeros.
#
#   Portability: strictly POSIX awk. Tested with gawk, mawk, BWK one-true-awk
#   (the awk shipped with macOS, version 20200816) and busybox awk. It avoids
#   printf "%*s", "delete array", local arrays in recursion and gawk-only
#   functions.
#   Usage: awk -f util_hier.awk -v top=<top> utilization.rpt
# Date: 2026-09-28

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

# summary words of the new layout that look like "<count> <word>"
function is_summary_word(w) {
  return (w == "wires" || w == "ports" || w == "cells" || w == "submodules" || \
          w == "memories" || w == "processes")
}

function is_num(s) { return (s ~ /^[0-9]+$/) }

function spaces(n,   s) {
  s = ""
  while (n-- > 0) s = s " "
  return s
}

# module name without the $paramod<hash>\ prefix; #n distinguishes variants
function short(m,   n) {
  if (m in shortname) return shortname[m]
  n = m
  if (m ~ /^\$paramod/) {
    sub(/^.*\\/, "", n)
    base_cnt[n]++
    if (base_cnt[n] > 1) n = n "#" base_cnt[n]
  }
  shortname[m] = n
  return n
}

BEGIN {
  ncats = split("LUT LUTRAM FF CARRY MUXF BRAM36 DSP", cats, " ")
  nmods = 0
}

# "=== design hierarchy ===" (both layouts) repeats the counts; skip it
/^=== design hierarchy ===/ { in_mod = 0; next }

/^=== .* ===$/ {
  mod = $0
  sub(/^=== /, "", mod)
  sub(/ ===$/, "", mod)
  mods[mod] = 1
  order[++nmods] = mod
  in_mod = 1
  next
}

# cell lines: exactly two fields, one numeric and one not
in_mod && NF == 2 {
  if (is_num($2) && !is_num($1) && $1 != "-") {                     # old: TYPE COUNT
    t = $1; c = $2 + 0
  } else if (is_num($1) && !is_num($2) && !is_summary_word($2)) {   # new: COUNT TYPE
    t = $2; c = $1 + 0
  } else {
    next
  }
  if (!((mod, t) in cells)) {
    ntype[mod]++
    type_at[mod, ntype[mod]] = t
  }
  cells[mod, t] += c
  ncell_lines[mod]++
  next
}

# total of one resource category for module m including everything below it
function total(m, k,   s, i, t) {
  if ((m, k) in memo) return memo[m, k]
  s = self[m, k]
  for (i = 1; i <= ntype[m]; i++) {
    t = type_at[m, i]
    if (t in mods) s += cells[m, t] * total(t, k)
  }
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

function walk(m, depth, count,   i, t, label, haschild, pad) {
  pad = spaces(2 * depth)
  label = pad short(m) ((count > 1) ? sprintf(" (x%d)", count) : "")
  row(label, m, "total")
  haschild = 0
  for (i = 1; i <= ntype[m]; i++) if (type_at[m, i] in mods) haschild = 1
  if (haschild) row(pad "  (self)", m, "self")
  for (i = 1; i <= ntype[m]; i++) {
    t = type_at[m, i]
    if (t in mods) walk(t, depth + 1, cells[m, t])
  }
}

END {
  # own resources of each module by category (sub-module instances excluded)
  for (i = 1; i <= nmods; i++) {
    m = order[i]
    for (j = 1; j <= ntype[m]; j++) {
      t = type_at[m, j]
      if (t in mods) continue
      k = cat_of(t)
      if (k == "BRAM18") { self[m, "BRAM36"] += cells[m, t] / 2; continue }
      self[m, k] += cells[m, t]
    }
  }
  if (!(top in mods)) {
    print "util_hier.awk: top module " top " not found in report" > "/dev/stderr"
    exit 1
  }
  if (ncell_lines[top] == 0) {
    print "util_hier.awk: no cell lines recognised for " top " - unsupported Yosys stat layout?" > "/dev/stderr"
    exit 1
  }
  hdr = sprintf("%-46s", "Instance")
  for (k = 1; k <= ncats; k++) hdr = hdr sprintf(" %8s", cats[k])
  print "Hierarchical utilization (Yosys synth_xilinx, totals include sub-instances)"
  print ""
  print hdr
  line = ""
  for (n = 1; n <= length(hdr); n++) line = line "-"
  print line
  walk(top, 0, 1)
  print ""
  print "LUT = LUT1..LUT6 used as logic; LUTRAM = distributed RAM + SRL; BRAM36 counts"
  print "RAMB36 as 1 and RAMB18 as 0.5. Yosys does not place or route, so these are"
  print "pre-implementation estimates (Vivado will typically optimise further)."
}
