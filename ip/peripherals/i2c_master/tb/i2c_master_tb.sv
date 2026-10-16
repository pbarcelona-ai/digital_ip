// ***************
// Filename: i2c_master_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the I2C master IP with a
//   behavioral I2C slave memory model (address 0x50, pointer byte then
//   sequential access, optional clock stretching). Tests multi-byte write,
//   repeated-START read with tlast, NACK on an absent address, address-
//   only probe, clock stretching and status flag write-1-to-clear. Prints
//   TEST PASSED on success. Use +vcd for sim/i2c_master_tb.vcd.
//   The test tasks are in tests/i2c_master_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps

module i2c_master_tb;
  localparam real CLK_PERIOD = 10.0;        // 100 MHz
  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(8)) m ();
  axis_if #(.DATA_W(8)) s ();
  logic scl_o, scl_t, sda_o, sda_t;

  tri1 sda, scl;
  assign sda = sda_t ? 1'bz : sda_o;       // master open-drain drivers
  assign scl = scl_t ? 1'bz : scl_o;

  i2c_if dut_i2c ();
  assign dut_i2c.scl_i = scl;
  assign scl_o = dut_i2c.scl_o;
  assign scl_t = dut_i2c.scl_t;
  assign dut_i2c.sda_i = sda;
  assign sda_o = dut_i2c.sda_o;
  assign sda_t = dut_i2c.sda_t;
  i2c_top #(.FIFO_DEPTH(16)) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(s),
    .m_axis(m),
    .i2c(dut_i2c)
  );

  i2c_bfm slave (
    .sda,
    .scl
  );

  int errors = 0;

  // used by task i2c_xfer (tests/i2c_master_tests.sv)
  logic [31:0] rd;
  // test tasks: tests/i2c_master_tests.sv
  // Received byte capture
  byte rx_q[$];
  bit last_q[$];
  logic [7:0] reg_base = 8'h10;                    // the register map after the ID block
  logic [1:0] last_bresp;
  `include "i2c_master_tests.sv"

  // Received byte capture
  always @(posedge aclk) if (m.tvalid && m.tready) begin
    rx_q.push_back(m.tdata);
    last_q.push_back(m.tlast);
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("i2c_master_tb.vcd");
      $dumpvars(0, i2c_master_tb);
    end
    s_axil.awvalid = 0;
    s_axil.wvalid = 0;
    s_axil.bready = 0;
    s_axil.arvalid = 0;
    s_axil.rready = 0;
    s_axil.awaddr = 0;
    s_axil.araddr = 0;
    s_axil.wdata = 0;
    s_axil.wstrb = 0;
    s.tdata = 0;
    s.tvalid = 0;
    s.tlast = 0;
    m.tready = 1;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);

    test_id_block();
    test_default_div();
    test_write();
    test_repeated_start_read();
    test_nack();
    test_probe();
    test_stretch();

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
