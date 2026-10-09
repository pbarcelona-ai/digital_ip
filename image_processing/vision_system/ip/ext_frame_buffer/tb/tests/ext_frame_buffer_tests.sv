// ***************
// Filename: ext_frame_buffer_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_ext_frame_buffer testbench
//   (tb_ext_frame_buffer.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     write_pixel
// Date: 2026-10-08
// ***************
  task automatic write_pixel(input logic [ADDR_W-1:0] address, input logic [PIX_W-1:0] value);
    begin
      @(negedge clk);
      wr_en = 1'b1;
      wr_addr = address;
      wr_data = value;
      do @(posedge clk);
      while (!wr_ready);
      @(negedge clk);
      wr_en = 1'b0;
    end
  endtask
