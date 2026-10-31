// ***************
// Filename: axil_core_gate_tb.sv
// Author: FPGA Cores 4 U
// Description: Unit test of axil_core_gate (src/axil_core_gate.sv): random
//   AXI4-Lite reads and writes while the core logic is randomly put into
//   and released from reset (core_rel_i = SYSCTL CORE_RESET, core_up_i its
//   synchronised state some clocks later). Checks: every access gets exactly
//   one response; with the gate open it goes to the bridge (a slave model
//   that answers OKAY and its own read data, random delays, held in reset
//   while pass_o is low) and its response comes back; with CORE_RESET clear
//   it is answered by the gate with SLVERR and read data 0; while the core
//   logic is being released (CORE_RESET set, not yet up) a new access waits
//   for the gate to open; an access in flight when the gate closes completes
//   once (SLVERR); pass_o changes only between accesses; the bridge never
//   sees a valid while the gate is closed.
//   Run: tb/unit/run_unit.sh axil_core_gate (Icarus) - PASS / FAIL and a
//   timeout.
// Date: 2026-10-26
`timescale 1ns / 1ps
`default_nettype none
module axil_core_gate_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic core_up = 0, core_rel = 0, pass;
  axil_if #(.ADDR_W(16)) s ();
  axil_if #(.ADDR_W(16)) m ();
  axil_core_gate dut (
    .clk,
    .rst_n,
    .core_up_i(core_up),
    .core_rel_i(core_rel),
    .pass_o(pass),
    .s_axil(s),
    .m_axil(m)
  );

  int errors = 0;
  task automatic check(input bit c, input string msg);
    if (c !== 1'b1) begin
      errors++;
      if (errors <= 10) $display("[%t] FAIL: %s", $realtime, msg);
    end
  endtask

  // ---------------- the core logic's reset: CORE_RESET toggled at random, core_up follows it after a delay
  // (released: some clocks later, as the reset_sync + bit_sync chain; asserted: one clock later)
  int phase_open = 0, phase_closed = 0, phase_rel = 0;
  initial begin
    wait (rst_n);
    forever begin
      repeat (50 + $urandom % 400) @(posedge clk);
      core_rel <= !core_rel;
      if (core_rel) begin                         // being cleared: the core logic goes into reset at once
        @(posedge clk);
        core_up <= 0;
      end else begin                              // being set: the core logic comes out some clocks later
        repeat (3 + $urandom % 20) @(posedge clk);
        if (core_rel) core_up <= 1;
      end
    end
  end
  always @(posedge clk) if (rst_n) begin
    if (pass) phase_open++;
    else if (!core_rel) phase_closed++;
    else phase_rel++;
  end

  // ---------------- the bridge: one access at a time, random delays, reset while pass is low
  logic m_got_aw, m_got_w, m_got_ar;
  logic [15:0] m_ar_addr;
  always @(posedge clk) begin
    if (!pass) begin
      m.awready <= 0;
      m.wready <= 0;
      m.arready <= 0;
      m.bvalid <= 0;
      m.rvalid <= 0;
      m_got_aw <= 0;
      m_got_w <= 0;
      m_got_ar <= 0;
    end else begin
      m.awready <= !m_got_aw && !(m.awvalid && m.awready) && $urandom % 2;
      m.wready <= !m_got_w && !(m.wvalid && m.wready) && $urandom % 2;
      m.arready <= !m_got_ar && !(m.arvalid && m.arready) && $urandom % 2;
      if (m.awvalid && m.awready) m_got_aw <= 1;
      if (m.wvalid && m.wready) m_got_w <= 1;
      if (m.arvalid && m.arready) begin
        m_got_ar <= 1;
        m_ar_addr <= m.araddr;
      end
      if (m_got_aw && m_got_w && !m.bvalid && $urandom % 3 == 0) begin
        m.bvalid <= 1;
        m.bresp <= 2'b00;
      end else if (m.bvalid && m.bready) begin
        m.bvalid <= 0;
        m_got_aw <= 0;
        m_got_w <= 0;
      end
      if (m_got_ar && !m.rvalid && $urandom % 3 == 0) begin
        m.rvalid <= 1;
        m.rresp <= 2'b00;
        m.rdata <= {16'hC0DE, m_ar_addr};
      end else if (m.rvalid && m.rready) begin
        m.rvalid <= 0;
        m_got_ar <= 0;
      end
    end
  end
  // nothing reaches the bridge while the gate is closed; pass changes only between accesses
  logic pass_q;
  logic s_busy;                                   // a CPU access in flight (some handshake done, response not yet)
  always @(posedge clk) begin
    pass_q <= pass;
    if (rst_n) begin
      check(pass || !(m.awvalid || m.wvalid || m.arvalid), "a valid reached the bridge while the gate was closed");
      check(!(pass && !pass_q) || !s_busy, $sformatf("the gate opened during an access (gate got %b%b%b, cpu aw %b w %b ar %b rel %b up %b)", dut.got_aw, dut.got_w, dut.got_ar, s.awvalid, s.wvalid, s.arvalid, core_rel, core_up));
    end
  end

  // ---------------- the CPU side
  initial begin
    s.awvalid = 0;
    s.wvalid = 0;
    s.bready = 0;
    s.arvalid = 0;
    s.rready = 0;
    s.awaddr = '0;
    s.araddr = '0;
    s.wdata = '0;
    s.wstrb = '0;
    s_busy = 0;
  end
  int n_ok = 0, n_err = 0, n_wait = 0, n_cut = 0;
  // one access: wr (both AW and W at once) or a read; the response and whether the gate was open when the
  // access was presented / at its end
  task automatic access(input bit wr, input logic [15:0] a);
    bit got_a, got_w, got_r, open0, rel0, waited;
    int t;
    logic [1:0] resp;
    logic [31:0] data;
    @(negedge clk);
    open0 = pass;
    rel0 = core_rel;
    got_a = 0;
    got_w = !wr;
    got_r = 0;
    waited = 0;
    if (wr) begin
      s.awaddr = a;
      s.wdata = $urandom;
      s.wstrb = 4'hF;
      s.awvalid = 1;
      s.wvalid = 1;
    end else begin
      s.araddr = a;
      s.arvalid = 1;
    end
    s.bready = 0;                                    // the response taken after a random delay (up to tens of
    s.rready = 0;                                    // clocks: the gate's own answer outlasts a release)
    for (t = 0; t < 5000 && !got_r; t++) begin
      @(posedge clk);
      if (wr && s.awvalid && s.awready) got_a = 1;
      if (wr && s.wvalid && s.wready) got_w = 1;
      if (!wr && s.arvalid && s.arready) got_a = 1;
      if (got_a || (wr && got_w)) s_busy = 1;           // something taken (got_w starts set for a read)
      if (!got_a && !pass && core_rel) waited = 1;
      if (wr && s.bvalid && s.bready) begin
        check(got_a && got_w, "B before both AW and W were taken");
        got_r = 1;
        resp = s.bresp;
      end
      if (!wr && s.rvalid && s.rready) begin
        check(got_a, "R before AR was taken");
        got_r = 1;
        resp = s.rresp;
        data = s.rdata;
      end
      @(negedge clk);
      if (got_a) begin
        s.awvalid = 0;
        s.arvalid = 0;
      end
      if (got_w) s.wvalid = 0;
      if (wr && !s.bready && $urandom % 8 == 0) s.bready = 1;
      if (!wr && !s.rready && $urandom % 8 == 0) s.rready = 1;
    end
    check(got_r, $sformatf("%s %h: no response (timeout)", wr ? "write" : "read", a));
    s.bready = 0;
    s.rready = 0;
    s_busy = 0;
    // one response only: none in the next clocks
    repeat (3) begin
      @(posedge clk);
      check(!s.bvalid && !s.rvalid, "a second response");
    end
    if (resp == 2'b00) begin
      n_ok++;
      check(wr || data == {16'hC0DE, a}, $sformatf("read %h through the gate: %h", a, data));
    end else begin
      check(resp == 2'b10, $sformatf("response %0d, OKAY or SLVERR expected", resp));
      check(wr || data == 32'd0, "SLVERR read data not 0");
      n_err++;
      if (open0) n_cut++;                        // the gate closed during the access
    end
    if (!open0 && !rel0) check(resp == 2'b10 || pass, "an access with CORE_RESET clear was not answered SLVERR");
    if (waited) n_wait++;
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    for (int n = 0; n < 3000; n++) begin
      access($urandom % 2, 16'($urandom));
      repeat ($urandom % 4) @(posedge clk);
    end
    check(n_ok > 300 && n_err > 300 && n_wait > 5, $sformatf("coverage: %0d OKAY, %0d SLVERR, %0d waited", n_ok,
                                                             n_err, n_wait));
    $display("axil_core_gate_tb: %0d accesses passed (OKAY), %0d answered SLVERR (%0d cut by the reset), %0d waited for the release; %0d errors",
             n_ok, n_err, n_cut, n_wait, errors);
    $display("  clocks open %0d, closed (CORE_RESET clear) %0d, being released %0d", phase_open, phase_closed, phase_rel);
    if (errors == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end
  initial begin
    #20ms;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
`default_nettype wire
