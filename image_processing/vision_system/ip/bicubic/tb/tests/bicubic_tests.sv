// ***************
// Filename: bicubic_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_bicubic testbench (tb_bicubic.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic check(input string label,
    input logic [PIX_W-1:0] a00,a01,a02,a03, a10,a11,a12,a13, a20,a21,a22,a23, a30,a31,a32,a33,
    input logic [31:0] tx, ty,
    input logic [PIX_W-1:0] expected);
    begin
      @(posedge clk);
      p00<=a00; p01<=a01; p02<=a02; p03<=a03;
      p10<=a10; p11<=a11; p12<=a12; p13<=a13;
      p20<=a20; p21<=a21; p22<=a22; p23<=a23;
      p30<=a30; p31<=a31; p32<=a32; p33<=a33;
      tx_q16 <= tx; ty_q16 <= ty; valid_in <= 1'b1;
      @(posedge clk);
      valid_in <= 1'b0;
      repeat (BICUBIC_LATENCY - 1) @(posedge clk);
      #1;
      checks = checks + 1;
      if (!valid_out) begin
        $display("[%s] FAIL: valid_out not asserted at expected latency", label);
        fails = fails + 1;
      end else if (pixel_out !== expected) begin
        $display("[%s] FAIL: pixel_out=0x%06h expected=0x%06h", label, pixel_out, expected);
        fails = fails + 1;
      end else begin
        $display("[%s] PASS: pixel_out=0x%06h", label, pixel_out);
      end
      @(posedge clk);
    end
  endtask
