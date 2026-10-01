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
// Date: 2026-09-26

`timescale 1ns/1ps
module tb_axil_regbus;
  localparam int ADDR_W = 8;              // 64 word registers

  logic clk = 0; always #5 clk = ~clk;    // 100 MHz clock
  logic rst_n = 0;
  int   errors = 0, checks = 0;           // result counters

  // AXI4-Lite master side (driven by the tasks below)
  logic [ADDR_W-1:0] awaddr = '0, araddr = '0;
  logic awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  logic [31:0] wdata = '0; logic [3:0] wstrb = '0;
  wire awready, wready, bvalid, arready, rvalid;
  wire [1:0] bresp, rresp; wire [31:0] rdata;

  // register bus side
  logic              reg_wr, reg_rd;
  logic [ADDR_W-1:0] reg_waddr, reg_raddr;
  logic [31:0]       reg_wdata, reg_rdata;
  logic [3:0]        reg_wstrb;

  // Device under test
  axil_regbus #(.ADDR_W(ADDR_W)) dut (
    .clk, .rst_n,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .reg_wr, .reg_waddr, .reg_wdata, .reg_wstrb, .reg_rd, .reg_raddr, .reg_rdata);

  // AXI4-Lite protocol checker + coverage on the DUT port
  axil_checker #(.ADDR_W(ADDR_W), .NAME("s_axil")) u_axil_chk (
    .clk, .rst_n, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
    .bresp, .bvalid, .bready, .araddr, .arvalid, .arready, .rdata, .rresp, .rvalid, .rready);

  // register file on the simple bus (registered read, as required)
  logic [31:0] rf [64];
  int n_wr = 0, n_rd = 0;
  always_ff @(posedge clk) begin
    if (reg_wr) begin
      n_wr++;
      for (int b = 0; b < 4; b++)
        if (reg_wstrb[b]) rf[reg_waddr[7:2]][b*8 +: 8] <= reg_wdata[b*8 +: 8];
    end
    if (reg_rd) begin
      n_rd++;
      reg_rdata <= rf[reg_raddr[7:2]];
    end
  end

  // expected register contents
  logic [31:0] model [64];

  // AXI write with a random AW/W order and delay and late bready; the
  // model is updated with the strobed bytes
  task automatic wr(input int a, input logic [31:0] d, input logic [3:0] s);
    int order = $urandom_range(2, 0);        // 0: together, 1: AW first, 2: W first
    bit aw_done = 0, w_done = 0;
    int delay = $urandom_range(3, 0);
    @(negedge clk);
    awaddr = ADDR_W'(a); wdata = d; wstrb = s;
    awvalid = (order != 2); wvalid = (order != 1);
    while (!(aw_done && w_done)) begin
      @(posedge clk);
      if (awvalid && awready) aw_done = 1;
      if (wvalid && wready)   w_done  = 1;
      @(negedge clk);
      if (aw_done) awvalid = 0;
      if (w_done)  wvalid  = 0;
      if (delay > 0) delay--;
      else begin
        if (!aw_done) awvalid = 1;
        if (!w_done)  wvalid  = 1;
      end
    end
    repeat ($urandom_range(3, 0)) @(negedge clk);   // late bready
    bready = 1;
    do @(posedge clk); while (!bvalid);
    checks++;
    if (bresp !== 2'b00) begin errors++; $display("ERROR: bresp"); end
    @(negedge clk) bready = 0;
    for (int b = 0; b < 4; b++) if (s[b]) model[a >> 2][b*8 +: 8] = d[b*8 +: 8];
  endtask

  // AXI read with late rready; R data must stay stable while stalled
  // and must equal the model
  task automatic rd(input int a);
    logic [31:0] d0;
    @(negedge clk); araddr = ADDR_W'(a); arvalid = 1;
    do @(posedge clk); while (!arready);
    @(negedge clk); arvalid = 0;
    wait (rvalid); d0 = rdata;
    repeat ($urandom_range(3, 0)) begin       // rdata must stay stable
      @(negedge clk);
      if (rdata !== d0 || !rvalid) begin errors++; $display("ERROR: R channel unstable"); end
    end
    @(negedge clk) rready = 1;
    do @(posedge clk); while (!rvalid);
    checks++;
    if (rdata !== model[a >> 2] || rresp !== 2'b00) begin
      errors++;
      $display("ERROR: read 0x%02h got 0x%08h exp 0x%08h", a, rdata, model[a >> 2]);
    end
    @(negedge clk) rready = 0;
  endtask

  // Main sequence: initialise every register, then random traffic,
  // then compare the number of bus pulses with the transactions issued
  initial begin
    int nw, nr;
    nw = 0; nr = 0;
    for (int i = 0; i < 64; i++) begin model[i] = 0; rf[i] = 0; end
    repeat (4) @(posedge clk); rst_n = 1;
    for (int i = 0; i < 64; i++) begin wr(i * 4, $urandom, 4'hF); nw++; end
    for (int i = 0; i < 2000; i++) begin
      int a;
      a = $urandom_range(63, 0) * 4;
      if ($urandom_range(1, 0)) begin wr(a, $urandom, 4'($urandom_range(15, 0))); nw++; end
      else begin rd(a); nr++; end
    end
    repeat (5) @(posedge clk);
    checks += 2;
    if (n_wr != nw) begin errors++; $display("ERROR: reg_wr pulses %0d != writes %0d", n_wr, nw); end
    if (n_rd != nr) begin errors++; $display("ERROR: reg_rd pulses %0d != reads %0d", n_rd, nr); end
    u_axil_chk.report();
    checks++;
    if (u_axil_chk.errors + u_axil_chk.sva_errors != 0) begin
      errors++; $display("ERROR: AXI-Lite protocol assertion failures");
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
