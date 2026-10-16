// ***************
// Filename: spi_master_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the SPI master IP. A behavioral
//   SPI slave model (all four modes, MSB/LSB first, variable word length)
//   echoes bit-reversed data so both MOSI and MISO paths are verified.
//   Tests modes 0 to 3, LSB first, 8/16/32 bit words, multi-word bursts
//   with tlast chip select control, chip select selection and register
//   readback. Prints TEST PASSED on success. Use +vcd to dump a VCD.
//   The test tasks are in tests/spi_master_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps

module spi_master_tb;
  localparam real CLK_PERIOD = 10.0;
  localparam int  NUM_CS = 4;
  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  // AXI-Lite wires (names match DUT ports for .* connections)
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );

  axis_if #(.DATA_W(32)) m_axis ();
  axis_if #(.DATA_W(32)) s_axis ();
  spi_if #(.NUM_CS(NUM_CS)) spi ();

  spi_top #(
    .FIFO_DEPTH(16),
    .NUM_CS(NUM_CS)
  ) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(s_axis),
    .m_axis(m_axis),
    .spi(spi)
  );

  logic cpol, cpha, lsb;
  int nbits;
  logic [31:0] slv_tx, slv_rx;
  int slv_words;
  spi_bfm slave (
    .sclk(spi.sclk),
    .cs_n(spi.cs_n[1]),
    .mosi(spi.mosi),
    .miso(spi.miso),
    .cpol,
    .cpha,
    .lsb_first(lsb),
    .nbits,
    .tx_word(slv_tx),
    .rx_word(slv_rx),
    .words_seen(slv_words)
  );

  int errors = 0;

  // Received words
  logic [31:0] rxq[$];
  bit rxlast[$];
  always @(posedge aclk) if (m_axis.tvalid && m_axis.tready) begin
    rxq.push_back(m_axis.tdata);
    rxlast.push_back(m_axis.tlast);
  end

  logic [31:0] rd;
  int words0;
  // test tasks: tests/spi_master_tests.sv
  `include "spi_master_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("spi_master_tb.vcd");
      $dumpvars(0, spi_master_tb);
    end
    s_axis.tdata = 0;
    s_axis.tvalid = 0;
    s_axis.tlast = 0;
    m_axis.tready = 1;
    cpol = 0;
    cpha = 0;
    lsb = 0;
    nbits = 8;
    slv_tx = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_default_div();
    test_modes();
    test_lsb_first();
    test_word_len();
    test_burst();
    test_cs_select();

    check(bfm.resp_errors == 0, "AXI-Lite error responses");

    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
