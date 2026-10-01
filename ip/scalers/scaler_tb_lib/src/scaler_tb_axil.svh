// ***************
// Filename: scaler_tb_axil.svh
// Author: FPGA Cores 4 U
// Description: Testbench kit: clock, reset and AXI4-Lite BFM.
//   Declares clk (100 MHz), rst_n, the AXI4-Lite master signals and the
//   tasks axil_write, axil_read, axil_check and reset_dut, plus error /
//   check / test counters, a watchdog (+TIMEOUT_MS=<n>) and
//   finish_report, which prints TB_RESULT: PASS or FAIL. Include inside a
//   testbench module after defining localparam int ADDR_W. Included by
//   scaler_tb_lib.svh; module testbenches include it directly.
// Date: 2026-09-26

// Default watchdog time in ns (can be overridden with a define)
`ifndef TB_TIMEOUT_NS
`define TB_TIMEOUT_NS 200_000_000
`endif

// ------------------------------------------------------------------ signals
logic clk = 1'b0;
always #5 clk = ~clk;          // 100 MHz with a 1 ns time unit
logic rst_n = 1'b0;            // active-low reset, driven by reset_dut

// AXI4-Lite master signals (driven on the falling clock edge)

logic [ADDR_W-1:0] awaddr = '0, araddr = '0;
logic              awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0;
logic              arvalid = 1'b0, rready = 1'b0;
logic [31:0]       wdata = '0;
logic [3:0]        wstrb = '0;
wire               awready, wready, bvalid, arready, rvalid;
wire [1:0]         bresp, rresp;
wire [31:0]        rdata;

// AXI4-Lite protocol checker + coverage on the testbench/DUT control link
axil_checker #(.ADDR_W(ADDR_W), .NAME("s_axil")) u_axil_chk (
  .clk, .rst_n, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
  .bresp, .bvalid, .bready, .araddr, .arvalid, .arready, .rdata, .rresp, .rvalid, .rready);

int errors = 0;                // mismatches / protocol errors found
int checks = 0;                // comparisons performed
int tests  = 0;                // test cases run

// Watchdog. Default `TB_TIMEOUT_NS; override at run time with +TIMEOUT_MS=<n>.
initial begin
  longint t_ns;
  int     ms;
  t_ns = `TB_TIMEOUT_NS;
  if ($value$plusargs("TIMEOUT_MS=%d", ms)) t_ns = longint'(ms) * 64'd1000000;
  #(t_ns);
  $display("TB_RESULT: FAIL (timeout) errors=%0d checks=%0d", errors, checks);
  $finish;
end

// ------------------------------------------------------------------ AXI-Lite
// Single AXI-Lite write: drive AW and W together, drop each valid once
// its handshake completes, then accept the B response and check OKAY.
// Randomised AXI4-Lite master: AW and W are presented together, AW first or
// W first (random), and BREADY / RREADY are asserted after a random delay, so
// the protocol checker sees every ordering and response stall.
int axil_max_delay = 2;   // set to 0 for fastest register access

task automatic axil_write(input int addr, input logic [31:0] data);
  bit aw_done, w_done;
  int order, lag;
  aw_done = 0; w_done = 0;
  order = $urandom_range(2, 0);             // 0: together, 1: AW first, 2: W first
  lag   = (axil_max_delay > 0) ? $urandom_range(axil_max_delay, 1) : 0;
  @(negedge clk);
  awaddr = ADDR_W'(addr); wdata = data; wstrb = 4'hF;
  awvalid = (order != 2) || (lag == 0);
  wvalid  = (order != 1) || (lag == 0);
  while (!(aw_done && w_done)) begin
    @(posedge clk);
    if (awvalid && awready) aw_done = 1;
    if (wvalid  && wready)  w_done  = 1;
    @(negedge clk);
    if (aw_done) awvalid = 1'b0;
    if (w_done)  wvalid  = 1'b0;
    if (lag > 0) lag--;
    if (lag == 0) begin
      if (!aw_done) awvalid = 1'b1;
      if (!w_done)  wvalid  = 1'b1;
    end
  end
  repeat ((axil_max_delay > 0) ? $urandom_range(axil_max_delay, 0) : 0) @(negedge clk);
  bready = 1'b1;
  do @(posedge clk); while (!bvalid);
  if (bresp != 2'b00) begin
    $display("ERROR: bresp=%0d at addr 0x%0h", bresp, addr); errors++;
  end
  @(negedge clk); bready = 1'b0;
endtask

// Single AXI-Lite read: AR handshake, then wait for R and check OKAY.
task automatic axil_read(input int addr, output logic [31:0] data);
  @(negedge clk);
  araddr = ADDR_W'(addr); arvalid = 1'b1;
  do @(posedge clk); while (!arready);
  @(negedge clk); arvalid = 1'b0;
  repeat ((axil_max_delay > 0) ? $urandom_range(axil_max_delay + 1, 0) : 0) @(negedge clk);
  rready = 1'b1;
  do @(posedge clk); while (!rvalid);
  data = rdata;
  if (rresp != 2'b00) begin
    $display("ERROR: rresp=%0d at addr 0x%0h", rresp, addr); errors++;
  end
  @(negedge clk); rready = 1'b0;
endtask

// Read a register and compare the bits selected by mask
task automatic axil_check(input int addr, input logic [31:0] exp,
                          input logic [31:0] mask = 32'hFFFF_FFFF);
  logic [31:0] r;
  axil_read(addr, r);
  checks++;
  if ((r & mask) !== (exp & mask)) begin
    errors++;
    $display("ERROR: reg 0x%03h read 0x%08h expected 0x%08h (mask 0x%08h)",
             addr, r, exp, mask);
  end
endtask

// ------------------------------------------------------------------ reset
// Hold reset for 5 clocks, release on a falling edge, wait 2 clocks
task automatic reset_dut();
  rst_n = 1'b0;
  repeat (5) @(posedge clk);
  @(negedge clk) rst_n = 1'b1;
  repeat (2) @(posedge clk);
endtask

// Print the final verdict (parsed by the run scripts) and stop
task automatic finish_report();
  int chk;
  $display("---------------------------------------------------------------- coverage");
  u_axil_chk.report();
  chk = u_axil_chk.errors + u_axil_chk.sva_errors;
`ifdef SCALER_TB_LIB
  lib_report(chk);
`endif
  if (chk > 0) $display("ERROR: %0d protocol assertion failure(s)", chk);
  errors += chk;
  if (errors == 0)
    $display("TB_RESULT: PASS  tests=%0d checks=%0d", tests, checks);
  else
    $display("TB_RESULT: FAIL  tests=%0d checks=%0d errors=%0d", tests, checks, errors);
  $finish;
endtask
