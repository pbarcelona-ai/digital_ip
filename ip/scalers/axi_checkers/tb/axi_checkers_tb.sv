// ***************
// Filename: tb_axi_checkers.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axis_checker and axil_checker.
//   1. Legal traffic with random stalls must produce zero assertion errors
//      and hit the coverage bins.
//   2. Each protocol rule is then violated on purpose; the checker must flag
//      exactly that violation (error count increases). With `SVA_ON the SVA
//      properties are checked the same way.
// Date: 2026-09-26

`timescale 1ns/1ps
module tb_axi_checkers;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n = 0;
  int   errors = 0, checks = 0;

  // ---------------- AXI-Stream
  logic       tvalid = 0, tready = 0, tuser = 0, tlast = 0;
  logic [7:0] tdata = 0;
  int         fw = 4, fh = 3;
  axis_checker #(.DATA_W(8), .NAME("s")) u_s (.clk, .rst_n, .tvalid, .tready, .tdata,
                                                .tuser, .tlast, .frame_w(fw), .frame_h(fh));

  // ---------------- AXI-Lite
  logic [7:0]  awaddr = 0, araddr = 0;
  logic        awvalid = 0, awready = 0, wvalid = 0, wready = 0, bvalid = 0, bready = 0;
  logic        arvalid = 0, arready = 0, rvalid = 0, rready = 0;
  logic [31:0] wdata = 0, rdata = 0; logic [3:0] wstrb = 0; logic [1:0] bresp = 0, rresp = 0;
  axil_checker #(.ADDR_W(8), .NAME("l")) u_l (.*);

  task automatic expect_err(input string what, input int prev, input int now);
    checks++;
    if (now <= prev) begin errors++; $display("ERROR: checker missed %s", what); end
    else $display("detected: %s", what);
  endtask

  // legal stream frame, random stalls; the "sink" readiness is random
  task automatic stream_frame();
    for (int y = 0; y < fh; y++)
      for (int x = 0; x < fw; x++) begin
        @(negedge clk);
        while ($urandom_range(3, 0) == 0) begin tvalid = 0; tready = $urandom_range(1, 0); @(negedge clk); end
        tvalid = 1; tdata = $urandom; tuser = (x == 0 && y == 0); tlast = (x == fw - 1);
        tready = $urandom_range(1, 0);
        @(posedge clk);
        while (!tready) begin @(negedge clk); tready = $urandom_range(1, 0); @(posedge clk); end
      end
    @(negedge clk) begin tvalid = 0; tuser = 0; tlast = 0; end
  endtask

  // legal AXI-Lite write/read (acting as both master and slave)
  task automatic lite_write(input int order);
    @(negedge clk);
    awaddr = $urandom; wdata = $urandom; wstrb = 4'hF;
    if (order != 2) awvalid = 1;
    if (order != 1) wvalid  = 1;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    awvalid = 1; wvalid = 1;
    if (order == 1) begin awready = 1; @(negedge clk); awvalid = 0; awready = 0; wready = 1; end
    else if (order == 2) begin wready = 1; @(negedge clk); wvalid = 0; wready = 0; awready = 1; end
    else begin awready = 1; wready = 1; end
    @(negedge clk); awvalid = 0; wvalid = 0; awready = 0; wready = 0;
    bvalid = 1; bresp = 0; bready = 0;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    bready = 1; @(negedge clk); bvalid = 0; bready = 0;
  endtask
  task automatic lite_read();
    @(negedge clk); araddr = $urandom; arvalid = 1;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    arready = 1; @(negedge clk); arvalid = 0; arready = 0;
    rvalid = 1; rdata = $urandom; rresp = 0; rready = 0;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    rready = 1; @(negedge clk); rvalid = 0; rready = 0;
  endtask

  initial begin
    int e;
    repeat (3) @(posedge clk); rst_n = 1;
    // ---------------- phase 1: legal traffic
    repeat (20) stream_frame();
    repeat (40) begin lite_write($urandom_range(2, 0)); lite_read(); end
    repeat (3) @(posedge clk);
    checks += 2;
    if (u_s.errors != 0) begin errors++; $display("ERROR: false stream assertion"); end
    if (u_l.errors != 0) begin errors++; $display("ERROR: false lite assertion"); end
    checks += 2;
    if (u_s.bins_hit() < 9)  begin errors++; $display("ERROR: stream coverage %0d", u_s.bins_hit()); end
    if (u_l.bins_hit() < 9)  begin errors++; $display("ERROR: lite coverage %0d", u_l.bins_hit()); end
    u_s.report(); u_l.report();
`ifdef SVA_ON
    checks++;
    if (u_s.sva_errors != 0 || u_l.sva_errors != 0) begin errors++; $display("ERROR: false SVA failure"); end
