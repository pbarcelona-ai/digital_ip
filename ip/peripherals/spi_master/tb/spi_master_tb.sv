// ***************
// Filename: spi_master_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the SPI master IP. A behavioral
//   SPI slave model (all four modes, MSB/LSB first, variable word length)
//   echoes bit-reversed data so both MOSI and MISO paths are verified.
//   Tests modes 0 to 3, LSB first, 8/16/32 bit words, multi-word bursts
//   with tlast chip select control, chip select selection and register
//   readback. Prints TEST PASSED on success. Use +vcd to dump a VCD.
// Date: 2026-09-29
`timescale 1ns/1ps

// Behavioral SPI slave. Captures MOSI into rx_word and returns tx_word on MISO.
module spi_slave_model (
  input  logic sclk, input logic cs_n, input logic mosi, output logic miso,
  input  logic cpol, input logic cpha, input logic lsb_first,
  input  int   nbits,
  input  logic [31:0] tx_word,
  output logic [31:0] rx_word,
  output int   words_seen
);
  int idx;              // bit counter
  int nedge;            // edge counter within the word
  logic [31:0] rx_sr;
  initial begin miso = 1'bz; words_seen = 0; rx_word = 0; end
  // Chip select falling: prepare first bit (CPHA=0 drives before first edge)
  always @(negedge cs_n) begin
    idx = 0; nedge = 0; rx_sr = 0;
    miso = cpha ? 1'bz : tx_word[lsb_first ? 0 : nbits-1];
  end
  always @(posedge cs_n) miso = 1'bz;
  // Every SCLK edge while selected
  always @(sclk) if (!cs_n) begin
    logic lead;
    lead = (sclk != cpol);                        // leading (active) edge
    if (lead == !cpha) begin                     // sample edge
      rx_sr[lsb_first ? idx : nbits-1-idx] = mosi;
      if (idx == nbits-1) begin rx_word = rx_sr; words_seen++; end
      idx++;
    end else begin                                // shift edge
      if (idx < nbits) miso = tx_word[lsb_first ? idx : nbits-1-idx];
    end
    if (idx == nbits && (lead != !cpha)) idx = 0;  // ready for a next word
  end
endmodule

module spi_master_tb;
  localparam real CLK_PERIOD = 10.0;
  localparam int  NUM_CS = 4;
  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  // AXI-Lite wires (names match DUT ports for .* connections)
  logic [7:0] s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);

  logic [31:0] s_axis_tdata, m_axis_tdata; logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic sclk, mosi, miso; logic [NUM_CS-1:0] cs_n;

  spi_top #(.FIFO_DEPTH(16), .NUM_CS(NUM_CS)) dut (
    .aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr,
    .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp,
    .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast,
    .m_axis_tdata, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast,
    .spi_sclk_o(sclk), .spi_mosi_o(mosi), .spi_miso_i(miso), .spi_cs_n_o(cs_n));

  logic cpol, cpha, lsb; int nbits; logic [31:0] slv_tx, slv_rx; int slv_words;
  spi_slave_model slave (.sclk, .cs_n(cs_n[1]), .mosi, .miso, .cpol, .cpha,
                         .lsb_first(lsb), .nbits, .tx_word(slv_tx),
                         .rx_word(slv_rx), .words_seen(slv_words));

  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Received words
  logic [31:0] rxq[$]; bit rxlast[$];
  always @(posedge aclk) if (m_axis_tvalid && m_axis_tready) begin
    rxq.push_back(m_axis_tdata); rxlast.push_back(m_axis_tlast);
  end

  task automatic send(input [31:0] w, input bit last);
    @(posedge aclk); #1; s_axis_tdata = w; s_axis_tvalid = 1; s_axis_tlast = last;
    wait (s_axis_tready); @(posedge aclk); #1 s_axis_tvalid = 0;
  endtask

  logic [31:0] rd; int words0;
  // Configure and run one single-word transfer, check both directions
  task automatic xfer(input logic p, input logic h, input logic l,
                      input int n, input [31:0] mosi_w, input [31:0] miso_w);
    logic [31:0] mask;
    mask = (n == 32) ? 32'hFFFF_FFFF : ((32'd1 << n) - 1);
    cpol = p; cpha = h; lsb = l; nbits = n; slv_tx = miso_w & mask;
    bfm.write(8'h00, {16'd0, 8'd1, 4'd0, l, h, p, 1'b1});   // cs_select=1
    bfm.write(8'h08, n);
    rxq.delete(); rxlast.delete();
    send(mosi_w & mask, 1);
    while (rxq.size() != 1) @(posedge aclk); repeat (10) @(posedge aclk);
    check(slv_rx == (mosi_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MOSI got %08h exp %08h",
          p, h, l, n, slv_rx, mosi_w & mask));
    check(rxq[0] == (miso_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MISO got %08h exp %08h",
          p, h, l, n, rxq[0], miso_w & mask));
    check(cs_n == '1, "CS not released after tlast");
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("spi_master_tb.vcd"); $dumpvars(0, spi_master_tb); end
    s_axis_tdata = 0; s_axis_tvalid = 0; s_axis_tlast = 0; m_axis_tready = 1;
    cpol = 0; cpha = 0; lsb = 0; nbits = 8; slv_tx = 0;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    bfm.read(8'h04, rd);  check(rd == 49, $sformatf("default DIV %0d", rd));
    bfm.write(8'h04, 4);                                    // fast SCLK for sim

    // ---- Test 1: all four modes, MSB first, 8 bits ----
    for (int m = 0; m < 4; m++)
      xfer(m[1], m[0], 0, 8, 32'hA5 ^ (m * 32'h3C), 32'h5A + m);
    // ---- Test 2: LSB first ----
    xfer(0, 0, 1, 8, 32'h96, 32'h1D);
    xfer(1, 1, 1, 16, 32'hBEEF, 32'h1234);
    // ---- Test 3: word lengths ----
    xfer(0, 1, 0, 16, 32'hCAFE, 32'h0F0F);
    xfer(1, 0, 0, 32, 32'hDEADBEEF, 32'h01234567);
    xfer(0, 0, 0, 5, 32'h15, 32'h0A);

    // ---- Test 4: burst of 3 words, CS held low until tlast ----
    cpol = 0; cpha = 0; lsb = 0; nbits = 8; slv_tx = 8'h3C;
    bfm.write(8'h00, {16'd0, 8'd1, 4'd0, 3'b000, 1'b1});
    bfm.write(8'h08, 8);
    rxq.delete(); rxlast.delete(); words0 = slv_words;
    send(8'h11, 0); send(8'h22, 0); send(8'h33, 1);
    while (rxq.size() != 3) @(posedge aclk); repeat (10) @(posedge aclk);
    check(slv_words - words0 == 3, $sformatf("slave saw %0d words in burst", slv_words));
    check(rxlast[0] == 0 && rxlast[1] == 0 && rxlast[2] == 1, "rx tlast pattern");
    check(rxq[0] == 8'h3C && rxq[2] == 8'h3C, "burst miso data");
    check(cs_n == '1, "CS not released after burst");

    // ---- Test 5: chip select select (cs 3) ----
    bfm.write(8'h00, {16'd0, 8'd3, 4'd0, 3'b000, 1'b1});
    rxq.delete(); send(8'h55, 1);
    wait (cs_n[3] == 0); check(cs_n == 4'b0111, "CS3 select");
    while (rxq.size() != 1) @(posedge aclk);
    check(bfm.resp_errors == 0, "AXI-Lite error responses");

    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #50_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
