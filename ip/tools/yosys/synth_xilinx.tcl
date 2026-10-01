# ***************
# Filename: synth_xilinx.tcl
# Author: FPGA Cores 4 U
# Description: Common Yosys synthesis script for every module of the scaler IP
#   family (run by <module>/synth.sh via  yosys -c synth_xilinx.tcl).
#   Targets Xilinx 7-series (default) with hierarchy preserved, so the
#   utilization can be reported per module.
#
#   Inputs (environment variables, set by synth.sh):
#     SYN_TOP     top-level module name
#     SYN_SRC     Verilog-2005 source produced by sv2v from src/build.f
#     SYN_OUT     output directory (<module>/yosys)
#     SYN_PARAMS  top-level parameter overrides, "NAME=VALUE NAME=VALUE ..."
#     SYN_FAMILY  synth_xilinx family (default xc7; e.g. xcup for UltraScale+)
#     SYN_FLAGS   extra synth_xilinx options (e.g. -nodsp, -nobram, -abc9)
#     SYN_JSON    1 = also write the netlist as JSON
#     SYN_SRL     1 = allow shift-register (SRL16E/SRLC32E) inference.
#                 Default 0 (-nosrl): Yosys 0.33's xilinx_srl pass was found
#                 to drop the clock enable of an enabled delay line in
#                 sharpen_cas (gate-level simulation mismatch under output
#                 back-pressure). Re-enable only with a Yosys version whose
#                 netlists pass tools/gatesim.sh.
#     SYN_DSP_PACK 1 = run Yosys's xilinx_dsp pass, which absorbs registers,
#                 post-adders and cascades into the DSP48s. Default 0: each
#                 multiplier is still mapped to its own DSP48 (same DSP
#                 count), but the surrounding registers and adders stay in
#                 the fabric. Yosys 0.33's xilinx_dsp was found to produce
#                 netlists that are not equivalent to the RTL for the
#                 pipelined polyphase filters (gate-level mismatch, with
#                 both Xilinx's UNISIM and Yosys's own DSP48E1 model).
#                 Re-enable only with a Yosys version whose netlists pass
#                 tools/gatesim.sh.
#     SYN_IOPAD   1 = insert I/O and clock buffers (default 0: out-of-context
#                 IP synthesis, no IBUF/OBUF/BUFG)
#
#   Steps
#     1. read      Xilinx cell library + design sources
#     2. elaborate hierarchy with top parameters, process always blocks
#     3. compile   generic RTL optimisation (opt, fsm, wreduce, ...)
#     4. DSP       pack multipliers / pre-adders / accumulators into DSP48
#     5. optimize  coarse-grain optimisation (alumacc, share, opt)
#     6. memory    map memories to block RAM, then LUT RAM, then flip-flops
#     7. map       fine optimisation and mapping to LUTs, carry chains,
#                  flip-flops, wide muxes
#     8. check     final design checks
#     9. report    per-module utilization (Yosys stat) and netlists
#    10. timing    rough path-delay indicator (Yosys sta; see limitations)
# Date: 2026-09-26

yosys -import

proc envdef {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $default
}

set top    [envdef SYN_TOP ""]
set src    [envdef SYN_SRC ""]
set out    [envdef SYN_OUT "."]
set params [envdef SYN_PARAMS ""]
set family [envdef SYN_FAMILY "xc7"]
set flags  [envdef SYN_FLAGS ""]
if {[envdef SYN_IOPAD 0] ne "1"} { append flags " -noiopad -noclkbuf" }
if {[envdef SYN_SRL 0] ne "1"}   { append flags " -nosrl" }
if {$top eq "" || $src eq ""} { error "SYN_TOP and SYN_SRC must be set" }

# synth_xilinx stage runner: executes the labelled section [from, to)
proc stage {title from to} {
  global top family flags
  log -header $title
  log -push
  eval synth_xilinx -family $family -top $top {*}$flags -run $from:$to
  log -pop
}

# ---------------------------------------------------------------- 1. read
log -header "Read sources"
read_verilog -lib -specify +/xilinx/cells_sim.v
read_verilog -lib +/xilinx/cells_xtra.v
read_verilog -defer $src

