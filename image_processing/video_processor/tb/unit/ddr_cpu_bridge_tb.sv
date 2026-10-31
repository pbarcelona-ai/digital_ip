// ***************
// Filename: ddr_cpu_bridge_tb.sv
// Author: FPGA Cores 4 U
// Description: Unit test of ddr_cpu_bridge (src/ddr_cpu_bridge.sv): random
//   AXI4-Lite reads and writes (byte strobes, AW before / with / after W, AR
//   presented with a write) against a word model of the memory; the AXI4
//   side an always-random-ready single-beat slave (256-bit beats, the bytes
//   outside the strobes kept) that checks AWLEN / AWSIZE / AWBURST, the beat
//   alignment and WLAST, and that no valid is withdrawn before its ready.
//   Run: tb/unit/run_unit.sh ddr_cpu_bridge (Icarus) - PASS / FAIL and a
//   timeout.
// Date: 2026-10-26
`timescale 1ns / 1ps
`default_nettype none
module ddr_cpu_bridge_tb;
  localparam int ADDR_W = 12;                    // a 4 KB window: 128 beats
  localparam int NW = (1 << ADDR_W) / 4;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  axil_if #(.ADDR_W(ADDR_W)) s ();
  logic [3:0]   awid, bid, arid, rid;
  logic [31:0]  awaddr, araddr;
  logic [7:0]   awlen, arlen;
  logic [2:0]   awsize, arsize;
  logic [1:0]   awburst, arburst, bresp, rresp;
  logic         awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  logic [255:0] wdata, rdata;
  logic [31:0]  wstrb;
  ddr_cpu_bridge #(.ADDR_W(ADDR_W), .ID_W(4), .ID(2)) dut (
    .clk,
    .rst_n,
    .s_axil(s),
    .m_axi_awid(awid),
    .m_axi_awaddr(awaddr),
    .m_axi_awlen(awlen),
    .m_axi_awsize(awsize),
    .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bid(bid),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready)
  );

  int errors = 0;
  task automatic check(input bit c, input string m);
    if (c !== 1'b1) begin
      errors++;
      if (errors <= 10) $display("[%t] FAIL: %s", $realtime, m);
    end
  endtask

  // ---------------- the AXI4 slave: memory of beats, random readies, one write and one read at a time
  logic [7:0] mem [1 << ADDR_W];
  logic       aw_hold, w_hold, ar_hold;          // a valid seen without its ready: it must stay
  logic [31:0] aw_q, ar_q;
  logic       aw_have, w_have, ar_have;
  logic [255:0] w_q;
  logic [31:0] ws_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      awready <= 0;
      wready <= 0;
      arready <= 0;
      bvalid <= 0;
      rvalid <= 0;
      aw_have <= 0;
      w_have <= 0;
      ar_have <= 0;
      aw_hold <= 0;
      w_hold <= 0;
      ar_hold <= 0;
    end else begin
      check(!aw_hold || awvalid, "AWVALID withdrawn before AWREADY");
      check(!w_hold || wvalid, "WVALID withdrawn before WREADY");
      check(!ar_hold || arvalid, "ARVALID withdrawn before ARREADY");
      aw_hold <= awvalid && !awready;
      w_hold <= wvalid && !wready;
      ar_hold <= arvalid && !arready;
      if (awvalid && awready) begin
        check(awlen == 0 && awsize == 3'd5 && awburst == 2'b01 && awaddr[4:0] == 0 && awid == 4'd2,
              $sformatf("AW: len %0d size %0d burst %0d addr %h id %0d", awlen, awsize, awburst, awaddr, awid));
        aw_q <= awaddr;
        aw_have <= 1;
      end
      if (wvalid && wready) begin
        check(wlast === 1'b1, "WLAST low on a single beat");
        w_q <= wdata;
        ws_q <= wstrb;
        w_have <= 1;
      end
      if (arvalid && arready) begin
        check(arlen == 0 && arsize == 3'd5 && arburst == 2'b01 && araddr[4:0] == 0 && arid == 4'd2,
              $sformatf("AR: len %0d size %0d burst %0d addr %h id %0d", arlen, arsize, arburst, araddr, arid));
        ar_q <= araddr;
        ar_have <= 1;
      end
      awready <= !aw_have && !(awvalid && awready) && ($urandom % 3 == 0);
      wready <= !w_have && !(wvalid && wready) && ($urandom % 3 == 0);
      arready <= !ar_have && !(arvalid && arready) && ($urandom % 3 == 0);
      if (aw_have && w_have && !bvalid && $urandom % 2) begin
        for (int i = 0; i < 32; i++) if (ws_q[i]) mem[aw_q[ADDR_W-1:0] + i] <= w_q[8*i +: 8];
        aw_have <= 0;
        w_have <= 0;
        bvalid <= 1;
        bresp <= 2'($urandom % 2) << 1;          // OKAY or SLVERR, passed back
      end else if (bvalid && bready) bvalid <= 0;
      if (ar_have && !rvalid && $urandom % 2) begin
        for (int i = 0; i < 32; i++) rdata[8*i +: 8] <= mem[ar_q[ADDR_W-1:0] + i];
        ar_have <= 0;
        rvalid <= 1;
        rresp <= 2'($urandom % 2) << 1;
      end else if (rvalid && rready) rvalid <= 0;
    end
  end
  assign bid = 4'd2;
  assign rid = 4'd2;
  assign rlast = 1'b1;

  // ---------------- the CPU side
  logic [31:0] model [NW];
  logic [1:0]  last_bresp, last_rresp;
  always @(posedge clk) if (bvalid && bready) last_bresp <= bresp;
  always @(posedge clk) if (rvalid && rready) last_rresp <= rresp;

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
  end

  // one write: AW and W in the order given (0 AW first, 1 together, 2 W first), with AR of rd_addr
  // presented alongside when with_rd (the read follows the write)
  task automatic write(input int a, input logic [31:0] d, input logic [3:0] strb, input int order,
                       input bit with_rd, input int rd_a, output logic [31:0] rd_d);
    bit aw_done, w_done, ar_done, b_done, r_done;
    aw_done = 0;
    w_done = 0;
    ar_done = !with_rd;
    b_done = 0;
    r_done = !with_rd;
    @(negedge clk);
    s.awaddr = ADDR_W'(a);
    s.wdata = d;
    s.wstrb = strb;
    s.awvalid = order != 2;
    s.wvalid = order != 0;
    if (with_rd) begin
      s.araddr = ADDR_W'(rd_a);
      s.arvalid = 1;
    end
    s.bready = 1;
    s.rready = 1;
    for (int t = 0; t < 2000 && !(aw_done && w_done && ar_done && b_done && r_done); t++) begin
      @(posedge clk);
      if (s.awvalid && s.awready) aw_done = 1;
      if (s.wvalid && s.wready) w_done = 1;
      if (s.arvalid && s.arready) begin
        ar_done = 1;
        check(b_done, "AR taken before the write's response");
      end
      if (s.bvalid && s.bready) begin
        b_done = 1;
        check(s.bresp == last_bresp, $sformatf("write %h: BRESP %0d, the slave's %0d", a, s.bresp, last_bresp));
      end
      if (s.rvalid && s.rready) begin
        r_done = 1;
        rd_d = s.rdata;
        check(s.rresp == last_rresp, $sformatf("read %h: RRESP %0d, the slave's %0d", rd_a, s.rresp, last_rresp));
      end
      @(negedge clk);
      if (aw_done) s.awvalid = 0;
      if (w_done) s.wvalid = 0;
      if (ar_done) s.arvalid = 0;
      if (order == 0 && aw_done) s.wvalid = !w_done;
      if (order == 2 && w_done) s.awvalid = !aw_done;
    end
    check(aw_done && w_done && b_done && ar_done && r_done, $sformatf("write %h: no response (timeout)", a));
    s.bready = 0;
    s.rready = 0;
  endtask
  task automatic read(input int a, output logic [31:0] d, output logic [1:0] resp);
    bit ar_done, r_done;
    ar_done = 0;
    r_done = 0;
    @(negedge clk);
    s.araddr = ADDR_W'(a);
    s.arvalid = 1;
    s.rready = 1;
    for (int t = 0; t < 2000 && !r_done; t++) begin
      @(posedge clk);
      if (s.arvalid && s.arready) ar_done = 1;
      if (s.rvalid && s.rready) begin
        r_done = 1;
        d = s.rdata;
        resp = s.rresp;
        check(resp == last_rresp, $sformatf("read %h: RRESP %0d, the slave's %0d", a, resp, last_rresp));
      end
      @(negedge clk);
      if (ar_done) s.arvalid = 0;
    end
    check(r_done, $sformatf("read %h: no response (timeout)", a));
    s.rready = 0;
  endtask

  initial begin
    logic [31:0] d, e;
    logic [1:0] resp;
    int a, ra, nw, nr, ncon;
    for (int i = 0; i < (1 << ADDR_W); i++) mem[i] = 8'(i * 7 + 3);
    for (int i = 0; i < NW; i++) model[i] = {mem[4*i+3], mem[4*i+2], mem[4*i+1], mem[4*i]};
    repeat (4) @(posedge clk);
    rst_n = 1;
    nw = 0;
    nr = 0;
    ncon = 0;
    for (int n = 0; n < 600; n++) begin
      a = 4 * ($urandom % NW);
      if ($urandom % 2) begin
        logic [3:0] st;
        bit wr;
        st = 4'($urandom);
        d = $urandom;
        wr = $urandom % 3 == 0;
        ra = 4 * ($urandom % NW);
        write(a, d, st, $urandom % 3, wr, ra, e);
        for (int b = 0; b < 4; b++) if (st[b]) model[a / 4][8*b +: 8] = d[8*b +: 8];
        nw++;
        if (wr) begin                            // the read presented with the write: after it
          check(e === model[ra / 4], $sformatf("read %h with a write to %h: %h, expected %h", ra, a, e, model[ra / 4]));
          ncon++;
        end
      end else begin
        read(a, d, resp);
        check(d === model[a / 4], $sformatf("read %h: %h, expected %h", a, d, model[a / 4]));
        nr++;
      end
    end
    check(ncon > 50, $sformatf("only %0d reads presented with a write", ncon));
    $display("ddr_cpu_bridge_tb: %0d writes, %0d reads (%0d presented with a write), %0d errors", nw, nr, ncon, errors);
    if (errors == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end
  initial begin
    #5ms;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
`default_nettype wire
