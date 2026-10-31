#!/usr/bin/env python3
# ***************
# Filename: test_cdc_check.py
# Author: FPGA Cores 4 U
# Description: Regression test of cdc_check.py: a two-clock design with an
#   unsynchronised crossing, a crossing through bit_sync (tagged cdc_sync),
#   a crossing between two outputs of one black-box oscillator (related),
#   the same between two bits of one oscillator's output bus (each bit its
#   own clock root, named with its index), a crossing into an inline
#   two-flop synchroniser marked async_reg (synchronised) and one whose first
#   stage has a synchronous reset of its own domain (no glitch warning),
#   a crossing into a register matched by --sync-inst, one out of a CDC
#   block's held data register (held), one into an
#   untagged bit_sync instance found by --sync-src, two registers mixed
#   ahead of a synchroniser (warning), a black box's output with and
#   without --bb-clock, and a waiver from a --waive-file;
#   Yosys builds its netlist. Checks each crossing's class, the exit status
#   (1 with the violation, 0 with it waived). Needs yosys.
# Date: 2026-10-27
# ***************
"""Usage: python3 ip/scripts/test_cdc_check.py (exit 0: PASS)"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DESIGN = r"""
(* blackbox *) module osc(output a_o, output b_o); endmodule
(* blackbox *) module tdc(input ck, output q); endmodule
(* blackbox *) module oscb(output [1:0] c_o); endmodule
module bit_sync(input clk, input d_i, output q_o);
  reg s1, s2;
  always @(posedge clk) begin s1 <= d_i; s2 <= s1; end
  assign q_o = s2;
endmodule
module hold_cdc(input clk, input d_i, output q_o);   // a CDC block's held data register (source side)
  reg data_q;
  always @(posedge clk) data_q <= d_i;
  assign q_o = data_q;
endmodule
module top(input clk_a, input clk_b, input din, input din2, output y_bad, output y_ok, output y_rel, output y_inl,
           output y_hld, output y_gl, output y_bb, output y_bus, output y_ar, output y_rs);
  reg ra, rb, x1, x2;
  reg u_cdc_cap;                                   // a register of an inlined CDC module (by its name)
  wire q, r1, r2;
  always @(posedge clk_a) ra <= din;
  always @(posedge clk_b) rb <= ra;                // unsynchronised
  always @(posedge clk_b) u_cdc_cap <= ra;         // matched by --sync-inst
  bit_sync u_s(.clk(clk_b), .d_i(ra), .q_o(q));
  osc u_osc(.a_o(r1), .b_o(r2));
  always @(posedge r1) x1 <= ~x1;
  always @(posedge r2) x2 <= x1;                   // related clocks
  wire hq;
  reg hd;
  hold_cdc u_hold(.clk(clk_a), .d_i(din), .q_o(hq));
  always @(posedge clk_b) hd <= hq;                // held data of a CDC block (by name)
  assign y_hld = hd;
  reg ga, gb;                                      // two registers mixed ahead of a synchroniser (glitch)
  wire gq;
  always @(posedge clk_a) begin ga <= din; gb <= din2; end
  bit_sync u_g(.clk(clk_b), .d_i(ga & gb), .q_o(gq));
  assign y_gl = gq;
  wire tq;                                         // a black box's output registered on its input clock
  reg td;
  tdc u_tdc(.ck(clk_a), .q(tq));
  always @(posedge clk_a) td <= tq;
  assign y_bb = td;
  assign y_bad = rb;
  assign y_ok = q;
  assign y_rel = x2;
  wire [1:0] cb;                                   // one oscillator, a bus of outputs
  reg x3, x4;
  oscb u_ob(.c_o(cb));
  always @(posedge cb[0]) x3 <= ~x3;
  always @(posedge cb[1]) x4 <= x3;               // related: bits 0 and 1 of the bus
  assign y_bus = x4;
  (* async_reg = "true" *) reg ar_s1, ar_s2;       // an inline synchroniser, marked
  always @(posedge clk_b) begin ar_s1 <= ra; ar_s2 <= ar_s1; end
  assign y_ar = ar_s2;
  reg rst_b;                                       // a reset of clk_b's domain
  always @(posedge clk_b) rst_b <= din2;
  (* async_reg = "true" *) reg rs_s1, rs_s2;       // first stage with a synchronous reset: not a glitch
  always @(posedge clk_b) if (rst_b) begin rs_s1 <= 1'b0; rs_s2 <= 1'b0; end else begin rs_s1 <= ra; rs_s2 <= rs_s1; end
  assign y_rs = rs_s2;
  assign y_inl = u_cdc_cap;
