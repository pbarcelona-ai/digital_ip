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
  logic [7:0] s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);

  logic [31:0] s_axis_tdata, m_axis_tdata;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic sclk, mosi, miso;
  logic [NUM_CS-1:0] cs_n;

  spi_top #(
    .FIFO_DEPTH(16),
    .NUM_CS(NUM_CS)
  ) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .s_axis_tdata,
    .s_axis_tvalid,
    .s_axis_tready,
    .s_axis_tlast,
    .m_axis_tdata,
    .m_axis_tvalid,
    .m_axis_tready,
    .m_axis_tlast,
    .spi_sclk_o(sclk),
    .spi_mosi_o(mosi),
    .spi_miso_i(miso),
    .spi_cs_n_o(cs_n)
  );

  logic cpol, cpha, lsb;
  int nbits;
  logic [31:0] slv_tx, slv_rx;
  int slv_words;
  spi_bfm slave (
    .sclk,
    .cs_n(cs_n[1]),
    .mosi,
    .miso,
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
  always @(posedge aclk) if (m_axis_tvalid && m_axis_tready) begin
    rxq.push_back(m_axis_tdata);
    rxlast.push_back(m_axis_tlast);
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
    s_axis_tdata = 0;
    s_axis_tvalid = 0;
    s_axis_tlast = 0;
    m_axis_tready = 1;
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
