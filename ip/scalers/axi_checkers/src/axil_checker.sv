// ***************
// Filename: axil_checker.sv
// Author: FPGA Cores 4 U
// Description: Passive AXI4-Lite protocol checker with functional coverage. Checks both
//   the master and the slave side of one AXI4-Lite link.
//
//   Checks (each violation increments `errors` and prints the rule id)
//     AXIL_X        valid signals never X/Z; payloads never X/Z while valid
//     AXIL_HOLD_*   AW/W/AR (master) and B/R (slave) valid stays asserted
//                   until the handshake
//     AXIL_STABLE_* payload (address / data / strobe / response) stable
//                   while valid && !ready
//     AXIL_BRESP_EARLY  B response without an accepted AW and W
//     AXIL_RRESP_EARLY  R response without an accepted AR
//     AXIL_RESP     BRESP/RRESP not OKAY (only if EXPECT_OKAY = 1)
//     AXIL_OUTSTANDING  more than MAX_OUTSTANDING transactions in flight
//
//   Procedural checks run on every simulator (incl. Icarus); SVA properties
//   for the handshake rules are compiled when `SVA_ON is defined.
//
//   Coverage: writes, reads, AW-before-W / W-before-AW / AW-with-W orderings,
//   B and R responses stalled by the master, AW/AR accepted immediately vs
//   after waiting, back-to-back writes/reads, simultaneous read and write.
// Date: 2026-09-26

