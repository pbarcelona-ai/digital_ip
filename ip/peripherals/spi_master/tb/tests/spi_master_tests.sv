// ***************
// Filename: spi_master_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the spi_master_tb testbench
//   (spi_master_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     send   Sends one word on the AXI4-Stream slave (last: ends the burst)
//     xfer   Configure and run one single-word transfer, check both directions
//            (register offsets from bfm.base = 0x10, the map after the ID block)
//     test_id_block     ID "SPIM", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                       0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_default_div  DIV resets to CLK_HZ / (2 * SCLK_HZ) - 1, then 4 (fast
//                       SCLK for the simulation)
//     test_modes        All four SPI modes, MSB first, 8 bits
//     test_lsb_first    LSB first, 8 and 16 bits
//     test_word_len     16, 32 and 5-bit words
//     test_burst        Burst of 3 words, CS held low until tlast
//     test_cs_select    Chip select 3 selected by CTRL[15:8]
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic send(input [31:0] w, input bit last);
    @(posedge aclk);
    #1;
    s_axis.tdata = w;
    s_axis.tvalid = 1;
    s_axis.tlast = last;
    wait (s_axis.tready);
    @(posedge aclk);
    #1 s_axis.tvalid = 0;
  endtask

  // Configure and run one single-word transfer, check both directions
  task automatic xfer(input logic p, input logic h, input logic l,
                      input int n, input [31:0] mosi_w, input [31:0] miso_w);
    logic [31:0] mask;
    mask = (n == 32) ? 32'hFFFF_FFFF : ((32'd1 << n) - 1);
    cpol = p;
    cpha = h;
    lsb = l;
    nbits = n;
    slv_tx = miso_w & mask;
    bfm.write(8'h00, {16'd0, 8'd1, 4'd0, l, h, p, 1'b1});   // cs_select=1
    bfm.write(8'h08, n);
    rxq.delete();
    rxlast.delete();
    send(mosi_w & mask, 1);
    while (rxq.size() != 1) @(posedge aclk);
    repeat (10) @(posedge aclk);
    check(slv_rx == (mosi_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MOSI got %08h exp %08h",
          p, h, l, n, slv_rx, mosi_w & mask));
    check(rxq[0] == (miso_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MISO got %08h exp %08h",
          p, h, l, n, rxq[0], miso_w & mask));
    check(spi.cs_n == '1, "CS not released after tlast");
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "SPIM", $sformatf("ID %h (\"%s\"), expected \"SPIM\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_default_div();
    bfm.read(8'h04, rd);
    check(rd == 49, $sformatf("default DIV %0d", rd));
    bfm.write(8'h04, 4);                                    // fast SCLK for sim
  endtask

  task automatic test_modes();
    // ---- Test 1: all four modes, MSB first, 8 bits ----
    for (int m = 0; m < 4; m++)
      xfer(m[1], m[0], 0, 8, 32'hA5 ^ (m * 32'h3C), 32'h5A + m);
  endtask

  task automatic test_lsb_first();
    // ---- Test 2: LSB first ----
    xfer(0, 0, 1, 8, 32'h96, 32'h1D);
    xfer(1, 1, 1, 16, 32'hBEEF, 32'h1234);
  endtask

  task automatic test_word_len();
    // ---- Test 3: word lengths ----
    xfer(0, 1, 0, 16, 32'hCAFE, 32'h0F0F);
    xfer(1, 0, 0, 32, 32'hDEADBEEF, 32'h01234567);
    xfer(0, 0, 0, 5, 32'h15, 32'h0A);
  endtask

  task automatic test_burst();
    // ---- Test 4: burst of 3 words, CS held low until tlast ----
    cpol = 0;
    cpha = 0;
    lsb = 0;
    nbits = 8;
    slv_tx = 8'h3C;
    bfm.write(8'h00, {16'd0, 8'd1, 4'd0, 3'b000, 1'b1});
    bfm.write(8'h08, 8);
    rxq.delete();
    rxlast.delete();
    words0 = slv_words;
    send(8'h11, 0);
    send(8'h22, 0);
    send(8'h33, 1);
    while (rxq.size() != 3) @(posedge aclk);
    repeat (10) @(posedge aclk);
    check(slv_words - words0 == 3, $sformatf("slave saw %0d words in burst", slv_words));
    check(rxlast[0] == 0 && rxlast[1] == 0 && rxlast[2] == 1, "rx tlast pattern");
    check(rxq[0] == 8'h3C && rxq[2] == 8'h3C, "burst miso data");
    check(spi.cs_n == '1, "CS not released after burst");
  endtask

  task automatic test_cs_select();
    // ---- Test 5: chip select select (cs 3) ----
    bfm.write(8'h00, {16'd0, 8'd3, 4'd0, 3'b000, 1'b1});
    rxq.delete();
    send(8'h55, 1);
    wait (spi.cs_n[3] == 0);
    check(spi.cs_n == 4'b0111, "CS3 select");
    while (rxq.size() != 1) @(posedge aclk);
  endtask
