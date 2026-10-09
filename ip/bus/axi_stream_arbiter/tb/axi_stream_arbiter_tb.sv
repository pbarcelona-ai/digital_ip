// ***************
// Filename: axi_stream_arbiter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axi_stream_arbiter. Four
//   sources send random-length packets with random gaps; the scoreboard
//   verifies that packets are never interleaved, per-source order and
//   content are preserved, tid identifies the source, round-robin is fair
//   under saturation, fixed priority always favours input 0, and the hog
//   timeout breaks up an endless packet. Prints TEST PASSED on success.
//   The test tasks are in tests/axi_stream_arbiter_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module axi_stream_arbiter_tb;
  localparam int N = 4, DW = 16;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [N*DW-1:0] sd = 0;
  logic [N*2-1:0] sk = 0;
  logic [N-1:0] sl = 0, sv = 0, sr;
  logic [N*1-1:0] su = 0;
  logic [DW-1:0] md;
  logic [1:0] mk;
  logic ml, mu, mv, mr = 0;
  logic [1:0] mid;
  logic hog;
  axi_stream_arbiter #(.NIN(N), .DATA_W(DW), .USER_W(1), .PRIORITY(0), .TIMEOUT(0)) dut (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axis_tdata(sd),
    .s_axis_tkeep(sk),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .m_axis_tdata(md),
    .m_axis_tkeep(mk),
    .m_axis_tlast(ml),
    .m_axis_tuser(mu),
    .m_axis_tid(mid),
    .m_axis_tvalid(mv),
    .m_axis_tready(mr),
    .hog_o(hog)
  );
  // fixed-priority instance (same stimulus) and a hog-timeout instance
  logic [DW-1:0] pd;
  logic pl, pv, pu;
  logic [1:0] pid, pk;
  logic [N-1:0] psr;
  logic phog;
  axi_stream_arbiter #(.NIN(N), .DATA_W(DW), .USER_W(1), .PRIORITY(1)) dutp (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axis_tdata(sd),
    .s_axis_tkeep(sk),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(psr),
    .m_axis_tdata(pd),
    .m_axis_tkeep(pk),
    .m_axis_tlast(pl),
    .m_axis_tuser(pu),
    .m_axis_tid(pid),
    .m_axis_tvalid(pv),
    .m_axis_tready(1'b1),
    .hog_o(phog)
  );
  // hog-timeout instance: input 0 never sends tlast
  logic [N-1:0] hv = 4'b0011, hr;
  logic hov, hhog;
  logic [1:0] hid;
  axi_stream_arbiter #(.NIN(N), .DATA_W(DW), .USER_W(1), .PRIORITY(0), .TIMEOUT(4)) duth (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axis_tdata(sd),
    .s_axis_tkeep(sk),
    .s_axis_tlast('0),
    .s_axis_tuser(su),
    .s_axis_tvalid(hv),
    .s_axis_tready(hr),
    .m_axis_tdata(),
    .m_axis_tkeep(),
    .m_axis_tlast(),
    .m_axis_tuser(),
    .m_axis_tid(hid),
    .m_axis_tvalid(hov),
    .m_axis_tready(1'b1),
    .hog_o(hhog)
  );
  int hogs = 0;
  bit saw1 = 0;
  always @(posedge clk) begin
    if (hhog) hogs++;
    if (hov && hid == 1) saw1 = 1;
  end
  int errors = 0;
  int gaps_en = 1;
  logic [DW+2:0] exp_q[$];
  int pkts_in [N];
  int pkts_out [N];
  int beats_left [N];
  int cur_owner = -1;
  int total_pkts = 0;
  int prio_wrong = 0, prio_checks = 0;
  logic [3:0] wait_cnt;
  initial for (int i = 0; i < N; i++) begin
    pkts_in[i] = 0;
    pkts_out[i] = 0;
    beats_left[i] = 0;
  end
  always @(posedge clk) if (rst_n) begin
    // record accepted input beats
    for (int i = 0; i < N; i++) if (sv[i] && sr[i]) exp_q.push_back({i[1:0], sl[i], sd[i*DW +: DW]});
    // check output beats
    if (mv && mr) begin
      if (cur_owner == -1) cur_owner = mid;
      if (mid != cur_owner) begin
        errors++;
        $display("ERROR interleave: tid %0d during packet of %0d", mid, cur_owner);
      end
      begin
        int found;
        logic [DW+2:0] tmp;
        found = -1;
        for (int k = 0; k < exp_q.size() && found < 0; k++) begin
          tmp = exp_q[k];
          if (tmp[DW+2:DW+1] == mid) found = k;
        end
        if (found < 0) begin
          errors++;
          $display("ERROR unexpected beat from %0d", mid);
        end
        else begin
          logic [DW+2:0] e;
          e = exp_q[found];
          exp_q.delete(found);
          if (md !== e[DW-1:0] || ml !== e[DW]) begin
            errors++;
            $display("ERROR src %0d data %h/%h last %b/%b", mid, md, e[DW-1:0], ml, e[DW]);
          end
        end
      end
      if (ml) begin
        cur_owner = -1;
        pkts_out[mid]++;
      end
    end
  end
  // test tasks: tests/axi_stream_arbiter_tests.sv
  `include "axi_stream_arbiter_tests.sv"
  always @(posedge clk) mr <= ($urandom_range(0, 9) < 7);
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi_stream_arbiter_tb.vcd");
      $dumpvars(0, axi_stream_arbiter_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    fork
      source(0, 60);
      source(1, 60);
      source(2, 60);
      source(3, 60);
    join
    repeat (30) @(posedge clk);
    if (exp_q.size() != 0) begin
      errors++;
      $display("ERROR %0d beats undelivered", exp_q.size());
    end
    for (int i = 0; i < N; i++) begin
      if (pkts_out[i] != pkts_in[i]) begin
        errors++;
        $display("ERROR src %0d: in %0d out %0d packets", i, pkts_in[i], pkts_out[i]);
      end
    end
    // fairness under saturation: all inputs send 1-beat packets continuously for 400 clocks; each should get about 25%
    begin
      int cnt [N];
      for (int i = 0; i < N; i++) cnt[i] = 0;
      gaps_en = 0;
      @(posedge clk);
      #1;
      force mr = 1'b1;
      for (int i = 0; i < N; i++) begin
        sv[i] = 1;
        sl[i] = 1;
        sk[i*2 +: 2] = 2'b11;
      end
      repeat (400) begin
        @(posedge clk);
        if (mv) cnt[mid]++;
      end
      for (int i = 1; i < N; i++) if (cnt[i] - cnt[0] > 10 || cnt[0] - cnt[i] > 10) begin
        errors++;
        $display("ERROR unfair %0d vs %0d", cnt[0], cnt[i]);
      end
      if (cnt[0] < 40) begin
        errors++;
        $display("ERROR low throughput %0d", cnt[0]);
      end
      // fixed priority instance: input 0 always saturated => only tid 0 seen
      begin
        int seen_other = 0;
        repeat (100) begin
          @(posedge clk);
          if (pv && pid != 0) seen_other++;
        end
        if (seen_other != 0) begin
          errors++;
          $display("ERROR fixed priority: %0d beats from other inputs", seen_other);
        end
      end
      #1 sv = 0;
      release mr;
      repeat (20) @(posedge clk);
    end
    if (hogs == 0 || !saw1) begin
      errors++;
      $display("ERROR hog timeout: hogs %0d saw1 %b", hogs, saw1);
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