`endif

    // ---------------- phase 2: stream violations
    e = u_s.errors;   // valid retracted
    @(negedge clk) begin tvalid = 1; tready = 0; tuser = 1; tlast = 0; end
    @(negedge clk) tvalid = 0;
    @(negedge clk); expect_err("AXIS_HOLD", e, u_s.errors);
    e = u_s.errors;   // data changes while stalled
    @(negedge clk) begin tvalid = 1; tready = 0; tdata = 8'h11; end
    @(negedge clk) tdata = 8'h22;
    @(negedge clk) begin tready = 1; end
    @(negedge clk) begin tvalid = 0; tready = 0; end
    expect_err("AXIS_STABLE", e, u_s.errors);
    e = u_s.errors;   // X payload
    @(negedge clk) begin tvalid = 1; tready = 1; tdata = 8'bx; tuser = 1; tlast = 0; end
    @(negedge clk) begin tvalid = 0; tready = 0; tdata = 0; end
    expect_err("AXIS_X_PAYLOAD", e, u_s.errors);
    // framing: send partial frame then new SOF, and a wrong tlast
    rst_n = 0; @(negedge clk); rst_n = 1;
    e = u_s.errors;
    @(negedge clk) begin tvalid = 1; tready = 1; tuser = 1; tlast = 1; tdata = 1; end   // tlast at x=0
    @(negedge clk) begin tuser = 0; tlast = 0; end
    @(negedge clk) begin tvalid = 0; tready = 0; end
    expect_err("AXIS_EOL", e, u_s.errors);
    e = u_s.errors;
    @(negedge clk) begin tvalid = 1; tready = 1; tuser = 1; tlast = 0; end             // SOF mid-frame
    @(negedge clk) begin tvalid = 0; tready = 0; tuser = 0; end
    expect_err("AXIS_FRAME", e, u_s.errors);
    rst_n = 0; @(negedge clk); rst_n = 1;
    e = u_s.errors;
    @(negedge clk) begin tvalid = 1; tready = 1; tuser = 0; tlast = 0; end             // no SOF
    @(negedge clk) begin tvalid = 0; tready = 0; end
    expect_err("AXIS_SOF", e, u_s.errors);

    // ---------------- phase 3: AXI-Lite violations
    e = u_l.errors;
    @(negedge clk) begin awvalid = 1; awaddr = 8'h10; end
    @(negedge clk) awaddr = 8'h14;
    @(negedge clk) begin awvalid = 0; end
    expect_err("AXIL_STABLE_AW", e, u_l.errors);
    e = u_l.errors;
    @(negedge clk) arvalid = 1;
    @(negedge clk) arvalid = 0;
    @(negedge clk);
    expect_err("AXIL_HOLD_AR", e, u_l.errors);
    rst_n = 0; @(negedge clk); rst_n = 1;
    e = u_l.errors;
    @(negedge clk) begin bvalid = 1; bready = 1; end                                   // B without AW/W
    @(negedge clk) begin bvalid = 0; bready = 0; end
    expect_err("AXIL_BRESP_EARLY", e, u_l.errors);
    rst_n = 0; @(negedge clk); rst_n = 1;
    e = u_l.errors;
    @(negedge clk) begin rvalid = 1; rready = 1; end                                   // R without AR
    @(negedge clk) begin rvalid = 0; rready = 0; end
    expect_err("AXIL_RRESP_EARLY", e, u_l.errors);
    e = u_l.errors;
    @(negedge clk) begin arvalid = 1; arready = 1; end
    @(negedge clk) begin arvalid = 0; arready = 0; rvalid = 1; rresp = 2'b10; rready = 0; end
    @(negedge clk) rdata = ~rdata;                                                     // unstable R
    @(negedge clk) rready = 1;
    @(negedge clk) begin rvalid = 0; rready = 0; rresp = 0; end
    expect_err("AXIL_STABLE_R + AXIL_RESP", e + 1, u_l.errors);
`ifdef SVA_ON
    expect_err("SVA stream properties", 0, u_s.sva_errors);
    expect_err("SVA AXI-Lite properties", 0, u_l.sva_errors);
`endif

    if (errors == 0) $display("TB_RESULT: PASS  checks=%0d", checks);
    else             $display("TB_RESULT: FAIL  checks=%0d errors=%0d", checks, errors);
    $finish;
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_axi_checkers.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_axi_checkers.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_axi_checkers);
    end
  end
endmodule