# ---------------------------------------------------------------- 2. elaborate
log -header "Elaborate $top $params"
# parameters are applied with "chparam -set" before elaboration (equivalent
# to "hierarchy -chparam", which trips an internal assertion in Yosys 0.33
# for some tops)
set chparams {}
foreach p $params {
  set kv [split $p "="]
  lappend chparams -set [lindex $kv 0] [lindex $kv 1]
}
if {[llength $chparams] > 0} { eval chparam {*}$chparams $top }
hierarchy -check -top $top

# ---------------------------------------------------------------- 3-8. synthesis
stage "Compile (generic RTL optimisation)"          prepare    map_dsp
# With -nosrl, synth_xilinx (0.33) also skips pmux2shiftx, which roughly
# doubles the LUTs of wide selection muxes (e.g. the banked frame buffer's
# tap multiplexer). Run it explicitly so -nosrl only disables SRL inference.
if {[lsearch -exact $flags "-nosrl"] >= 0 && [string first "-widemux" $flags] < 0} {
  log -header "pmux2shiftx (normally skipped with -nosrl)"
  pmux2shiftx
  clean
}
if {[envdef SYN_DSP_PACK 0] eq "1" || [lsearch -exact $flags "-nodsp"] >= 0} {
  stage "Map multipliers to DSP48 blocks (with xilinx_dsp packing)" map_dsp coarse
} else {
  # map_dsp without the xilinx_dsp packing pass (see SYN_DSP_PACK above)
  log -header "Map multipliers to DSP48 blocks (no register/adder packing)"
  log -push
  set dspmap [dict create \
    xc7  {xc7_dsp_map.v -D DSP_A_MAXWIDTH=25 -D DSP_B_MAXWIDTH=18 -D DSP_A_MAXWIDTH_PARTIAL=18 -D DSP_NAME=$__MUL25X18} \
    xcu  {xcu_dsp_map.v -D DSP_A_MAXWIDTH=27 -D DSP_B_MAXWIDTH=18 -D DSP_A_MAXWIDTH_PARTIAL=18 -D DSP_NAME=$__MUL27X18} \
    xcup {xcu_dsp_map.v -D DSP_A_MAXWIDTH=27 -D DSP_B_MAXWIDTH=18 -D DSP_A_MAXWIDTH_PARTIAL=18 -D DSP_NAME=$__MUL27X18}]
  if {![dict exists $dspmap $family]} {
    error "DSP mapping without packing is set up for xc7/xcu/xcup; use SYN_DSP_PACK=1 for $family"
  }
  set m [dict get $dspmap $family]
  memory_dff
  techmap -map +/mul2dsp.v -map +/xilinx/[lindex $m 0] {*}[lrange $m 1 end] \
    -D DSP_A_MINWIDTH=2 -D DSP_B_MINWIDTH=2 -D DSP_Y_MINWIDTH=9 -D DSP_SIGNEDONLY=1
  select a:mul2dsp
  setattr -unset mul2dsp
  opt_expr -fine
  wreduce
  select -clear
  chtype -set {$mul} {t:$__soft_mul}
  log -pop
}
stage "Optimize (coarse grain)"                     coarse     map_memory
stage "Map memories to block RAM / LUT RAM"         map_memory fine
stage "Map to LUTs, carry chains and flip-flops"    fine       check
stage "Final checks"                                check      edif

# ---------------------------------------------------------------- 9. reports
log -header "Reports"
tee -q -o $out/utilization.rpt stat -tech xilinx -top $top
write_verilog -noattr $out/${top}_netlist.v
write_edif -top $top $out/${top}.edf
if {[envdef SYN_JSON 0] eq "1"} { write_json $out/${top}.json }

# ---------------------------------------------------------------- 10. timing
# Rough static-timing indicator (Yosys "sta") using the cell delays in the
# specify blocks of the Xilinx cell library (LUTs, flip-flops, DSP48E1).
# Limitations, so treat timing.rpt as indicative only, not as an Fmax:
#   * no routing delay;
#   * CARRY4 and MUXF7/F8 have no timing arcs in the Yosys 0.33 library, so
#     carry chains and wide muxes count as zero delay;
#   * no clock constraints: the reported longest path may start at a
#     primary input such as the asynchronous reset.
# Use Vivado (the .edf netlist) for real timing. The design is flattened
# first, after the hierarchical reports and netlists have been written.
log -header "Timing estimate (cell delays only)"
flatten
tee -q -o $out/timing.rpt sta
