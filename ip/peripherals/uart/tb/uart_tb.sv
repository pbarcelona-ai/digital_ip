// ***************
// Filename: uart_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the UART IP. Tests transmit
//   (AXI-Stream in, serial monitor checks framing and parity), receive
//   (serial driver, AXI-Stream out), internal loopback, parity/framing
//   error flags with write-1-to-clear, and register readback. Runs at 1
//   Mbaud from a 100 MHz clock. Prints TEST PASSED on success. Use +vcd
//   for sim/uart_tb.vcd.
// Date: 2026-09-29
`timescale 1ns/1ps
module uart_tb;
  localparam real CLK_PERIOD = 10.0;          // 100 MHz
  localparam real BIT_NS     = 1000.0;        // 1 Mbaud
  localparam logic [31:0] FCW_1M = 32'd687194767;  // 1e6*16*2^32/1e8

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr; logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [7:0] s_tdata, m_tdata; logic s_tvalid, s_tready, s_tlast;
  logic m_tvalid, m_tready, m_tlast;
  logic txd, rxd = 1'b1;

  uart_top #(.FIFO_DEPTH(16)) dut (
    .aclk, .aresetn,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
    .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .uart_txd_o(txd), .uart_rxd_i(rxd));

  int errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR @%0t: %s", $time, msg); end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge aclk); #1;
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1; bready = 1;
    fork
      begin wait (awready); @(posedge aclk); #1 awvalid = 0; end
      begin wait (wready);  @(posedge aclk); #1 wvalid = 0;  end
    join
    wait (bvalid); @(posedge aclk); #1;
  endtask
  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1; rready = 1;
    wait (arready); @(posedge aclk); #1 arvalid = 0;
    wait (rvalid); d = rdata; @(posedge aclk); #1;
  endtask

  // ---------- AXI-Stream helpers ----------
  task automatic stream_send(input [7:0] b);
    @(posedge aclk); #1; s_tdata = b; s_tvalid = 1; s_tlast = 0;
    wait (s_tready); @(posedge aclk); #1 s_tvalid = 0;
  endtask

  // ---------- Serial driver (acts as external transmitter) ----------
  task automatic serial_send(input [7:0] b, input int nbits, input bit pen,
                             input bit podd, input bit stop2,
                             input bit bad_par, input bit bad_stop);
    bit p; p = 0;
    rxd = 0; #(BIT_NS);                                  // start
    for (int i = 0; i < nbits; i++) begin
      rxd = b[i]; p ^= b[i]; #(BIT_NS);
    end
    if (pen) begin rxd = p ^ podd ^ bad_par; #(BIT_NS); end
    rxd = bad_stop ? 1'b0 : 1'b1; #(BIT_NS);             // stop
    rxd = 1'b1;
    if (bad_stop) #(BIT_NS);                             // let line recover
    if (stop2) #(BIT_NS);
  endtask

  // ---------- Serial monitor (checks the DUT transmitter) ----------
  int   mon_nbits = 8; bit mon_pen = 0, mon_podd = 0, mon_stop2 = 0;
  byte  exp_q[$];
  int   mon_count = 0;
  logic [7:0] mon_byte; bit mon_par; bit mon_en = 0;
  always @(negedge txd) if (mon_en) begin
    #(BIT_NS * 1.5);
    mon_byte = 0; mon_par = 0;
    for (int i = 0; i < mon_nbits; i++) begin
      mon_byte[i] = txd; mon_par ^= txd; #(BIT_NS);
    end
    if (mon_pen) begin
      check(txd == (mon_par ^ mon_podd), "tx parity bit wrong"); #(BIT_NS);
    end
    check(txd == 1'b1, "tx stop bit wrong");
    if (mon_stop2) begin #(BIT_NS); check(txd == 1'b1, "tx second stop bit wrong"); end
    if (exp_q.size() == 0) check(0, "unexpected tx byte");
    else begin
      logic [7:0] e; e = exp_q.pop_front();
      check(mon_byte == (e & ((9'd1 << mon_nbits) - 1)),
            $sformatf("tx byte got %02h exp %02h", mon_byte, e));
    end
    mon_count++;
  end

  // ---------- Receive stream checker ----------
  byte rx_q[$];
  int  rx_count = 0;
  logic m_user_dummy;
  always @(posedge aclk) if (m_tvalid && m_tready) begin
    check(rx_q.size() != 0, "unexpected rx byte");
    if (rx_q.size() != 0) begin
      logic [7:0] e; e = rx_q.pop_front();
      check(m_tdata == e, $sformatf("rx byte got %02h exp %02h", m_tdata, e));
    end
    rx_count++;
  end

  logic [31:0] rd;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("uart_tb.vcd"); $dumpvars(0, uart_tb);
    end
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    s_tdata = 0; s_tvalid = 0; s_tlast = 0; m_tready = 1;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);

    // default FCW for 115200 baud
    axil_read(8'h04, rd); check(rd == 32'd79164837, $sformatf("default FCW %0d", rd));
    axil_write(8'h04, FCW_1M);

    // ---- Test 1: transmit 8N1 ----
    mon_en = 1; mon_nbits = 8;
    for (int i = 0; i < 6; i++) begin
      exp_q.push_back(8'hA0 + i * 17); stream_send(8'hA0 + i * 17);
    end
    wait (mon_count == 6);
    #(BIT_NS * 3);
    check(exp_q.size() == 0, "not all tx bytes seen");

    // ---- Test 2: transmit 7E2 (7 bits, even parity, 2 stop) ----
    axil_write(8'h00, 32'b0001_0111 | (32'd1 << 6));   // tx,rx,par_en,stop2, 7 bits
    mon_nbits = 7; mon_pen = 1; mon_podd = 0; mon_stop2 = 1; mon_count = 0;
    for (int i = 0; i < 4; i++) begin
      exp_q.push_back(8'h35 + i * 9); stream_send(8'h35 + i * 9);
    end
    wait (mon_count == 4);
    #(BIT_NS * 3);
    // odd parity, 8 bits, 1 stop
    axil_write(8'h00, 32'b0000_1111);                    // tx,rx,par_en,par_odd
    mon_nbits = 8; mon_pen = 1; mon_podd = 1; mon_stop2 = 0; mon_count = 0;
    exp_q.push_back(8'hC3); stream_send(8'hC3);
    exp_q.push_back(8'h01); stream_send(8'h01);
    wait (mon_count == 2);
    #(BIT_NS * 3);
    mon_en = 0;

    // ---- Test 3: receive 8N1 from the external driver ----
    axil_write(8'h00, 32'h3);
    for (int i = 0; i < 8; i++) begin
      rx_q.push_back(8'h10 * i + 3);
      serial_send(8'h10 * i + 3, 8, 0, 0, 0, 0, 0);
    end
    #(BIT_NS * 3);
    check(rx_count == 8, $sformatf("rx count %0d", rx_count));
    check(rx_q.size() == 0, "rx bytes missing");

    // ---- Test 4: parity error and framing error flags ----
    axil_write(8'h00, 32'b0000_0111);                    // par_en even
    rx_q.push_back(8'h5A); serial_send(8'h5A, 8, 1, 0, 0, 1, 0);   // bad parity
    #(BIT_NS * 2);
    axil_read(8'h08, rd); check(rd[9] == 1'b1, "parity_err flag missing");
    axil_write(8'h08, 32'h0000_0200);                    // W1C parity_err
    axil_read(8'h08, rd); check(rd[9] == 1'b0, "parity_err W1C failed");
    axil_write(8'h00, 32'h3);
    rx_q.push_back(8'h77); serial_send(8'h77, 8, 0, 0, 0, 0, 1);   // bad stop
    #(BIT_NS * 3);
    axil_read(8'h08, rd); check(rd[8] == 1'b1, "frame_err flag missing");
    axil_read(8'h0C, rd); check(rd == 2, $sformatf("error count %0d", rd));
    axil_write(8'h08, 32'h0000_0700);
    axil_read(8'h08, rd); check(rd[10:8] == 0, "flags not cleared");
    // drain the two error words that were pushed into the FIFO
    repeat (10) @(posedge aclk);

    // ---- Test 5: internal loopback ----
    axil_write(8'h00, 32'h23);                           // tx,rx,loopback
    for (int i = 0; i < 10; i++) begin
      rx_q.push_back(8'hF0 ^ (i * 29)); stream_send(8'hF0 ^ (i * 29));
    end
    #(BIT_NS * 10 * 10 + BIT_NS * 3);
    check(rx_q.size() == 0, $sformatf("loopback: %0d bytes missing", rx_q.size()));

    // ---- Test 6: 5 data bits ----
    axil_write(8'h00, 32'h3 | (32'd3 << 6));             // 5 bits
    rx_q.push_back(8'h15); serial_send(8'h15, 5, 0, 0, 0, 0, 0);
    #(BIT_NS * 2);
    check(rx_q.size() == 0, "5-bit word not received");

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #3_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
