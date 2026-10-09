// ***************
// Filename: true_dual_port_ram_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for true_dual_port_ram. Port A (100
//   MHz) and port B (57 MHz) write disjoint address ranges concurrently,
//   then each port reads back the whole memory including the other port's
//   data; also checks read-first behaviour and the write-conflict flag.
//   Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module true_dual_port_ram_tb;
  logic ca = 0, cb = 0, ra_n = 0, rb_n = 0;
  always #5 ca = ~ca;
  always #8.75 cb = ~cb;
  logic ena = 0, wea = 0, enb = 0, web = 0;
  logic [5:0] aa = 0, ab = 0;
  logic [15:0] da = 0, db = 0, qa, qb;
  logic conf;
  true_dual_port_ram #(.WIDTH(16), .DEPTH(64), .DUAL_CLOCK(1)) dut (
    .clk_a(ca),
    .rst_a_n(ra_n),
    .en_a_i(ena),
    .we_a_i(wea),
    .addr_a_i(aa),
    .wdata_a_i(da),
    .rdata_a_o(qa),
    .clk_b(cb),
    .rst_b_n(rb_n),
    .en_b_i(enb),
    .we_b_i(web),
    .addr_b_i(ab),
    .wdata_b_i(db),
    .rdata_b_o(qb),
    .wr_conflict_o(conf)
  );
  logic ena1 = 0, wea1 = 0, enb1 = 0;
  logic [5:0] aa1 = 0, ab1 = 0;
  logic [15:0] da1 = 0, qa1, qb1;
  logic conf1;
  true_dual_port_ram #(.WIDTH(16), .DEPTH(64), .DUAL_CLOCK(0)) dut1 (
    .clk_a(ca),
    .rst_a_n(ra_n),
    .en_a_i(ena1),
    .we_a_i(wea1),
    .addr_a_i(aa1),
    .wdata_a_i(da1),
    .rdata_a_o(qa1),
    .clk_b(cb),
    .rst_b_n(ra_n),
    .en_b_i(enb1),
    .we_b_i(1'b0),
    .addr_b_i(ab1),
    .wdata_b_i(16'd0),
    .rdata_b_o(qb1),
    .wr_conflict_o(conf1)
  );
  int errors = 0;
  logic [15:0] m [0:63];
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("true_dual_port_ram_tb.vcd");
      $dumpvars(0, true_dual_port_ram_tb);
    end
    repeat (4) @(posedge ca);
    ra_n = 1;
    rb_n = 1;
    fork
      begin
        for (int i = 0; i < 32; i++) begin
          @(posedge ca);
          #1 ena = 1;
          wea = 1;
          aa = i;
          da = 16'hA000 + i;
          m[i] = da;
        end
        @(posedge ca);
        #1 ena = 0;
        wea = 0;
      end
      begin
        for (int i = 32; i < 64; i++) begin
          @(posedge cb);
          #1 enb = 1;
          web = 1;
          ab = i;
          db = 16'hB000 + i;
          m[i] = db;
        end
        @(posedge cb);
        #1 enb = 0;
        web = 0;
      end
    join
    repeat (3) @(posedge ca);
    fork
      begin
        for (int i = 0; i < 64; i++) begin
          @(posedge ca);
          #1 ena = 1;
          aa = i;
          @(posedge ca);
          #1;
          if (qa !== m[i]) begin
            errors++;
            $display("ERROR A addr %0d got %h exp %h", i, qa, m[i]);
          end
        end
        ena = 0;
      end
      begin
        for (int i = 63; i >= 0; i--) begin
          @(posedge cb);
          #1 enb = 1;
          ab = i;
          @(posedge cb);
          #1;
          if (qb !== m[i]) begin
            errors++;
            $display("ERROR B addr %0d got %h exp %h", i, qb, m[i]);
          end
        end
        enb = 0;
      end
    join
    // read-first: write A to addr 3 while reading addr 3
    @(posedge ca);
    #1 ena = 1;
    wea = 1;
    aa = 3;
    da = 16'hDEAD;
    @(posedge ca);
    #1 wea = 0;
    if (qa !== m[3]) begin
      errors++;
      $display("ERROR read-first got %h", qa);
    end
    @(posedge ca);
    #1 if (qa !== 16'hDEAD) begin
      errors++;
      $display("ERROR post-write read %h", qa);
    end
    // single-clock configuration: write through A, read through B on the same clock
    begin
      logic [15:0] q1a, q1b;
      @(posedge ca);
      #1 ena1 = 1;
      wea1 = 1;
      aa1 = 6'd7;
      da1 = 16'h1357;
      @(posedge ca);
      #1 wea1 = 0;
      enb1 = 1;
      ab1 = 6'd7;
      @(posedge ca);
      #1;
      if (qb1 !== 16'h1357) begin
        errors++;
        $display("ERROR single-clock B read %h", qb1);
      end
    end
    // conflict flag (combinational detect)
    ena = 1;
    enb = 1;
    wea = 1;
    web = 1;
    aa = 9;
    ab = 9;
    #1;
    if (!conf) begin
      errors++;
      $display("ERROR conflict flag");
    end
    wea = 0;
    web = 0;
    ab = 10;
    #1;
    if (conf) begin
      errors++;
      $display("ERROR conflict flag stuck");
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #200000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
