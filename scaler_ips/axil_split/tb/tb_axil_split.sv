// ***************
// Filename: tb_axil_split.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for axil_split.
//   A randomised AXI-Lite master (scaler_tb_axil.svh BFM: random AW/W order,
//   delayed BREADY/RREADY) accesses two register files, each behind an
//   axil_regbus slave on one of the split ports. Every read is compared with
//   a reference model; writes must land only in the addressed slave.
//   Protocol checkers watch the master link and both slave links.
//   Plusargs: +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
// Date: 2026-09-26

`timescale 1ns/1ps
module tb_axil_split;
  localparam int ADDR_W = 15;
  localparam int SEL    = 14;

  `include "scaler_tb_axil.svh"

  // master port signals are declared by the kit (awaddr, awvalid, ...)
  logic [2*ADDR_W-1:0] m_awaddr, m_araddr;
  logic [1:0] m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [1:0] m_arvalid, m_arready, m_rvalid, m_rready;
  logic [63:0] m_wdata, m_rdata;
  logic [7:0]  m_wstrb;
  logic [3:0]  m_bresp, m_rresp;

  axil_split #(.ADDR_W(ADDR_W), .SEL_BIT(SEL)) dut (
    .clk, .rst_n,
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
    .m_awaddr, .m_awvalid, .m_awready, .m_wdata, .m_wstrb, .m_wvalid, .m_wready,
    .m_bresp, .m_bvalid, .m_bready, .m_araddr, .m_arvalid, .m_arready,
    .m_rdata, .m_rresp, .m_rvalid, .m_rready);

  // two slaves: axil_regbus + 64-word register file each
  logic [31:0] rf [2][64];
  int          wr_cnt [2];
  for (genvar g = 0; g < 2; g++) begin : g_slave
    logic              reg_wr, reg_rd;
    logic [ADDR_W-1:0] reg_waddr, reg_raddr;
    logic [31:0]       reg_wdata, reg_rdata;
    logic [3:0]        reg_wstrb;
    axil_regbus #(.ADDR_W(ADDR_W)) u_slave (
      .clk, .rst_n,
      .s_axil_awaddr(m_awaddr[g*ADDR_W +: ADDR_W]), .s_axil_awvalid(m_awvalid[g]), .s_axil_awready(m_awready[g]),
      .s_axil_wdata(m_wdata[g*32 +: 32]), .s_axil_wstrb(m_wstrb[g*4 +: 4]), .s_axil_wvalid(m_wvalid[g]), .s_axil_wready(m_wready[g]),
      .s_axil_bresp(m_bresp[g*2 +: 2]), .s_axil_bvalid(m_bvalid[g]), .s_axil_bready(m_bready[g]),
      .s_axil_araddr(m_araddr[g*ADDR_W +: ADDR_W]), .s_axil_arvalid(m_arvalid[g]), .s_axil_arready(m_arready[g]),
      .s_axil_rdata(m_rdata[g*32 +: 32]), .s_axil_rresp(m_rresp[g*2 +: 2]), .s_axil_rvalid(m_rvalid[g]), .s_axil_rready(m_rready[g]),
      .reg_wr, .reg_waddr, .reg_wdata, .reg_wstrb, .reg_rd, .reg_raddr, .reg_rdata);
    always_ff @(posedge clk) begin
      if (reg_wr) begin
        rf[g][reg_waddr[7:2]] <= reg_wdata;
        wr_cnt[g]++;
        if (reg_waddr[SEL] != 1'(g)) begin
          errors++; $display("ERROR: slave %0d got a write for address 0x%0h", g, reg_waddr);
        end
      end
      if (reg_rd) reg_rdata <= rf[g][reg_raddr[7:2]];
    end
    axil_checker #(.ADDR_W(ADDR_W), .NAME("m_axil")) u_chk (
      .clk, .rst_n,
      .awaddr(m_awaddr[g*ADDR_W +: ADDR_W]), .awvalid(m_awvalid[g]), .awready(m_awready[g]),
      .wdata(m_wdata[g*32 +: 32]), .wstrb(m_wstrb[g*4 +: 4]), .wvalid(m_wvalid[g]), .wready(m_wready[g]),
      .bresp(m_bresp[g*2 +: 2]), .bvalid(m_bvalid[g]), .bready(m_bready[g]),
      .araddr(m_araddr[g*ADDR_W +: ADDR_W]), .arvalid(m_arvalid[g]), .arready(m_arready[g]),
      .rdata(m_rdata[g*32 +: 32]), .rresp(m_rresp[g*2 +: 2]), .rvalid(m_rvalid[g]), .rready(m_rready[g]));
  end

  logic [31:0] model [2][64];

  initial begin
    int nw [2];
    for (int g = 0; g < 2; g++) begin
      nw[g] = 0; wr_cnt[g] = 0;
      for (int i = 0; i < 64; i++) begin model[g][i] = 0; rf[g][i] = 0; end
    end
    reset_dut();
    for (int i = 0; i < 600; i++) begin
      int g, a, addr;
      logic [31:0] d;
      g = $urandom_range(1, 0);
      a = $urandom_range(63, 0);
      addr = (g << SEL) | (a << 2) | ($urandom_range(15, 0) << 8);   // upper bits ignored by slaves
      if ($urandom_range(1, 0)) begin
        d = $urandom;
        axil_write(addr, d);
        model[g][a] = d;
        nw[g]++;
      end else begin
        axil_check(addr, model[g][a]);
      end
    end
    repeat (5) @(posedge clk);
    for (int g = 0; g < 2; g++) begin
      checks++;
      if (wr_cnt[g] != nw[g]) begin errors++; $display("ERROR: slave %0d writes %0d != %0d", g, wr_cnt[g], nw[g]); end
      g_slave_report(g);
    end
    tests = 1;
    finish_report();
  end

  task automatic g_slave_report(input int g);
    int e;
    if (g == 0) begin g_slave[0].u_chk.report(); e = g_slave[0].u_chk.errors + g_slave[0].u_chk.sva_errors; end
    else        begin g_slave[1].u_chk.report(); e = g_slave[1].u_chk.errors + g_slave[1].u_chk.sva_errors; end
    if (e != 0) begin errors++; $display("ERROR: protocol errors on slave port %0d", g); end
  endtask

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_axil_split.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_axil_split.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_axil_split);
    end
  end
endmodule