endmodule
"""


def run(json_path, *extra):
    p = subprocess.run([sys.executable, str(HERE / "cdc_check.py"), str(json_path), "--sync-inst", r"(^|\.)u_cdc_",
                        "--sync-inst", r"(^|\.)u_hold\.", *extra], capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    with tempfile.TemporaryDirectory() as td:
        v, js = Path(td) / "t.v", Path(td) / "t.json"
        v.write_text(DESIGN, encoding="utf-8")
        subprocess.run(["yosys", "-q", "-p", f"read_verilog {v}; hierarchy -top top; proc; "
                        f"setattr -set cdc_sync 1 bit_sync/c:*; flatten; opt_clean; write_json {js}"], check=True)
        rc, out = run(js)
        sec = {}
        cur = None
        for ln in out.splitlines():
            if not ln.startswith("  ") and ":" in ln:
                cur = ln.split(":")[0]
                sec[cur] = []
            elif cur and ln.startswith("  "):
                sec[cur].append(ln.strip())
        errs = []
        if rc != 1:
            errs.append(f"exit status {rc} with a violation (1 expected)")
        if [v for v in sec.get("VIOLATIONS (unsynchronised crossings)", []) if "td.D" not in v] != ["ra [clk_a] -> rb.D [clk_b]"]:
            errs.append(f"violations {sec.get('VIOLATIONS (unsynchronised crossings)')}")
        if sorted(sec.get("Related clocks (same oscillator)", [])) != sorted(["x1 [r1] -> x2.D [r2]",
                                                                         "x3 [cb[0]] -> x4.D [cb[1]]"]):
            errs.append(f"related {sec.get('Related clocks (same oscillator)')}")
        sync = sec.get("Synchronised crossings", [])
        if sorted(x for x in sync if "u_g." not in x) != sorted(["ra [clk_a] -> u_s.s1.D [clk_b]", "ra [clk_a] -> u_cdc_cap.D [clk_b]",
                                                                "ra [clk_a] -> ar_s1.D [clk_b]",
                                                                "ra [clk_a] -> rs_s1.D [clk_b]"]):
            errs.append(f"synchronised {sync}")
        if sec.get("Held data of CDC blocks (handshake / FIFO memory)") != ["u_hold.data_q [clk_a] -> hd.D [clk_b]"]:
            errs.append(f"held {sec.get('Held data of CDC blocks (handshake / FIFO memory)')}")
        wl = sec.get("Warnings (logic before a synchroniser)", [])
        if not any("u_g.s1.D" in w and "mixing 2" in w for w in wl) or any("rs_s1" in w for w in wl):
            errs.append(f"glitch warning {wl}")
        if not any("-> td.D" in v for v in sec.get("VIOLATIONS (unsynchronised crossings)", [])):
            errs.append("black box without --bb-clock: not a crossing")
        wf = Path(td) / "waivers.txt"
        wf.write_text("-> rb\\.D   # rb is quasi-static (the test's reason)\n", encoding="utf-8")
        rc2, out2 = run(js, "--waive-file", str(wf), "--bb-clock", "tdc:q=ck")
        if rc2 != 0 or "(waived)" not in out2 or "the test's reason" not in out2:
            errs.append(f"waiver / --bb-clock: exit status {rc2}")
        # --sync-src: the same design without the cdc_sync tag, bit_sync in a file of its own (the top's instance
        # u_s found in the sources)
        lib, topf, js2, lst = (Path(td) / n for n in ("lib.v", "top.v", "t2.json", "files.txt"))
        lib.write_text(DESIGN[:DESIGN.index("module top")], encoding="utf-8")
        topf.write_text(DESIGN[DESIGN.index("module top"):], encoding="utf-8")
        lst.write_text(f"{lib}\n{topf}\n", encoding="utf-8")
        subprocess.run(["yosys", "-q", "-p", f"read_verilog {lib} {topf}; hierarchy -top top; proc; flatten; opt_clean; "
                        f"write_json {js2}"], check=True)
        rc3, out3 = run(js2, "--sync-src", str(lst), "--waive", r"-> rb\.D", "--bb-clock", "tdc:q=ck")
        if rc3 != 0 or "ra [clk_a] -> u_s.s1.D [clk_b]" not in out3.split("Synchronised crossings")[-1]:
            errs.append(f"--sync-src: exit status {rc3}")
    if errs:
        print("test_cdc_check: FAIL\n  " + "\n  ".join(errs))
        print(out)
        sys.exit(1)
    print("test_cdc_check: PASS (violation, related (also bits of one output bus), held, glitch warning, black-box "
          "clock, synchronised by module, by name, by async_reg and by source scan, waivers)")


if __name__ == "__main__":
    main()
