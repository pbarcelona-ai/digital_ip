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
  `include "i2c_master_tests.sv"

  // Received byte capture
  byte rx_q[$];
  bit last_q[$];
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

    axil_read(8'h0C, rd);
    check(rd == 32'd249, $sformatf("default DIV %0d (100 kHz at 100 MHz)", rd));
    axil_write(8'h0C, 32'd12);                          // fast bus for sim

    // ---- Test 1: write pointer 0x10 then two data bytes ----
    stream_send(8'h10);
    stream_send(8'hAA);
    stream_send(8'h55);
    i2c_xfer(7'h50, 0, 3, 0);
    check(rd[2] == 0, "unexpected NACK on write");
    check(slave.mem[16] == 8'hAA && slave.mem[17] == 8'h55,
          $sformatf("slave memory %02h %02h", slave.mem[16], slave.mem[17]));
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after STOP");

    // ---- Test 2: pointer write without STOP, repeated START read ----
    stream_send(8'h10);
    i2c_xfer(7'h50, 0, 1, 1);
    check(scl === 1'b0, "SCL should stay low after no-stop transaction");
    i2c_xfer(7'h50, 1, 2, 0);
    repeat (20) @(posedge aclk);
    check(rx_q.size() == 2, $sformatf("read %0d bytes", rx_q.size()));
    if (rx_q.size() == 2) begin
      check(rx_q[0] == 8'hAA && rx_q[1] == 8'h55, "read data mismatch");
      check(last_q[0] == 0 && last_q[1] == 1, "tlast on final read byte only");
    end
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after read STOP");
    rx_q.delete();
    last_q.delete();

    // ---- Test 3: absent slave NACKs the address ----
    i2c_xfer(7'h51, 0, 1, 0);
    check(rd[2] == 1, "NACK flag not set");
    stream_send(8'h00);                       // consume unused byte later
    axil_write(8'h10, 32'hE);
    axil_read(8'h10, rd);
    check(rd[3:1] == 0, "W1C did not clear flags");
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after NACK");

    // ---- Test 4: address-only probe (len = 0) ----
    i2c_xfer(7'h50, 0, 0, 0);
    check(rd[2] == 0, "probe of present slave NACKed");

    // ---- Test 5: read with clock stretching ----
    slave.stretch_en = 1;
    i2c_xfer(7'h50, 1, 1, 0);
    repeat (20) @(posedge aclk);
    check(rx_q.size() == 1, "stretched read lost data");
    check(rd[2] == 0, "NACK during stretched transfer");
    slave.stretch_en = 0;

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