`timescale 1ns/1ps
module axil_checker #(
  parameter int    ADDR_W          = 14,
  parameter string NAME            = "axil",
  parameter bit    EXPECT_OKAY     = 1'b1,
  parameter int    MAX_OUTSTANDING = 1
)(
  input logic              clk,
  input logic              rst_n,
  input logic [ADDR_W-1:0] awaddr,
  input logic              awvalid,
  input logic              awready,
  input logic [31:0]       wdata,
  input logic [3:0]        wstrb,
  input logic              wvalid,
  input logic              wready,
  input logic [1:0]        bresp,
  input logic              bvalid,
  input logic              bready,
  input logic [ADDR_W-1:0] araddr,
  input logic              arvalid,
  input logic              arready,
  input logic [31:0]       rdata,
  input logic [1:0]        rresp,
  input logic              rvalid,
  input logic              rready
);

  int errors     = 0;      // procedural rule violations
  int sva_errors = 0;      // SVA violations (only with `SVA_ON)

  int cov_writes = 0, cov_reads = 0;
  int cov_aw_first = 0, cov_w_first = 0, cov_aw_w_same = 0;
  int cov_b_stall = 0, cov_r_stall = 0, cov_aw_wait = 0, cov_ar_wait = 0;
  int cov_b2b_wr = 0, cov_b2b_rd = 0, cov_rw_overlap = 0;

  // previous-cycle samples
  logic              p_awv = 0, p_awr = 0, p_wv = 0, p_wr = 0, p_bv = 0, p_br = 0;
  logic              p_arv = 0, p_arr = 0, p_rv = 0, p_rr = 0;
  logic [ADDR_W-1:0] p_awaddr, p_araddr;
  logic [31:0]       p_wdata, p_rdata;
  logic [3:0]        p_wstrb;
  logic [1:0]        p_bresp, p_rresp;

  // transaction tracking
  int  aw_acc = 0, w_acc = 0, ar_acc = 0;   // accepted, not yet answered
  bit  aw_pending_first = 0, w_pending_first = 0;
  int  last_b = -10, last_r = -10, cyc = 0;

  task automatic fail(input string rule, input string msg);
    errors++;
    if (errors <= 10) $display("ASSERT %s.%s @%0t: %s", NAME, rule, $time, msg);
  endtask

  wire aw_hs = awvalid && awready;
  wire w_hs  = wvalid && wready;
  wire b_hs  = bvalid && bready;
  wire ar_hs = arvalid && arready;
  wire r_hs  = rvalid && rready;

  always @(posedge clk) begin
    if (!rst_n) begin
      p_awv <= 0;
      p_wv <= 0;
      p_bv <= 0;
      p_arv <= 0;
      p_rv <= 0;
      aw_acc = 0;
      w_acc = 0;
      ar_acc = 0;
    end else begin
      cyc++;
      // ---- X checks
      if (((^({awvalid, wvalid, bvalid, arvalid, rvalid})) === 1'bx))
        fail("AXIL_X", "valid signal X/Z");
      if (awvalid === 1'b1 && ((^(awaddr)) === 1'bx))          fail("AXIL_X", "awaddr X/Z");
      if (wvalid === 1'b1 && ((^({wdata, wstrb})) === 1'bx))   fail("AXIL_X", "wdata/wstrb X/Z");
      if (arvalid === 1'b1 && ((^(araddr)) === 1'bx))          fail("AXIL_X", "araddr X/Z");
      if (bvalid === 1'b1 && ((^(bresp)) === 1'bx))            fail("AXIL_X", "bresp X/Z");
      if (rvalid === 1'b1 && ((^({rdata, rresp})) === 1'bx))   fail("AXIL_X", "rdata/rresp X/Z");

      // ---- hold / stability
      if (p_awv && !p_awr) begin
        if (awvalid !== 1'b1) fail("AXIL_HOLD_AW", "awvalid dropped");
        else if (awaddr !== p_awaddr) fail("AXIL_STABLE_AW", "awaddr changed");
      end
      if (p_wv && !p_wr) begin
        if (wvalid !== 1'b1) fail("AXIL_HOLD_W", "wvalid dropped");
        else if (wdata !== p_wdata || wstrb !== p_wstrb) fail("AXIL_STABLE_W", "wdata/wstrb changed");
      end
      if (p_arv && !p_arr) begin
        if (arvalid !== 1'b1) fail("AXIL_HOLD_AR", "arvalid dropped");
        else if (araddr !== p_araddr) fail("AXIL_STABLE_AR", "araddr changed");
      end
      if (p_bv && !p_br) begin
        if (bvalid !== 1'b1) fail("AXIL_HOLD_B", "bvalid dropped");
        else if (bresp !== p_bresp) fail("AXIL_STABLE_B", "bresp changed");
      end
      if (p_rv && !p_rr) begin
        if (rvalid !== 1'b1) fail("AXIL_HOLD_R", "rvalid dropped");
        else if (rdata !== p_rdata || rresp !== p_rresp) fail("AXIL_STABLE_R", "rdata/rresp changed");
      end

      // ---- transaction ordering
      if (aw_hs) begin
        aw_acc++;
        if (p_awv && !p_awr) cov_aw_wait++;
      end
      if (w_hs) w_acc++;
      if (aw_hs && w_hs)       cov_aw_w_same++;
      else if (aw_hs && w_acc <= (aw_acc - 1)) cov_aw_first++;
      else if (w_hs && aw_acc <= (w_acc - 1))  cov_w_first++;
      if (bvalid === 1'b1 && !p_bv && (aw_acc < 1 || w_acc < 1))
        fail("AXIL_BRESP_EARLY", "bvalid without accepted AW and W");
      if (b_hs) begin
        cov_writes++;
        if (p_bv && !p_br) cov_b_stall++;
        if (EXPECT_OKAY && bresp != 2'b00) fail("AXIL_RESP", $sformatf("bresp=%0d", bresp));
        if (cyc - last_b <= 8) cov_b2b_wr++;
        last_b = cyc;
        aw_acc--;
        w_acc--;
      end
      if (ar_hs) begin
        ar_acc++;
        if (p_arv && !p_arr) cov_ar_wait++;
      end
      if (rvalid === 1'b1 && !p_rv && ar_acc < 1)
        fail("AXIL_RRESP_EARLY", "rvalid without accepted AR");
      if (r_hs) begin
        cov_reads++;
        if (p_rv && !p_rr) cov_r_stall++;
        if (EXPECT_OKAY && rresp != 2'b00) fail("AXIL_RESP", $sformatf("rresp=%0d", rresp));
        if (cyc - last_r <= 8) cov_b2b_rd++;
        last_r = cyc;
        ar_acc--;
      end
      if ((aw_acc > 0 || w_acc > 0) && ar_acc > 0) cov_rw_overlap++;
      if (aw_acc > MAX_OUTSTANDING || w_acc > MAX_OUTSTANDING || ar_acc > MAX_OUTSTANDING)
        fail("AXIL_OUTSTANDING", "too many transactions in flight");

      p_awv <= (awvalid === 1'b1);
      p_awr <= awready;
      p_awaddr <= awaddr;
      p_wv  <= (wvalid === 1'b1);
      p_wr  <= wready;
      p_wdata  <= wdata;
      p_wstrb <= wstrb;
      p_bv  <= (bvalid === 1'b1);
      p_br  <= bready;
      p_bresp  <= bresp;
      p_arv <= (arvalid === 1'b1);
      p_arr <= arready;
      p_araddr <= araddr;
      p_rv  <= (rvalid === 1'b1);
      p_rr  <= rready;
      p_rdata  <= rdata;
      p_rresp <= rresp;
    end
  end

  function automatic int bins_hit();
    return (cov_writes > 0) + (cov_reads > 0) + (cov_aw_first > 0) + (cov_w_first > 0)
         + (cov_aw_w_same > 0) + (cov_b_stall > 0) + (cov_r_stall > 0)
         + (cov_aw_wait > 0) + (cov_ar_wait > 0) + (cov_b2b_wr > 0) + (cov_b2b_rd > 0);
  endfunction
  localparam int BINS = 11;

  task automatic report();
    $display("COVERAGE %-10s writes=%0d reads=%0d aw_first=%0d w_first=%0d aw_with_w=%0d aw_wait=%0d ar_wait=%0d",
             NAME, cov_writes, cov_reads, cov_aw_first, cov_w_first, cov_aw_w_same,
             cov_aw_wait, cov_ar_wait);
    $display("COVERAGE %-10s b_stalled=%0d r_stalled=%0d b2b_wr=%0d b2b_rd=%0d rw_overlap=%0d  bins %0d/%0d  assertion_errors=%0d sva_errors=%0d",
             NAME, cov_b_stall, cov_r_stall, cov_b2b_wr, cov_b2b_rd, cov_rw_overlap,
             bins_hit(), BINS, errors, sva_errors);
  endtask

`ifdef SVA_ON
  function automatic void sva_fail(input string rule);
    sva_errors++;
    if (sva_errors <= 10) $display("SVA %s.%s @%0t", NAME, rule, $time);
  endfunction

  a_aw_hold: assert property (@(posedge clk) disable iff (!rst_n)
               awvalid && !awready |=> awvalid && $stable(awaddr)) else sva_fail("AXIL_HOLD_AW");
  a_w_hold:  assert property (@(posedge clk) disable iff (!rst_n)
               wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb)) else sva_fail("AXIL_HOLD_W");
  a_ar_hold: assert property (@(posedge clk) disable iff (!rst_n)
               arvalid && !arready |=> arvalid && $stable(araddr)) else sva_fail("AXIL_HOLD_AR");
  a_b_hold:  assert property (@(posedge clk) disable iff (!rst_n)
               bvalid && !bready |=> bvalid && $stable(bresp)) else sva_fail("AXIL_HOLD_B");
  a_r_hold:  assert property (@(posedge clk) disable iff (!rst_n)
               rvalid && !rready |=> rvalid && $stable(rdata) && $stable(rresp)) else sva_fail("AXIL_HOLD_R");
  c_b_stall: cover property (@(posedge clk) disable iff (!rst_n) $past(bvalid && !bready) && bvalid && bready);
  c_r_stall: cover property (@(posedge clk) disable iff (!rst_n) $past(rvalid && !rready) && rvalid && rready);
`endif

endmodule
