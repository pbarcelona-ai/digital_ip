// ***************
// Filename: memory_arbiter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for memory_arbiter. Four clients
//   issue random reads and writes to a memory model with variable read
//   latency and random ready stalls. Every read must return the value most
//   recently written (scoreboarded per address, each client owns its own
//   address region so ordering is well defined), responses must reach the
//   issuing client, round-robin must be fair under full load, fixed
//   priority must always favour client 0, and an unsolicited response must
//   set err_o. Prints TEST PASSED on success.
//   The test tasks are in tests/memory_arbiter_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module memory_arbiter_tb;
  localparam int N = 4, AW = 8, DW = 16;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [N-1:0] req = 0, we = 0, rdy, rvl;
  logic [N*AW-1:0] addr = 0;
  logic [N*DW-1:0] wdat = 0;
  logic [DW-1:0] rdat;
  logic mreq, mwe, mrdy = 1, mrv = 0;
  logic [AW-1:0] maddr;
  logic [DW-1:0] mwd, mrd = 0;
  logic err, clr = 0;
  memory_arbiter #(.CLIENTS(N), .ADDR_W(AW), .DATA_W(DW), .PRIORITY(0), .MAX_OUT(4)) dut
    (
    .clk,
    .rst_n,
    .c_req_i(req),
    .c_we_i(we),
    .c_addr_i(addr),
    .c_wdata_i(wdat),
    .c_ready_o(rdy),
    .c_rvalid_o(rvl),
    .c_rdata_o(rdat),
    .m_req_o(mreq),
    .m_we_o(mwe),
    .m_addr_o(maddr),
    .m_wdata_o(mwd),
    .m_ready_i(mrdy),
    .m_rvalid_i(mrv),
    .m_rdata_i(mrd),
    .clr_err_i(clr),
    .err_o(err)
  );
  // fixed-priority instance sharing stimulus
  logic [N-1:0] rdy_p;
  logic mreq_p, mwe_p;
  logic [AW-1:0] maddr_p;
  logic [DW-1:0] mwd_p;
  logic [N-1:0] rvl_p;
  logic [DW-1:0] rdat_p;
  logic err_p;
  memory_arbiter #(.CLIENTS(N), .ADDR_W(AW), .DATA_W(DW), .PRIORITY(1)) dutp
    (
    .clk,
    .rst_n,
    .c_req_i(req),
    .c_we_i(we),
    .c_addr_i(addr),
    .c_wdata_i(wdat),
    .c_ready_o(rdy_p),
    .c_rvalid_o(rvl_p),
    .c_rdata_o(rdat_p),
    .m_req_o(mreq_p),
    .m_we_o(mwe_p),
    .m_addr_o(maddr_p),
    .m_wdata_o(mwd_p),
    .m_ready_i(1'b1),
    .m_rvalid_i(1'b0),
    .m_rdata_i('0),
    .clr_err_i(1'b0),
    .err_o(err_p)
  );
  int errors = 0;
  // test tasks: tests/memory_arbiter_tests.sv
  `include "memory_arbiter_tests.sv"
  // memory model with 1-4 cycle read latency, in-order responses
  logic [DW-1:0] mem [0:255];
  logic [DW-1:0] rq[$];
  int dq[$];
  int cyc = 0;
  always @(posedge clk) begin
    cyc++;
    mrv <= 0;
    if (dq.size() > 0 && dq[0] <= cyc) begin
      mrv <= 1;
      mrd <= rq[0];
      void'(rq.pop_front());
      void'(dq.pop_front());
    end
    mrdy <= ($urandom_range(0, 9) < 7);
    if (mreq && mrdy) begin
      if (mwe) mem[maddr] <= mwd;
      else begin
        rq.push_back(mem[maddr]);
        dq.push_back(cyc + $urandom_range(1, 4) + (dq.size() > 0 ? 0 : 0));
      end
    end
  end
  // clients: each owns 64 addresses (client id in the top 2 bits) so per-address data is unambiguous
  logic [DW-1:0] shadow [0:255];
  bit valid [0:255];
  int outstanding_owner[$];
  logic [DW-1:0] exp_data[$];
  int reads_done [N];
  int grants [N];
  logic [N-1:0] fired;
  always @(posedge clk) if (rst_n) begin
    fired = rdy & req;
    for (int i = 0; i < N; i++) if (fired[i]) begin
      grants[i]++;
      if (we[i]) begin
        shadow[addr[i*AW +: AW]] = wdat[i*DW +: DW];
        valid[addr[i*AW +: AW]] = 1;
      end
      else begin
        outstanding_owner.push_back(i);
        exp_data.push_back(shadow[addr[i*AW +: AW]]);
      end
    end
    if (|rvl) begin
      int o;
      o = outstanding_owner.pop_front();
      check(rvl == (N'(1) << o), $sformatf("response routed to %b, expected client %0d", rvl, o));
      check(rdat === exp_data[0], $sformatf("read data %h exp %h", rdat, exp_data[0]));
      void'(exp_data.pop_front());
      reads_done[o]++;
    end
  end
  initial begin
    for (int i = 0; i < 256; i++) begin
      mem[i] = 0;
      shadow[i] = 0;
      valid[i] = 0;
    end
    for (int i = 0; i < N; i++) begin
      reads_done[i] = 0;
      grants[i] = 0;
    end
    if ($test$plusargs("vcd")) begin
      $dumpfile("memory_arbiter_tb.vcd");
      $dumpvars(0, memory_arbiter_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    // Phase 1: random traffic
    repeat (4000) begin
      @(posedge clk);
      #1;
      for (int i = 0; i < N; i++) begin
        if (fired[i] || !req[i]) begin
          req[i] = ($urandom_range(0, 9) < 6);
          we[i] = ($urandom_range(0, 9) < 5);
          addr[i*AW +: AW] = {2'(i), 6'($urandom)};
          wdat[i*DW +: DW] = $urandom;
        end
      end
    end
    req = 0;
    repeat (30) @(posedge clk);
    check(outstanding_owner.size() == 0, "reads still outstanding");
    // Phase 2: fairness under full load with writes only
    for (int i = 0; i < N; i++) grants[i] = 0;
    we = '1;
    #1;
    mrdy = 1;
    repeat (400) begin
      @(posedge clk);
      #1 req = '1;
    end
    for (int i = 1; i < N; i++) check(grants[i] - grants[0] <= 40 && grants[0] - grants[i] <= 40, $sformatf("unfair: %0d vs %0d", grants[0], grants[i]));
    check(grants[0] > 50, "no grants");
    // Phase 3: fixed priority: client 0 wins whenever it requests
    @(posedge clk);
    #1 req = 4'b1111;
    #1;
    check(rdy_p == 4'b0001 && mreq_p, "fixed priority client 0");
    req = 4'b1110;
    #1;
    check(rdy_p == 4'b0010, "fixed priority next");
    req = 0;
    // Phase 4: unsolicited response sets err_o
    repeat (10) @(posedge clk);
    check(!err, "err before");
    force dut.m_rvalid_i = 1'b1;
    @(posedge clk);
    #1;
    release dut.m_rvalid_i;
    check(err, "unsolicited response not flagged");
    clr = 1;
    @(posedge clk);
    #1 clr = 0;
    @(posedge clk);
    #1;
    check(!err, "err clear");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
