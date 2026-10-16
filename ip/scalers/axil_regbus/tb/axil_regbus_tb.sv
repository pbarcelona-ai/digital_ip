// ***************
// Filename: tb_axil_regbus.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axil_regbus.
//   A 64-entry register file with byte strobes sits on the register bus.
//   2000+ random writes and reads use random AW/W ordering, random valid
//   delays and random B/R back-pressure, and are compared with a model.
//   Protocol checks: exactly one reg_wr per write and one reg_rd per read,
//   OKAY responses, R data stable while rready is low.
//   Plusargs: +VCD=<file> waveform file, +NO_VCD disables dumping.
//   The test tasks are in tests/axil_regbus_tests.sv (`included).
// Date: 2026-10-16

`timescale 1ns/1ps
module tb_axil_regbus;
  localparam int ADDR_W = 8;              // 64 word registers

  logic clk = 0; // 100 MHz clock
  always #5 clk = ~clk;
  logic rst_n = 0;
  int   errors = 0, checks = 0;           // result counters

  // AXI4-Lite master side (driven by the tasks below)
  axil_if #(.ADDR_W(ADDR_W), .DATA_W(32)) s_axil ();
  initial s_axil.awaddr = '0;
  initial s_axil.awvalid = 0;
  initial s_axil.wdata = '0;
  initial s_axil.wstrb = '0;
  initial s_axil.wvalid = 0;
  initial s_axil.bready = 0;
  initial s_axil.araddr = '0;
  initial s_axil.arvalid = 0;
  initial s_axil.rready = 0;

  // register bus side
  regbus_if #(.ADDR_W(ADDR_W), .DATA_W(32)) reg_bus ();

  // Device under test
  axil_regbus #(.ADDR_W(ADDR_W)) dut (
    .clk,
    .rst_n,
    .s_axil(s_axil),
    .bus(reg_bus)
  );

  // AXI4-Lite protocol checker + coverage on the DUT port
  axil_checker #(
    .ADDR_W(ADDR_W),
    .NAME("s_axil"),
    .EXPECT_OKAY(0)                         // ERR_WORD answers SLVERR (checked by the tests)
  ) u_axil_chk (
    .clk,
    .rst_n,
    .awaddr(s_axil.awaddr),
    .awvalid(s_axil.awvalid),
    .awready(s_axil.awready),
    .wdata(s_axil.wdata),
    .wstrb(s_axil.wstrb),
    .wvalid(s_axil.wvalid),
    .wready(s_axil.wready),
    .bresp(s_axil.bresp),
    .bvalid(s_axil.bvalid),
    .bready(s_axil.bready),
    .araddr(s_axil.araddr),
    .arvalid(s_axil.arvalid),
    .arready(s_axil.arready),
    .rdata(s_axil.rdata),
    .rresp(s_axil.rresp),
    .rvalid(s_axil.rvalid),
    .rready(s_axil.rready)
  );

  // register file on the simple bus (registered read, as required); word
  // ERR_WORD is an error word: writes are refused (SLVERR) and reads answer
  // SLVERR, so both error inputs are exercised
  localparam int ERR_WORD = 63;
  logic [31:0] rf [64];
  int n_wr = 0, n_rd = 0;
  always_ff @(posedge clk) begin
    reg_bus.wr_err <= reg_bus.wr && (reg_bus.waddr[7:2] == 6'(ERR_WORD));
    if (reg_bus.wr) begin
      n_wr++;
      if (reg_bus.waddr[7:2] != 6'(ERR_WORD))
        for (int b = 0; b < 4; b++)
          if (reg_bus.wstrb[b]) rf[reg_bus.waddr[7:2]][b*8 +: 8] <= reg_bus.wdata[b*8 +: 8];
    end
    if (reg_bus.rd) begin
      n_rd++;
      reg_bus.rdata <= rf[reg_bus.raddr[7:2]];
      reg_bus.rd_err <= (reg_bus.raddr[7:2] == 6'(ERR_WORD));
    end
  end

  // expected register contents
  logic [31:0] model [64];

  // test tasks: tests/axil_regbus_tests.sv
  `include "axil_regbus_tests.sv"

  // Main sequence: initialise every register, then random traffic,
  // then compare the number of bus pulses with the transactions issued
  initial begin
    int nw, nr;
    nw = 0;
    nr = 0;
    for (int i = 0; i < 64; i++) begin
      model[i] = 0;
      rf[i] = 0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    for (int i = 0; i < 64; i++) begin
      wr(i * 4, $urandom, 4'hF);
      nw++;
    end
    for (int i = 0; i < 2000; i++) begin
      int a;
      a = $urandom_range(63, 0) * 4;
      if ($urandom_range(1, 0)) begin
        wr(a, $urandom, 4'($urandom_range(15, 0)));
        nw++;
      end
      else begin
        rd(a);
        nr++;
      end
    end
    repeat (5) @(posedge clk);
    checks += 2;
    if (n_wr != nw) begin
      errors++;
      $display("ERROR: reg_wr pulses %0d != writes %0d", n_wr, nw);
    end
    if (n_rd != nr) begin
      errors++;
      $display("ERROR: reg_rd pulses %0d != reads %0d", n_rd, nr);
    end
    u_axil_chk.report();
    checks++;
    if (u_axil_chk.errors + u_axil_chk.sva_errors != 0) begin
      errors++;
      $display("ERROR: AXI-Lite protocol assertion failures");
    end
    if (errors == 0) $display("TB_RESULT: PASS  checks=%0d", checks);
    else             $display("TB_RESULT: FAIL  checks=%0d errors=%0d", checks, errors);
    $finish;
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_axil_regbus.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_axil_regbus.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_axil_regbus);
    end
  end
endmodule
