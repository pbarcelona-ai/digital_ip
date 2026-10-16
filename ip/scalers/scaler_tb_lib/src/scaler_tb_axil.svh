// ***************
// Filename: scaler_tb_axil.svh
// Author: FPGA Cores 4 U
// Description: Testbench kit: clock, reset and AXI4-Lite BFM.
//   Declares clk (100 MHz), rst_n, the AXI4-Lite master signals and the
//   tasks axil_write, axil_read, axil_check (register offsets: 0x000-0x0FF
//   of every 16 KB window move up by 0x10 past the ID block while
//   axil_id_block = 1, the default), axil_write_abs / axil_read_abs /
//   axil_check_abs (addresses as given), axil_write_err / axil_read_err
//   (SLVERR expected), check_id_block and reset_dut, plus error /
//   check / test counters, a watchdog (+TIMEOUT_MS=<n>) and
//   finish_report, which prints TB_RESULT: PASS or FAIL. Include inside a
//   testbench module after defining localparam int ADDR_W. Included by
//   scaler_tb_lib.svh; module testbenches include it directly.
// Date: 2026-10-16

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
axil_checker #(
  .ADDR_W(ADDR_W),
  .NAME("s_axil"),
  .EXPECT_OKAY(0)              // responses are checked by the tasks (axil_resp_exp)
) u_axil_chk (
  .clk,
  .rst_n,
  .awaddr,
  .awvalid,
  .awready,
  .wdata,
  .wstrb,
  .wvalid,
  .wready,
  .bresp,
  .bvalid,
  .bready,
  .araddr,
  .arvalid,
  .arready,
  .rdata,
  .rresp,
  .rvalid,
  .rready
);

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

// Register windows of the DUT start with the ID block (ID, VERSION, DATE, reserved at 0x00-0x0C):
// the offsets 0x000-0x0FF of each 16 KB window (the old register maps) are 0x10 higher. Tables at
// 0x1000 and up do not move. 0 for a DUT without ID blocks (axil_split).
bit axil_id_block = 1;
logic [1:0] axil_resp_exp = 2'b00;   // response the next accesses must get (OKAY; SLVERR in *_err)
function automatic int axil_map(input int addr);
  return (axil_id_block && (addr & 'h3F00) == 0) ? addr + 'h10 : addr;
endfunction

task automatic axil_write(input int addr, input logic [31:0] data);
  axil_write_abs(axil_map(addr), data);
endtask

task automatic axil_read(input int addr, output logic [31:0] data);
  axil_read_abs(axil_map(addr), data);
endtask

task automatic axil_write_abs(input int addr, input logic [31:0] data);
  bit aw_done, w_done;
  int order, lag;
  aw_done = 0;
  w_done = 0;
  order = $urandom_range(2, 0);             // 0: together, 1: AW first, 2: W first
  lag   = (axil_max_delay > 0) ? $urandom_range(axil_max_delay, 1) : 0;
  @(negedge clk);
  awaddr = ADDR_W'(addr);
  wdata = data;
  wstrb = 4'hF;
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
  do @(posedge clk);
  while (!bvalid);
  if (bresp != axil_resp_exp) begin
    $display("ERROR: bresp=%0d (expected %0d) at addr 0x%0h", bresp, axil_resp_exp, addr);
    errors++;
  end
  @(negedge clk);
  bready = 1'b0;
endtask

// Single AXI-Lite read: AR handshake, then wait for R and check OKAY.
task automatic axil_read_abs(input int addr, output logic [31:0] data);
  @(negedge clk);
  araddr = ADDR_W'(addr);
  arvalid = 1'b1;
  do @(posedge clk);
  while (!arready);
  @(negedge clk);
  arvalid = 1'b0;
  repeat ((axil_max_delay > 0) ? $urandom_range(axil_max_delay + 1, 0) : 0) @(negedge clk);
  rready = 1'b1;
  do @(posedge clk);
  while (!rvalid);
  data = rdata;
  if (rresp != axil_resp_exp) begin
    $display("ERROR: rresp=%0d (expected %0d) at addr 0x%0h", rresp, axil_resp_exp, addr);
    errors++;
  end
  @(negedge clk);
  rready = 1'b0;
endtask

// Read a register and compare the bits selected by mask
task automatic axil_check(input int addr, input logic [31:0] exp,
                          input logic [31:0] mask = 32'hFFFF_FFFF);
  axil_check_abs(axil_map(addr), exp, mask);
endtask

task automatic axil_check_abs(input int addr, input logic [31:0] exp,
                              input logic [31:0] mask = 32'hFFFF_FFFF);
  logic [31:0] r;
  axil_read_abs(addr, r);
  checks++;
  if ((r & mask) !== (exp & mask)) begin
    errors++;
    $display("ERROR: reg 0x%03h read 0x%08h expected 0x%08h (mask 0x%08h)",
             addr, r, exp, mask);
  end
endtask

// Accesses that must be refused with SLVERR (addresses as given)
task automatic axil_write_err(input int addr, input logic [31:0] data);
  checks++;
  axil_resp_exp = 2'b10;
  axil_write_abs(addr, data);
  axil_resp_exp = 2'b00;
endtask

task automatic axil_read_err(input int addr);
  logic [31:0] r;
  checks++;
  axil_resp_exp = 2'b10;
  axil_read_abs(addr, r);
  axil_resp_exp = 2'b00;
endtask

// ID block of the register window at base: ID (exp_id), VERSION ASCII "d.dd", DATE BCD mm/dd/yyyy,
// 0x0C reads 0; writes to the block are refused (SLVERR) and change nothing
task automatic check_id_block(input int base, input logic [31:0] exp_id);
  logic [31:0] id, ver, date, rsv, v;
  axil_read_abs(base, id);
  axil_read_abs(base + 4, ver);
  axil_read_abs(base + 8, date);
  axil_read_abs(base + 'hC, rsv);
  checks += 4;
  if (id !== exp_id) begin
    errors++;
    $display("ERROR: ID 0x%08h (\"%s\"), expected \"%s\"", id, id, exp_id);
  end
  if (!(ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." && ver[15:8] >= "0" && ver[15:8] <= "9" &&
        ver[7:0] >= "0" && ver[7:0] <= "9")) begin
    errors++;
    $display("ERROR: VERSION 0x%08h (\"%s\"), expected ASCII \"d.dd\"", ver, ver);
  end
  if (!(date[31:24] >= 8'h01 && date[31:24] <= 8'h12 && date[23:16] >= 8'h01 && date[23:16] <= 8'h31 &&
        date[15:0] >= 16'h2000)) begin
    errors++;
    $display("ERROR: DATE 0x%08h, expected BCD mm/dd/yyyy", date);
  end
  if (rsv !== 0) begin
    errors++;
    $display("ERROR: 0x%0h (reserved) reads 0x%08h", base + 'hC, rsv);
  end
  axil_write_err(base, 32'hA5A5_5A5A);
  axil_read_abs(base, v);
  checks++;
  if (v !== id) begin
    errors++;
    $display("ERROR: ID changed by a write (0x%08h)", v);
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
