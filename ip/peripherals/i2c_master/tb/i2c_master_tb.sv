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

  logic [7:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [7:0] s_tdata, m_tdata;
  logic s_tvalid, s_tready, s_tlast;
  logic m_tvalid, m_tready, m_tlast;
  logic scl_o, scl_t, sda_o, sda_t;

  tri1 sda, scl;
  assign sda = sda_t ? 1'bz : sda_o;       // master open-drain drivers
  assign scl = scl_t ? 1'bz : scl_o;

  i2c_top #(.FIFO_DEPTH(16)) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr(awaddr),
    .s_axil_awvalid(awvalid),
    .s_axil_awready(awready),
    .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb),
    .s_axil_wvalid(wvalid),
    .s_axil_wready(wready),
    .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid),
    .s_axil_bready(bready),
    .s_axil_araddr(araddr),
    .s_axil_arvalid(arvalid),
    .s_axil_arready(arready),
    .s_axil_rdata(rdata),
    .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .s_axis_tdata(s_tdata),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast),
    .scl_i(scl),
    .scl_o,
    .scl_t,
    .sda_i(sda),
    .sda_o,
    .sda_t
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
  always @(posedge aclk) if (m_tvalid && m_tready) begin
    rx_q.push_back(m_tdata);
    last_q.push_back(m_tlast);
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("i2c_master_tb.vcd");
      $dumpvars(0, i2c_master_tb);
    end
    awvalid = 0;
    wvalid = 0;
    bready = 0;
    arvalid = 0;
    rready = 0;
    awaddr = 0;
    araddr = 0;
    wdata = 0;
    wstrb = 0;
    s_tdata = 0;
    s_tvalid = 0;
    s_tlast = 0;
    m_tready = 1;
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
