// ***************
// Filename: axi4_lite_regs_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axi4_lite_regs. Eight registers
//   with RW, RO, W1C and W1S access types: checks reset values, RW byte
//   strobes, RO readback of hardware values and SLVERR on write, W1C set
//   from hardware and clear by software (including a simultaneous set),
//   W1S behaviour, write pulses and DECERR beyond the last register.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/axi4_lite_regs_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_lite_regs_tb;
  localparam int N = 8;
  // 0 RW, 1 RW, 2 RO, 3 RO, 4 W1C, 5 W1C, 6 W1S, 7 RW
  localparam logic [2*N-1:0] ACC = {2'd0, 2'd3, 2'd2, 2'd2, 2'd1, 2'd1, 2'd0, 2'd0};
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [32*N-1:0] hw = 0, hws = 0, r;
  logic [N-1:0] wp;
  localparam logic [32*N-1:0] rv = {32'hF00D_0007, 32'hF00D_0006, 32'hF00D_0005, 32'hF00D_0004, 32'hF00D_0003, 32'hF00D_0002, 32'hF00D_0001, 32'hF00D_0000};
  axi4_lite_regs #(.ADDR_W(8), .NREG(N), .ACCESS(ACC), .RESET_VALS(rv)) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .hw_i(hw),
    .hw_set_i(hws),
    .reg_o(r),
    .wr_pulse_o(wp)
  );
  int errors = 0, pulses = 0;
  logic [31:0] rd;
  always @(posedge aclk) if (|wp) pulses++;
  // test tasks: tests/axi4_lite_regs_tests.sv
  `include "axi4_lite_regs_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi4_lite_regs_tb.vcd");
      $dumpvars(0, axi4_lite_regs_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    for (int i = 0; i < N; i++) begin
      bfm.read(i*4, rd);
      check(rd == ((i == 2 || i == 3) ? 32'h0 : 32'hF00D_0000 + i), $sformatf("reset value reg %0d: %h", i, rd));
    end
    // RW with strobes
    bfm.write(8'h00, 32'h1234_5678);
    bfm.read(8'h00, rd);
    check(rd == 32'h1234_5678, "RW");
    bfm.write_strb(8'h00, 32'hFFFF_FFFF, 4'b0100);
    bfm.read(8'h00, rd);
    check(rd == 32'h12FF_5678, "RW strobe");
    check(r[31:0] == 32'h12FF_5678, "reg_o mirrors RW");
    // RO
    hw[32*2 +: 32] = 32'hAAAA_5555;
    bfm.read(8'h08, rd);
    check(rd == 32'hAAAA_5555, "RO reads hw_i");
    bfm.write(8'h08, 32'h1);
    check(bfm.last_resp == 2'b10, "RO write must SLVERR");
    bfm.read(8'h08, rd);
    check(rd == 32'hAAAA_5555, "RO changed by write");
    bfm.resp_errors = 0;
    // W1C: hardware sets bits 3 and 5, software clears bit 3
    @(posedge aclk);
    #1 hws[32*4 +: 32] = 32'h28;
    @(posedge aclk);
    #1 hws = 0;
    bfm.read(8'h10, rd);
    check(rd == (32'hF00D_0004 | 32'h28), $sformatf("W1C set %h", rd));
    bfm.write(8'h10, 32'h08);
    bfm.read(8'h10, rd);
    check(rd == ((32'hF00D_0004 | 32'h28) & ~32'h08), $sformatf("W1C clear %h", rd));
    // W1S: software sets, hardware clears
    bfm.write(8'h18, 32'h0000_00F0);
    bfm.read(8'h18, rd);
    check(rd == (32'hF00D_0006 | 32'hF0), "W1S set");
    @(posedge aclk);
    #1 hws[32*6 +: 32] = 32'h30;
    @(posedge aclk);
    #1 hws = 0;
    bfm.read(8'h18, rd);
    check(rd == ((32'hF00D_0006 | 32'hF0) & ~32'h30), "W1S hw clear");
    // pulses and DECERR
    check(pulses == 5, $sformatf("write pulses %0d", pulses));
    bfm.read(8'h20, rd);
    check(bfm.last_resp == 2'b11, "DECERR read");
    bfm.write(8'h24, 1);
    check(bfm.last_resp == 2'b11, "DECERR write");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #3000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
