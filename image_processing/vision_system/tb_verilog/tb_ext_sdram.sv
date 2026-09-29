`timescale 1ns/1ps
import barrel_pkg::*;

module tb_ext_sdram;
  localparam int WIDTH = 4;
  localparam int HEIGHT = 4;
  localparam int FRAME_PIXELS = WIDTH * HEIGHT;

  logic clk = 0;
  logic rst_n = 0;
  logic s_axis_tvalid = 0;
  wire s_axis_tready;
  logic [PIX_W-1:0] s_axis_tdata = 0;
  logic s_axis_tlast = 0;
  logic s_axis_tuser = 0;
  wire m_axis_tvalid;
  logic m_axis_tready = 1;
  wire [PIX_W-1:0] m_axis_tdata;
  wire m_axis_tlast, m_axis_tuser;

  logic [7:0] s_axil_awaddr = 0, s_axil_araddr = 0;
  logic s_axil_awvalid = 0, s_axil_wvalid = 0, s_axil_bready = 0;
  logic [31:0] s_axil_wdata = 0;
  logic [3:0] s_axil_wstrb = 4'hf;
  wire s_axil_awready, s_axil_wready;
  wire [1:0] s_axil_bresp;
  wire s_axil_bvalid;
  logic s_axil_arvalid = 0, s_axil_rready = 0;
  wire s_axil_arready;
  wire [31:0] s_axil_rdata;
  wire [1:0] s_axil_rresp;
  wire s_axil_rvalid;

  wire sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
  wire [12:0] sdram_a;
  wire [1:0] sdram_ba;
  wire [7:0] sdram_dqm;
  tri [63:0] sdram_dq;

  logic [PIX_W-1:0] expected [0:FRAME_PIXELS-1];
  integer output_count = 0;
  integer errors = 0;

  vision_system #(
    .USE_EXT_FB(1'b1), .SDRAM_DQ_W(64), .SDRAM_A_W(13),
    .SDRAM_COL_W(4), .SDRAM_INIT_WAIT_CYCLES(4),
    .SDRAM_REFRESH_INTERVAL_CYCLES(60)
  ) dut (.*);

  always #5 clk = ~clk;

  logic [63:0] dram [0:4095];
  logic [12:0] model_row;
  logic model_row_open;
  logic model_dq_oe;
  logic [63:0] model_dq_out;
  logic read_pending;
  integer read_wait;
  logic [12:0] pending_row;
  logic [3:0] pending_col;
  assign sdram_dq = model_dq_oe ? model_dq_out : 64'bz;

  always @(posedge clk) begin
    model_dq_oe <= 1'b0;
    if (!rst_n) begin
      model_row <= '0;
      model_row_open <= 1'b0;
      read_pending <= 1'b0;
      read_wait <= 0;
      pending_row <= '0;
      pending_col <= '0;
    end else begin
      if (read_pending) begin
        if (read_wait <= 1) begin
          model_dq_out <= dram[(pending_row << 4) | pending_col];
          model_dq_oe <= 1'b1;
          read_pending <= 1'b0;
        end else read_wait <= read_wait - 1;
      end

      if (sdram_cke && !sdram_cs_n) begin
        if (!sdram_ras_n && sdram_cas_n && sdram_we_n) begin
          model_row <= sdram_a;
          model_row_open <= 1'b1;
        end else if (!sdram_ras_n && sdram_cas_n && !sdram_we_n) begin
          model_row_open <= 1'b0;
        end else if (!sdram_ras_n && !sdram_cas_n && !sdram_we_n) begin
          model_row_open <= 1'b0;
        end else if (sdram_ras_n && !sdram_cas_n && sdram_we_n) begin
          if (!model_row_open) $fatal(1, "SDRAM READ without active row");
          pending_row <= model_row;
          pending_col <= sdram_a[3:0];
          read_wait <= 2;
          read_pending <= 1'b1;
        end else if (sdram_ras_n && !sdram_cas_n && !sdram_we_n) begin
          if (!model_row_open) $fatal(1, "SDRAM WRITE without active row");
          dram[(model_row << 4) | sdram_a[3:0]] <= sdram_dq;
        end
      end
    end
  end

  task automatic write_reg(input logic [7:0] address, input logic [31:0] value);
    begin
      @(negedge clk);
      s_axil_awaddr = address;
      s_axil_wdata = value;
      s_axil_awvalid = 1'b1;
      s_axil_wvalid = 1'b1;
      do @(posedge clk); while (!(s_axil_awready && s_axil_wready));
      @(negedge clk);
      s_axil_awvalid = 1'b0;
      s_axil_wvalid = 1'b0;
      s_axil_bready = 1'b1;
      do @(posedge clk); while (!s_axil_bvalid);
      @(negedge clk);
      s_axil_bready = 1'b0;
    end
  endtask

  task automatic send_frame;
    integer x, y, index;
    begin
      index = 0;
      for (y = 0; y < HEIGHT; y = y + 1) begin
        for (x = 0; x < WIDTH; x = x + 1) begin
          @(negedge clk);
          s_axis_tvalid = 1'b1;
          s_axis_tdata = expected[index];
          s_axis_tlast = (x == WIDTH-1);
          s_axis_tuser = (index == 0);
          do @(posedge clk); while (!s_axis_tready);
          index = index + 1;
        end
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tuser = 1'b0;
        repeat (LINE_GAP_CYCLES) @(negedge clk);
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
      if (output_count >= FRAME_PIXELS) begin
        $display("FAIL: too many output pixels");
        errors <= errors + 1;
      end else begin
        if (m_axis_tdata !== expected[output_count]) begin
          $display("FAIL pixel %0d got=%h expected=%h", output_count, m_axis_tdata, expected[output_count]);
          errors <= errors + 1;
        end
        if (m_axis_tlast !== ((output_count % WIDTH) == WIDTH-1)) begin
          $display("FAIL tlast at output pixel %0d", output_count);
          errors <= errors + 1;
        end
        if (m_axis_tuser !== (output_count == 0)) begin
          $display("FAIL tuser at output pixel %0d", output_count);
          errors <= errors + 1;
        end
      end
      output_count <= output_count + 1;
    end
  end

  initial begin
    for (int n = 0; n < FRAME_PIXELS; n++)
      expected[n] = PIX_W'(24'h103050 + n * 24'h010307);
    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    wait (dut.g_ext_frame_buffer.u_fb.initialized);
    write_reg(8'h08, WIDTH);
    write_reg(8'h0c, HEIGHT);
    repeat (100) @(negedge clk);

    fork
      send_frame();
      begin
        wait (output_count == FRAME_PIXELS);
        repeat (2) @(negedge clk);
        if (errors != 0) $fatal(1, "external SDRAM system had %0d errors", errors);
        $display("EXT SDRAM SYSTEM PASS: %0d identity pixels and stream markers", output_count);
        $display(">>> PASS <<<");
        $finish;
      end
      begin
        repeat (100000) @(negedge clk);
        $fatal(1, "timed out waiting for external SDRAM output frame");
      end
    join_any
  end
endmodule