// ***************
// Filename: sva_demo_tb.sv
// Author: FPGA Cores 4 U
// Description: Demonstration of the concurrent SVA checkers. Instantiates
//   axi_stream_fifo and axi4_lite_regs with random traffic and binds
//   axis_protocol_checker and axil_protocol_checker to their ports. Run
//   with scripts/run_sva.sh (Verilator --assert --binary). Prints TEST
//   PASSED when no assertion fires in 20000 clocks. Clock - 100 MHz.
//   Reset - released after 5 clocks. Latency - not applicable. Errors -
//   any $error from a checker ends the run as failed.
// Date: 2026-09-29
`timescale 1ns/1ps
module sva_demo_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // ---- AXI-Stream FIFO with random traffic ----
  logic [31:0] sd = 0, md; logic [3:0] sk = 4'hF, mk; logic sl = 0, sv = 0, sr, ml, mv, mr = 0; logic [0:0] su = 0, mu; logic [10:0] lvl;
  axi_stream_fifo #(.DATA_W(32), .USER_W(1), .DEPTH(16)) fifo (.aclk, .aresetn, .s_axis_tdata(sd), .s_axis_tkeep(sk), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr), .level_o(lvl));
  axis_protocol_checker #(.DATA_W(32), .USER_W(1)) chk_in  (.aclk, .aresetn, .tdata(sd), .tkeep(sk), .tlast(sl), .tuser(su), .tvalid(sv), .tready(sr));
  axis_protocol_checker #(.DATA_W(32), .USER_W(1)) chk_out (.aclk, .aresetn, .tdata(md), .tkeep(mk), .tlast(ml), .tuser(mu), .tvalid(mv), .tready(mr));
  always @(posedge aclk) begin
    mr <= $urandom_range(0, 2) != 0;
    if (!sv || sr) begin sv <= ($urandom_range(0, 3) != 0); sd <= $urandom; sl <= ($urandom_range(0, 7) == 0); end
  end
  // ---- AXI-Lite register bank with random accesses ----
  logic [7:0] awaddr = 0, araddr = 0; logic awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 1, arvalid = 0, arready, rvalid, rready = 1;
  logic [31:0] wdata = 0, rdata; logic [3:0] wstrb = 4'hF; logic [1:0] bresp, rresp; logic [255:0] regs_o, hw_i = 0, hw_set = 0; logic [7:0] wrp;
  axi4_lite_regs #(.ADDR_W(8), .NREG(8)) regs (.aclk, .aresetn, .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready), .hw_i, .hw_set_i(hw_set), .reg_o(regs_o), .wr_pulse_o(wrp));
  axil_protocol_checker #(.ADDR_W(8)) chk_axil (.aclk, .aresetn, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready, .bresp, .bvalid, .bready,
    .araddr, .arvalid, .arready, .rdata, .rresp, .rvalid, .rready);
  always @(posedge aclk) begin
    bready <= $urandom_range(0, 1); rready <= $urandom_range(0, 1);
    if (!awvalid || awready) begin awvalid <= $urandom_range(0, 3) == 0; awaddr <= $urandom_range(0, 9) * 4; end
    if (!wvalid || wready) begin wvalid <= $urandom_range(0, 3) == 0; wdata <= $urandom; end
    if (!arvalid || arready) begin arvalid <= $urandom_range(0, 3) == 0; araddr <= $urandom_range(0, 9) * 4; end
  end
  initial begin
    repeat (5) @(posedge aclk); aresetn = 1; repeat (20000) @(posedge aclk);
    $display("TEST PASSED"); $finish;
  end
endmodule
