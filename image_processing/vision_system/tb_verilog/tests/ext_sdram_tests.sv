// ***************
// Filename: ext_sdram_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_ext_sdram testbench (tb_ext_sdram.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     write_reg
//     send_frame
// Date: 2026-10-08
// ***************
  task automatic write_reg(input logic [7:0] address, input logic [31:0] value);
    begin
      @(negedge clk);
      s_axil.awaddr = address;
      s_axil.wdata = value;
      s_axil.awvalid = 1'b1;
      s_axil.wvalid = 1'b1;
      do @(posedge clk);
      while (!(s_axil.awready && s_axil.wready));
      @(negedge clk);
      s_axil.awvalid = 1'b0;
      s_axil.wvalid = 1'b0;
      s_axil.bready = 1'b1;
      do @(posedge clk);
      while (!s_axil.bvalid);
      @(negedge clk);
      s_axil.bready = 1'b0;
    end
  endtask

  task automatic send_frame;
    integer x, y, index;
    begin
      index = 0;
      for (y = 0; y < HEIGHT; y = y + 1) begin
        for (x = 0; x < WIDTH; x = x + 1) begin
          @(negedge clk);
          s_axis.tvalid = 1'b1;
          s_axis.tdata = expected[index];
          s_axis.tlast = (x == WIDTH-1);
          s_axis.tuser = (index == 0);
          do @(posedge clk);
          while (!s_axis.tready);
          index = index + 1;
        end
        @(negedge clk);
        s_axis.tvalid = 1'b0;
        s_axis.tlast = 1'b0;
        s_axis.tuser = 1'b0;
        repeat (LINE_GAP_CYCLES) @(negedge clk);
      end
    end
  endtask
