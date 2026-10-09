// ***************
// Filename: bounded_fisheye_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_bounded_fisheye testbench
//   (tb_bounded_fisheye.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     axil_write       AXI4-Lite write of one register
//     axil_read        AXI4-Lite read of one register
//     stream_frame_in  Streams one input frame into the DUT (AXI4-Stream,
//                      tuser = start of frame)
//     capture_bounded  Bounded capture
// Date: 2026-10-08
// ***************
  task automatic axil_write(input int addr, input longint data);
    begin
      @(posedge clk);
      s_axil_awaddr  <= addr[7:0];
      s_axil_awvalid <= 1'b1;
      s_axil_wdata   <= data[31:0];
      s_axil_wstrb <= 4'hF;
      s_axil_wvalid <= 1'b1;
      @(posedge clk);
      s_axil_awvalid <= 1'b0;
      s_axil_wvalid <= 1'b0;
      while (s_axil_bvalid !== 1'b1) @(posedge clk);
      s_axil_bready <= 1'b1;
      @(posedge clk);
      s_axil_bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input int addr, output logic [31:0] data);
    begin
      @(posedge clk);
      s_axil_araddr <= addr[7:0];
      s_axil_arvalid <= 1'b1;
      @(posedge clk);
      s_axil_arvalid <= 1'b0;
      while (s_axil_rvalid !== 1'b1) @(posedge clk);
      data = s_axil_rdata;
      s_axil_rready <= 1'b1;
      @(posedge clk);
      s_axil_rready <= 1'b0;
    end
  endtask

  task automatic stream_frame_in(input int w, input int h,
      input logic [7:0] r[], input logic [7:0] g[], input logic [7:0] b[]);
    int xx,yy;
    begin
      for (yy=0; yy<h; yy++) begin
        for (xx=0; xx<w; xx++) begin
          s_axis_tvalid <= 1'b1;
          s_axis_tdata <= {r[yy*w+xx], g[yy*w+xx], b[yy*w+xx]};
          s_axis_tlast <= (xx==w-1);
          s_axis_tuser <= (xx==0)&&(yy==0);
          @(posedge clk);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast <= 1'b0;
        s_axis_tuser <= 1'b0;
        repeat(5) @(posedge clk);
      end
    end
  endtask

  // Bounded capture: stops after max_cap pixels rather than the full
  // W*H frame (the slow per-pixel-divide models cannot stream a full
  // multi-hundred-thousand-pixel frame within a practical simulation
  // time budget -- see README). Since capture proceeds in strict raster
  // order from (0,0), this still exercises the FULL x-coordinate range
  // (0..w-1) from the very first row, plus a substantial y range too.
  task automatic capture_bounded(input int w, input int max_n);
    begin
      cap_r = new[max_n];
      cap_g = new[max_n];
      cap_b = new[max_n];
      cap_count=0;
      while (cap_count < max_n) begin
        @(posedge clk);
        if (m_axis_tvalid===1'b1 && m_axis_tready===1'b1) begin
          cap_r[cap_count]=m_axis_tdata[23:16];
          cap_g[cap_count]=m_axis_tdata[15:8];
          cap_b[cap_count]=m_axis_tdata[7:0];
          cap_count++;
        end
      end
    end
  endtask
