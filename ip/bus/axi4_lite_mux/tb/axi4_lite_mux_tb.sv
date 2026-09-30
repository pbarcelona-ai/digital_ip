// ***************
// Filename: axi4_lite_mux_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for axi4_lite_mux. One BFM master
//   accesses three ip_axil_regs slaves at 0x000, 0x100 and 0x200 (4
//   registers each) through the mux. Checks isolation (each slave holds
//   its own data), address pass-through, DECERR for unmapped reads and
//   writes with no slave activity, and a random soak against a model.
//   Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_lite_mux_tb;
  localparam int NS = 3, AW = 12;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  logic [AW-1:0] s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready; logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready; logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(AW)) bfm (.*);
  logic [NS*AW-1:0] awa, ara; logic [NS-1:0] awv, awr, wv, wr, bv, br, arv, arr, rv, rr; logic [NS*32-1:0] wd, rd_; logic [NS*4-1:0] ws; logic [NS*2-1:0] bre, rre;
  localparam logic [NS*AW-1:0] BASE = {12'h200, 12'h100, 12'h000};
  localparam logic [NS*AW-1:0] MASK = {12'hF00, 12'hF00, 12'hF00};
  axi4_lite_mux #(.ADDR_W(AW), .NSLAVE(NS), .BASE(BASE), .MASK(MASK)) dut (.aclk, .aresetn,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .m_axil_awaddr(awa), .m_axil_awvalid(awv), .m_axil_awready(awr), .m_axil_wdata(wd), .m_axil_wstrb(ws), .m_axil_wvalid(wv), .m_axil_wready(wr),
    .m_axil_bresp(bre), .m_axil_bvalid(bv), .m_axil_bready(br), .m_axil_araddr(ara), .m_axil_arvalid(arv), .m_axil_arready(arr),
    .m_axil_rdata(rd_), .m_axil_rresp(rre), .m_axil_rvalid(rv), .m_axil_rready(rr));
  logic [NS*4*32-1:0] regs_o; logic [NS*4-1:0] wp; int slave_writes [NS]; int slave_reads [NS];
  for (genvar i = 0; i < NS; i++) begin : g_s
    logic [4*32-1:0] r;
    ip_axil_regs #(.ADDR_W(8), .NREG(4)) s (.aclk, .aresetn,
      .s_axil_awaddr(awa[i*AW +: 8]), .s_axil_awvalid(awv[i]), .s_axil_awready(awr[i]), .s_axil_wdata(wd[i*32 +: 32]), .s_axil_wstrb(ws[i*4 +: 4]),
      .s_axil_wvalid(wv[i]), .s_axil_wready(wr[i]), .s_axil_bresp(bre[i*2 +: 2]), .s_axil_bvalid(bv[i]), .s_axil_bready(br[i]),
      .s_axil_araddr(ara[i*AW +: 8]), .s_axil_arvalid(arv[i]), .s_axil_arready(arr[i]), .s_axil_rdata(rd_[i*32 +: 32]), .s_axil_rresp(rre[i*2 +: 2]),
      .s_axil_rvalid(rv[i]), .s_axil_rready(rr[i]), .reg_o(r), .wr_pulse_o(), .wr_data_o(), .rd_i(r));
    always @(posedge aclk) begin if (awv[i] && awr[i]) slave_writes[i]++; if (arv[i] && arr[i]) slave_reads[i]++; end
  end
  int errors = 0; logic [31:0] rd; logic [31:0] model [0:11];
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  function automatic int addr_of(input int k); return (k / 4) * 256 + (k % 4) * 4; endfunction
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("axi4_lite_mux_tb.vcd"); $dumpvars(0, axi4_lite_mux_tb); end
    for (int i = 0; i < NS; i++) begin slave_writes[i] = 0; slave_reads[i] = 0; end
    for (int i = 0; i < 12; i++) model[i] = 0;
    repeat (4) @(posedge aclk); aresetn = 1; repeat (3) @(posedge aclk);
    for (int k = 0; k < 12; k++) begin model[k] = 32'hC0DE_0000 + k * 16 + 1; bfm.write(addr_of(k), model[k]); check(bfm.last_resp == 0, "write resp"); end
    for (int k = 0; k < 12; k++) begin bfm.read(addr_of(k), rd); check(rd == model[k] && bfm.last_resp == 0, $sformatf("slot %0d got %h exp %h", k, rd, model[k])); end
    for (int i = 0; i < NS; i++) check(slave_writes[i] == 4 && slave_reads[i] == 4, $sformatf("slave %0d writes %0d reads %0d", i, slave_writes[i], slave_reads[i]));
    // unmapped: DECERR, no slave activity
    bfm.read(12'h300, rd); check(bfm.last_resp == 2'b11 && rd == 0, "read DECERR"); bfm.write(12'h404, 32'h55); check(bfm.last_resp == 2'b11, "write DECERR");
    bfm.write(12'hF00, 32'h55); check(bfm.last_resp == 2'b11, "write DECERR 2");
    for (int i = 0; i < NS; i++) check(slave_writes[i] == 4 && slave_reads[i] == 4, "unmapped access reached a slave");
    bfm.resp_errors = 0;
    // soak
    for (int n = 0; n < 300; n++) begin
      int k; k = $urandom_range(0, 11);
      if ($urandom_range(0, 1)) begin model[k] = $urandom; bfm.write(addr_of(k), model[k]); end
      else begin bfm.read(addr_of(k), rd); check(rd == model[k], $sformatf("soak slot %0d", k)); end
    end
    check(bfm.resp_errors == 0, "unexpected error responses");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #5000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
