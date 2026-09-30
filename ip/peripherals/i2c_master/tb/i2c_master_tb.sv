// ***************
// Filename: i2c_master_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the I2C master IP with a
//   behavioral I2C slave memory model (address 0x50, pointer byte then
//   sequential access, optional clock stretching). Tests multi-byte write,
//   repeated-START read with tlast, NACK on an absent address, address-
//   only probe, clock stretching and status flag write-1-to-clear. Prints
//   TEST PASSED on success. Use +vcd for sim/i2c_master_tb.vcd.
// Date: 2026-09-29
`timescale 1ns/1ps

// ---------------------------------------------------------------
// Behavioral I2C slave: 256 byte memory, first written byte is the
// memory pointer, reads are sequential from the pointer.
// ---------------------------------------------------------------
module i2c_slave_model #(parameter logic [6:0] ADDR = 7'h50) (
  inout tri1 sda,
  inout tri1 scl
);
  logic sda_low = 0, scl_low = 0;
  assign sda = sda_low ? 1'b0 : 1'bz;
  assign scl = scl_low ? 1'b0 : 1'bz;

  logic [7:0] mem [0:255];
  logic [7:0] ptr = 0, shreg = 0;
  int  state = 0, bitcnt = 0;
  bit  rw = 0, first = 0, m_nack = 0;
  bit  stretch_en = 0;              // hold SCL low during ack when set
  int  stretch_ns = 2000;

  localparam int IDLE = 0, ADR = 1, ADR_ACK = 2, WDATA = 3, W_ACK = 4,
                 RDATA = 5, R_ACK = 6;

  initial for (int i = 0; i < 256; i++) mem[i] = 8'h00;

  // START: SDA falls while SCL high; STOP: SDA rises while SCL high
  always @(negedge sda) if (scl === 1'b1) begin
    state = ADR; bitcnt = 0; shreg = 0; sda_low = 0;
  end
  always @(posedge sda) if (scl === 1'b1) begin
    state = IDLE; sda_low = 0;
  end

  // Sample on rising SCL
  always @(posedge scl) begin
    case (state)
      ADR, WDATA: begin shreg = {shreg[6:0], sda}; bitcnt = bitcnt + 1; end
      R_ACK: m_nack = sda;
      default: ;
    endcase
  end

  // Drive on falling SCL
  always @(negedge scl) begin
    case (state)
      ADR: if (bitcnt == 8) begin
        if (shreg[7:1] == ADDR) begin
          rw = shreg[0]; sda_low = 1; state = ADR_ACK;
          if (stretch_en) begin scl_low = 1; #(stretch_ns); scl_low = 0; end
        end else state = IDLE;
      end
      ADR_ACK: begin
        sda_low = 0; bitcnt = 0;
        if (rw) begin
          shreg = mem[ptr]; ptr = ptr + 1; state = RDATA;
          sda_low = ~shreg[7]; shreg = {shreg[6:0], 1'b0}; bitcnt = 1;
        end else begin state = WDATA; first = 1; end
      end
      WDATA: if (bitcnt == 8) begin
        if (first) begin ptr = shreg; first = 0; end
        else begin mem[ptr] = shreg; ptr = ptr + 1; end
        sda_low = 1; state = W_ACK;
      end
      W_ACK: begin sda_low = 0; bitcnt = 0; state = WDATA; end
      RDATA: begin
        if (bitcnt < 8) begin
          sda_low = ~shreg[7]; shreg = {shreg[6:0], 1'b0}; bitcnt = bitcnt + 1;
        end else begin sda_low = 0; state = R_ACK; end
      end
      R_ACK: begin
        if (m_nack) state = IDLE;
        else begin
          shreg = mem[ptr]; ptr = ptr + 1; state = RDATA;
          sda_low = ~shreg[7]; shreg = {shreg[6:0], 1'b0}; bitcnt = 1;
        end
      end
      default: ;
    endcase
  end
endmodule

module i2c_master_tb;
  localparam real CLK_PERIOD = 10.0;        // 100 MHz
  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr; logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [7:0] s_tdata, m_tdata; logic s_tvalid, s_tready, s_tlast;
  logic m_tvalid, m_tready, m_tlast;
  logic scl_o, scl_t, sda_o, sda_t;

  tri1 sda, scl;
  assign sda = sda_t ? 1'bz : sda_o;       // master open-drain drivers
  assign scl = scl_t ? 1'bz : scl_o;

  i2c_top #(.FIFO_DEPTH(16)) dut (
    .aclk, .aresetn,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
    .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast), .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .scl_i(scl), .scl_o, .scl_t, .sda_i(sda), .sda_o, .sda_t);

  i2c_slave_model slave (.sda, .scl);

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
  task automatic stream_send(input [7:0] b);
    @(posedge aclk); #1; s_tdata = b; s_tvalid = 1; s_tlast = 0;
    wait (s_tready); @(posedge aclk); #1 s_tvalid = 0;
  endtask

  // Run a transaction and wait for the done flag
  logic [31:0] rd;
  task automatic i2c_xfer(input [6:0] a, input bit read, input int len,
                          input bit nostop);
    axil_write(8'h04, {25'd0, a});
    axil_write(8'h08, len);
    axil_write(8'h10, 32'hE);                           // clear flags
    axil_write(8'h00, {28'd0, nostop, read, 1'b1, 1'b1});
    do axil_read(8'h10, rd); while (rd[1] == 1'b0);     // wait for done
  endtask

  // Received byte capture
  byte rx_q[$]; bit last_q[$];
  always @(posedge aclk) if (m_tvalid && m_tready) begin
    rx_q.push_back(m_tdata); last_q.push_back(m_tlast);
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("i2c_master_tb.vcd"); $dumpvars(0, i2c_master_tb);
    end
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    s_tdata = 0; s_tvalid = 0; s_tlast = 0; m_tready = 1;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);

    axil_read(8'h0C, rd);
    check(rd == 32'd249, $sformatf("default DIV %0d (100 kHz at 100 MHz)", rd));
    axil_write(8'h0C, 32'd12);                          // fast bus for sim

    // ---- Test 1: write pointer 0x10 then two data bytes ----
    stream_send(8'h10); stream_send(8'hAA); stream_send(8'h55);
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
    rx_q.delete(); last_q.delete();

    // ---- Test 3: absent slave NACKs the address ----
    i2c_xfer(7'h51, 0, 1, 0);
    check(rd[2] == 1, "NACK flag not set");
    stream_send(8'h00);                       // consume unused byte later
    axil_write(8'h10, 32'hE);
    axil_read(8'h10, rd); check(rd[3:1] == 0, "W1C did not clear flags");
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
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
