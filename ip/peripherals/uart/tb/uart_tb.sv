// ***************
// Filename: uart_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the UART IP. Tests transmit
//   (AXI-Stream in, serial monitor checks framing and parity), receive
//   (serial driver, AXI-Stream out), internal loopback, parity/framing
//   error flags with write-1-to-clear, and register readback. Runs at 1
//   Mbaud from a 100 MHz clock. Prints TEST PASSED on success. Use +vcd
//   for sim/uart_tb.vcd.
//   The test tasks are in tests/uart_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module uart_tb;
  localparam real CLK_PERIOD = 10.0;          // 100 MHz
  localparam real BIT_NS     = 1000.0;        // 1 Mbaud
  localparam logic [31:0] FCW_1M = 32'd687194767;  // 1e6*16*2^32/1e8

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(8)) m ();
  axis_if #(.DATA_W(8)) s ();
  uart_if dut_uart ();

  uart_top #(.FIFO_DEPTH(16)) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(s),
    .m_axis(m),
    .uart(dut_uart)
  );

  // UART line partner: drives the DUT receiver, checks the DUT transmitter
  uart_bfm #(.BIT_NS(BIT_NS)) uart (
    .txd(dut_uart.rxd),
    .rxd(dut_uart.txd)
  );

  int errors = 0;

  // test tasks: tests/uart_tests.sv

  int unsigned reg_base = 'h10;                    // the register map after the ID block (0x00-0x0C)
  `include "uart_tests.sv"

  // ---------- Serial monitor (checks the DUT transmitter, via uart_bfm) ----------
  byte  exp_q[$];
  int   mon_count = 0;
  initial uart.rx_en = 0;
  always @(uart.rx_done) begin
    check(!uart.rx_perr, "tx parity bit wrong");
    check(!uart.rx_ferr, "tx stop bit wrong");
    if (exp_q.size() == 0) check(0, "unexpected tx byte");
    else begin
      logic [7:0] e;
      e = exp_q.pop_front();
      check(uart.rx_data == (e & ((9'd1 << uart.nbits) - 1)),
            $sformatf("tx byte got %02h exp %02h", uart.rx_data, e));
    end
    mon_count++;
  end

  // ---------- Receive stream checker ----------
  byte rx_q[$];
  int  rx_count = 0;
  logic m_user_dummy;
  always @(posedge aclk) if (m.tvalid && m.tready) begin
    check(rx_q.size() != 0, "unexpected rx byte");
    if (rx_q.size() != 0) begin
      logic [7:0] e;
      e = rx_q.pop_front();
      check(m.tdata == e, $sformatf("rx byte got %02h exp %02h", m.tdata, e));
    end
    rx_count++;
  end

  logic [31:0] rd;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("uart_tb.vcd");
      $dumpvars(0, uart_tb);
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

    // default FCW for 115200 baud
    test_id_block();
    axil_read(8'h04, rd);
    check(rd == 32'd79164837, $sformatf("default FCW %0d", rd));
    axil_write(8'h04, FCW_1M);

    // ---- Test 1: transmit 8N1 ----
    uart.rx_en = 1;
    uart.nbits = 8;
    for (int i = 0; i < 6; i++) begin
      exp_q.push_back(8'(8'hA0 + i * 17));
      stream_send(8'hA0 + i * 17);
    end
    wait (mon_count == 6);
    #(BIT_NS * 3);
    check(exp_q.size() == 0, "not all tx bytes seen");

    // ---- Test 2: transmit 7E2 (7 bits, even parity, 2 stop) ----
    axil_write(8'h00, 32'b0001_0111 | (32'd1 << 6));   // tx,rx,par_en,stop2, 7 bits
    uart.nbits = 7;
    uart.parity_en = 1;
    uart.parity_odd = 0;
    uart.stop2 = 1;
    mon_count = 0;
    for (int i = 0; i < 4; i++) begin
      exp_q.push_back(8'(8'h35 + i * 9));
      stream_send(8'h35 + i * 9);
    end
    wait (mon_count == 4);
    #(BIT_NS * 3);
    // odd parity, 8 bits, 1 stop
    axil_write(8'h00, 32'b0000_1111);                    // tx,rx,par_en,par_odd
    uart.nbits = 8;
    uart.parity_en = 1;
    uart.parity_odd = 1;
    uart.stop2 = 0;
    mon_count = 0;
    exp_q.push_back(8'hC3);
    stream_send(8'hC3);
    exp_q.push_back(8'h01);
    stream_send(8'h01);
    wait (mon_count == 2);
    #(BIT_NS * 3);
    uart.rx_en = 0;

    // ---- Test 3: receive 8N1 from the external driver ----
    axil_write(8'h00, 32'h3);
    for (int i = 0; i < 8; i++) begin
      rx_q.push_back(8'(8'h10 * i + 3));
      serial_send(8'h10 * i + 3, 8, 0, 0, 0, 0, 0);
    end
    #(BIT_NS * 3);
    check(rx_count == 8, $sformatf("rx count %0d", rx_count));
    check(rx_q.size() == 0, "rx bytes missing");

    // ---- Test 4: parity error and framing error flags ----
    axil_write(8'h00, 32'b0000_0111);                    // par_en even
    rx_q.push_back(8'h5A); // bad parity
    serial_send(8'h5A, 8, 1, 0, 0, 1, 0);
    #(BIT_NS * 2);
    axil_read(8'h08, rd);
    check(rd[9] == 1'b1, "parity_err flag missing");
    axil_write(8'h08, 32'h0000_0200);                    // W1C parity_err
    axil_read(8'h08, rd);
    check(rd[9] == 1'b0, "parity_err W1C failed");
    axil_write(8'h00, 32'h3);
    rx_q.push_back(8'h77); // bad stop
    serial_send(8'h77, 8, 0, 0, 0, 0, 1);
    #(BIT_NS * 3);
    axil_read(8'h08, rd);
    check(rd[8] == 1'b1, "frame_err flag missing");
    axil_read(8'h0C, rd);
    check(rd == 2, $sformatf("error count %0d", rd));
    axil_write(8'h08, 32'h0000_0700);
    axil_read(8'h08, rd);
    check(rd[10:8] == 0, "flags not cleared");
    // drain the two error words that were pushed into the FIFO
    repeat (10) @(posedge aclk);

    // ---- Test 5: internal loopback ----
    axil_write(8'h00, 32'h23);                           // tx,rx,loopback
    for (int i = 0; i < 10; i++) begin
      rx_q.push_back(8'(8'hF0 ^ (i * 29)));
      stream_send(8'hF0 ^ (i * 29));
    end
    #(BIT_NS * 10 * 10 + BIT_NS * 3);
    check(rx_q.size() == 0, $sformatf("loopback: %0d bytes missing", rx_q.size()));

    // ---- Test 6: 5 data bits ----
    axil_write(8'h00, 32'h3 | (32'd3 << 6));             // 5 bits
    rx_q.push_back(8'h15);
    serial_send(8'h15, 5, 0, 0, 0, 0, 0);
    #(BIT_NS * 2);
    check(rx_q.size() == 0, "5-bit word not received");

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #3_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
