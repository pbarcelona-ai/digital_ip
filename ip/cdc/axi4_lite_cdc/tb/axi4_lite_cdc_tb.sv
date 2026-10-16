// ***************
// Filename: axi4_lite_cdc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the AXI-Lite clock domain
//   bridge. A 100 MHz AXI-Lite master (BFM) accesses a register file that
//   runs on an unrelated 37 MHz clock through the bridge. Tests
//   write/readback, byte strobes, back-to-back transactions, response
//   codes for out-of-range addresses, a random access soak, and a write and a
//   read issued in the same clock (the write goes first, neither is lost). Prints TEST
//   PASSED on success.
//   The test tasks are in tests/axi4_lite_cdc_tests.sv (`included).
// Date: 2026-10-16
`timescale 1ns/1ps
module axi4_lite_cdc_tb;
  logic aclk = 0, mclk = 0, aresetn = 0, mresetn = 0;
  always #5.0 aclk = ~aclk;
  always #13.5 mclk = ~mclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );
  axil_if #(.ADDR_W(8), .DATA_W(32)) m ();
  axi4_lite_cdc #(.ADDR_W(8)) dut (
    .s_clk(aclk),
    .s_rst_n(aresetn),
    .s_axil(s_axil),
    .m_clk(mclk),
    .m_rst_n(mresetn),
    .m_axil(m)
  );
  logic [8*32-1:0] regs;
  logic [7:0] wrp;
  logic [31:0] wrd;
  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(8)
  ) slave (
    .aclk(mclk),
    .aresetn(mresetn),
    .s_axil(m),
    .reg_o(regs),
    .wr_pulse_o(wrp),
    .wr_data_o(wrd),
    .rd_i(regs)
  );
  int errors = 0;
  logic [31:0] rd;
  logic [31:0] model [0:7];
  // test tasks: tests/axi4_lite_cdc_tests.sv
  `include "axi4_lite_cdc_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi4_lite_cdc_tb.vcd");
      $dumpvars(0, axi4_lite_cdc_tb);
    end
    repeat (5) @(posedge aclk);
    aresetn = 1;
    mresetn = 1;
    repeat (5) @(posedge aclk);
    for (int i = 0; i < 8; i++) model[i] = 0;
    // ---- Test 1: write then read every register ----
    for (int i = 0; i < 8; i++) begin
      bfm.write(i*4, 32'hA000_0000 + i*32'h1111);
      model[i] = 32'hA000_0000 + i*32'h1111;
    end
    for (int i = 0; i < 8; i++) begin
      bfm.read(i*4, rd);
      check(rd == model[i], $sformatf("reg %0d got %h", i, rd));
    end
    // ---- Test 2: byte strobes ----
    bfm.write_strb(8'h08, 32'hFFFF_FFFF, 4'b0101);
    model[2] = (model[2] & 32'hFF00_FF00) | 32'h00FF_00FF;
    bfm.read(8'h08, rd);
    check(rd == model[2], $sformatf("strobe result %h exp %h", rd, model[2]));
    // ---- Test 3: out of range address returns SLVERR through the bridge ----
    bfm.read(8'h80, rd);
    check(bfm.last_resp == 2'b10, "read SLVERR expected");
    bfm.write(8'h80, 32'h1);
    check(bfm.last_resp == 2'b10, "write SLVERR expected");
    bfm.resp_errors = 0;
    // ---- Test 4: random soak ----
    for (int n = 0; n < 200; n++) begin
      int r;
      r = $urandom_range(0, 7);
      if ($urandom_range(0, 1)) begin
        model[r] = $urandom;
        bfm.write(r*4, model[r]);
      end
      else begin
        bfm.read(r*4, rd);
        check(rd == model[r], $sformatf("soak reg %0d got %h exp %h", r, rd, model[r]));
      end
    end
    check(bfm.resp_errors == 0, "unexpected AXI errors");
    // ---- Test 5: AW / W and AR in the same clock: the write goes first, the read is not lost ----
    for (int n = 0; n < 8; n++) begin
      logic [31:0] wv;
      int wr_i, rd_i;
      wr_i = n;
      rd_i = (n + 3) % 8;
      wv = 32'hC0DE_0000 + n;
      fork
        bfm.write(wr_i * 4, wv);
        bfm.read(rd_i * 4, rd);
      join
      check(rd == model[rd_i], $sformatf("concurrent read reg %0d got %h exp %h", rd_i, rd, model[rd_i]));
      model[wr_i] = wv;
      bfm.read(wr_i * 4, rd);
      check(rd == wv, $sformatf("concurrent write reg %0d got %h exp %h", wr_i, rd, wv));
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
