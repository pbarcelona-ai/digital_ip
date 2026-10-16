// ***************
// Filename: tb_axil_split.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axil_split.
//   A randomised AXI-Lite master (scaler_tb_axil.svh BFM: random AW/W order,
//   delayed BREADY/RREADY) accesses two register files, each behind an
//   axil_regbus slave on one of the split ports. Every read is compared with
//   a reference model; writes must land only in the addressed slave.
//   Protocol checkers watch the master link and both slave links.
//   Plusargs: +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   The test tasks are in tests/axil_split_tests.sv (`included).
// Date: 2026-10-16

`timescale 1ns/1ps
module tb_axil_split;
  localparam int ADDR_W = 15;
  localparam int SEL    = 14;

  `include "scaler_tb_axil.svh"
  initial axil_id_block = 0;                         // the split itself has no ID block

  // master port signals are declared by the kit (awaddr, awvalid, ...)
  logic [2*ADDR_W-1:0] m_awaddr, m_araddr;
  logic [1:0] m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [1:0] m_arvalid, m_arready, m_rvalid, m_rready;
  logic [63:0] m_wdata, m_rdata;
  logic [7:0]  m_wstrb;
  logic [3:0]  m_bresp, m_rresp;

  axil_split #(
    .ADDR_W(ADDR_W),
    .SEL_BIT(SEL)
  ) dut (
    .clk,
    .rst_n,
    .s_awaddr(awaddr),
    .s_awvalid(awvalid),
    .s_awready(awready),
    .s_wdata(wdata),
    .s_wstrb(wstrb),
    .s_wvalid(wvalid),
    .s_wready(wready),
    .s_bresp(bresp),
    .s_bvalid(bvalid),
    .s_bready(bready),
    .s_araddr(araddr),
    .s_arvalid(arvalid),
    .s_arready(arready),
    .s_rdata(rdata),
    .s_rresp(rresp),
    .s_rvalid(rvalid),
    .s_rready(rready),
    .m_awaddr,
    .m_awvalid,
    .m_awready,
    .m_wdata,
    .m_wstrb,
    .m_wvalid,
    .m_wready,
    .m_bresp,
    .m_bvalid,
    .m_bready,
    .m_araddr,
    .m_arvalid,
    .m_arready,
    .m_rdata,
    .m_rresp,
    .m_rvalid,
    .m_rready
  );

  // two slaves: axil_regbus + 64-word register file each
  logic [31:0] rf [2][64];
  int          wr_cnt [2];
  for (genvar g = 0; g < 2; g++) begin : g_slave
    regbus_if #(.ADDR_W(ADDR_W), .DATA_W(32)) reg_bus ();
    assign reg_bus.rd_err = 1'b0;
    assign reg_bus.wr_err = 1'b0;
    axil_if #(.ADDR_W(ADDR_W)) u_slave_s_axil ();
    assign u_slave_s_axil.awaddr = m_awaddr[g*ADDR_W +: ADDR_W];
    assign u_slave_s_axil.awvalid = m_awvalid[g];
    assign m_awready[g] = u_slave_s_axil.awready;
    assign u_slave_s_axil.wdata = m_wdata[g*32 +: 32];
    assign u_slave_s_axil.wstrb = m_wstrb[g*4 +: 4];
    assign u_slave_s_axil.wvalid = m_wvalid[g];
    assign m_wready[g] = u_slave_s_axil.wready;
    assign m_bresp[g*2 +: 2] = u_slave_s_axil.bresp;
    assign m_bvalid[g] = u_slave_s_axil.bvalid;
    assign u_slave_s_axil.bready = m_bready[g];
    assign u_slave_s_axil.araddr = m_araddr[g*ADDR_W +: ADDR_W];
    assign u_slave_s_axil.arvalid = m_arvalid[g];
    assign m_arready[g] = u_slave_s_axil.arready;
    assign m_rdata[g*32 +: 32] = u_slave_s_axil.rdata;
    assign m_rresp[g*2 +: 2] = u_slave_s_axil.rresp;
    assign m_rvalid[g] = u_slave_s_axil.rvalid;
    assign u_slave_s_axil.rready = m_rready[g];
    axil_regbus #(.ADDR_W(ADDR_W)) u_slave (
      .clk,
      .rst_n,
      .s_axil(u_slave_s_axil),
      .bus(reg_bus)
    );
    always_ff @(posedge clk) begin
      if (reg_bus.wr) begin
        rf[g][reg_bus.waddr[7:2]] <= reg_bus.wdata;
        wr_cnt[g]++;
        if (reg_bus.waddr[SEL] != 1'(g)) begin
          errors++;
          $display("ERROR: slave %0d got a write for address 0x%0h", g, reg_bus.waddr);
        end
      end
      if (reg_bus.rd) reg_bus.rdata <= rf[g][reg_bus.raddr[7:2]];
    end
    axil_checker #(
      .ADDR_W(ADDR_W),
      .NAME("m_axil")
    ) u_chk (
      .clk,
      .rst_n,
      .awaddr(m_awaddr[g*ADDR_W +: ADDR_W]),
      .awvalid(m_awvalid[g]),
      .awready(m_awready[g]),
      .wdata(m_wdata[g*32 +: 32]),
      .wstrb(m_wstrb[g*4 +: 4]),
      .wvalid(m_wvalid[g]),
      .wready(m_wready[g]),
      .bresp(m_bresp[g*2 +: 2]),
      .bvalid(m_bvalid[g]),
      .bready(m_bready[g]),
      .araddr(m_araddr[g*ADDR_W +: ADDR_W]),
      .arvalid(m_arvalid[g]),
      .arready(m_arready[g]),
      .rdata(m_rdata[g*32 +: 32]),
      .rresp(m_rresp[g*2 +: 2]),
      .rvalid(m_rvalid[g]),
      .rready(m_rready[g])
    );
  end

  logic [31:0] model [2][64];

  initial begin
    int nw [2];
    for (int g = 0; g < 2; g++) begin
      nw[g] = 0;
      wr_cnt[g] = 0;
      for (int i = 0; i < 64; i++) begin
        model[g][i] = 0;
        rf[g][i] = 0;
      end
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
      if (wr_cnt[g] != nw[g]) begin
        errors++;
        $display("ERROR: slave %0d writes %0d != %0d", g, wr_cnt[g], nw[g]);
      end
      g_slave_report(g);
    end
    tests = 1;
    finish_report();
  end

  // test tasks: tests/axil_split_tests.sv
  `include "axil_split_tests.sv"

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
