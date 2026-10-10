// ***************
// Filename: counter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for counter. Compares an up, a down
//   and a runtime-direction instance against a reference model across
//   random enable, load and direction changes, including wrap pulses, load
//   clamping and reset. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module counter_tb;
  localparam int W = 6;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic en, ld, dir;
  logic [W-1:0] lv, top;
  logic [W-1:0] cu, cd, cr;
  logic wu, wd, wr;
  counter #(
    .WIDTH(W),
    .DIRECTION(0)
  ) uu (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .load_val_i(lv),
    .top_i(top),
    .dir_i(dir),
    .count_o(cu),
    .wrap_o(wu)
  );
  counter #(
    .WIDTH(W),
    .DIRECTION(1)
  ) ud (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .load_val_i(lv),
    .top_i(top),
    .dir_i(dir),
    .count_o(cd),
    .wrap_o(wd)
  );
  counter #(
    .WIDTH(W),
    .DIRECTION(2)
  ) ur (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .load_val_i(lv),
    .top_i(top),
    .dir_i(dir),
    .count_o(cr),
    .wrap_o(wr)
  );
  int errors = 0;
  // reference models
  logic [W-1:0] mu, md, mr;
  logic mwu, mwd, mwr;
  // one reference step: returns {wrap, next}
  function automatic logic [W:0] step(input logic [W-1:0] c, input bit down);
    if (!down) begin
      if (c >= top) return {1'b1, {W{1'b0}}};
      else return {1'b0, c + 1'b1};
    end
    else begin
      if (c == 0) return {1'b1, top};
      else return {1'b0, c - 1'b1};
    end
  endfunction
  always @(posedge clk) begin
    logic [W-1:0] ld_v;
    ld_v = (lv > top) ? top : lv;
    if (!rst_n) begin
      mu <= 0;
      md <= 0;
      mr <= 0;
      mwu <= 0;
      mwd <= 0;
      mwr <= 0;
    end
    else begin
      mwu <= 0;
      mwd <= 0;
      mwr <= 0;
      if (ld) begin
        mu <= ld_v;
        md <= ld_v;
        mr <= ld_v;
      end
      else if (en) begin
        logic [W:0] s1, s2, s3;
        s1 = step(mu, 0);
        s2 = step(md, 1);
        s3 = step(mr, dir);
        mu <= s1[W-1:0];
        mwu <= s1[W];
        md <= s2[W-1:0];
        mwd <= s2[W];
        mr <= s3[W-1:0];
        mwr <= s3[W];
      end
    end
  end
  always @(negedge clk) if (rst_n) begin
    if (cu !== mu || cd !== md || cr !== mr || wu !== mwu || wd !== mwd || wr !== mwr) begin
      errors++;
      $display("ERROR @%0t up %0d/%0d dn %0d/%0d rt %0d/%0d wrap %b%b%b/%b%b%b", $time, cu, mu, cd, md, cr, mr, wu, wd, wr, mwu, mwd, mwr);
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("counter_tb.vcd");
      $dumpvars(0, counter_tb);
    end
    en = 0;
    ld = 0;
    dir = 0;
    lv = 0;
    top = 10;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3000) begin
      @(posedge clk);
      #1;
      en = ($urandom_range(0, 9) < 8);
      ld = ($urandom_range(0, 39) == 0);
      lv = $urandom;
      if ($urandom_range(0, 29) == 0) dir = ~dir;
      if ($urandom_range(0, 99) == 0) top = $urandom_range(1, 63);
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
