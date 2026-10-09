// ***************
// Filename: bilinear_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_bilinear testbench (tb_bilinear.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic check(input string label, input logic [PIX_W-1:0] TL, TR, BL, BR,
                        input logic [7:0] FX, FY);
    logic [PIX_W-1:0] expected;
    begin
      expected[23:16] = ref_chan(TL[23:16], TR[23:16], BL[23:16], BR[23:16], FX, FY);
      expected[15:8]  = ref_chan(TL[15:8],  TR[15:8],  BL[15:8],  BR[15:8],  FX, FY);
      expected[7:0]   = ref_chan(TL[7:0],   TR[7:0],   BL[7:0],   BR[7:0],   FX, FY);

      @(posedge clk);
      tl <= TL; tr <= TR; bl <= BL; br <= BR; fx <= FX; fy <= FY; valid_in <= 1'b1;
      @(posedge clk);
      valid_in <= 1'b0;
      @(posedge clk);
      @(posedge clk);   // LATENCY=3: valid_out should now be asserted
      #1;
      checks = checks + 1;
      if (!valid_out) begin
        $display("[%s] FAIL: valid_out not asserted at expected 3-cycle latency", label);
        fails = fails + 1;
      end else if (pixel_out !== expected) begin
        $display("[%s] FAIL: pixel_out=0x%06h expected=0x%06h (TL=%06h TR=%06h BL=%06h BR=%06h fx=%0d fy=%0d)",
                   label, pixel_out, expected, TL, TR, BL, BR, FX, FY);
        fails = fails + 1;
      end else begin
        $display("[%s] PASS: pixel_out=0x%06h", label, pixel_out);
      end
      @(posedge clk);
    end
  endtask
