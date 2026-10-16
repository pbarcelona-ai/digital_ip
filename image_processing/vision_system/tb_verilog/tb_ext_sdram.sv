`timescale 1ns/1ps
import barrel_pkg::*;

module tb_ext_sdram;
  localparam int WIDTH = 4;
  localparam int HEIGHT = 4;
  localparam int FRAME_PIXELS = WIDTH * HEIGHT;

  logic clk = 0;
  logic rst_n = 0;
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) s_axis ();
  initial s_axis.tvalid = 0;
  initial s_axis.tdata = 0;
  initial s_axis.tlast = 0;
  initial s_axis.tuser = 0;
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) m_axis ();
  initial m_axis.tready = 1;

  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  initial s_axil.awaddr = 0;
  initial s_axil.awvalid = 0;
  initial s_axil.wdata = 0;
  initial s_axil.wstrb = 4'hf;
  initial s_axil.wvalid = 0;
  initial s_axil.bready = 0;
  initial s_axil.araddr = 0;
  initial s_axil.arvalid = 0;
  initial s_axil.rready = 0;

  wire sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
  wire [12:0] sdram_a;
  wire [1:0] sdram_ba;
  wire [7:0] sdram_dqm;
  tri [63:0] sdram_dq;

  logic [PIX_W-1:0] expected [0:FRAME_PIXELS-1];
  integer output_count = 0;
  integer errors = 0;

  vision_system #(
    .USE_EXT_FB(1'b1),
    .SDRAM_DQ_W(64),
    .SDRAM_A_W(13),
    .SDRAM_COL_W(4),
    .SDRAM_INIT_WAIT_CYCLES(4),
    .SDRAM_REFRESH_INTERVAL_CYCLES(60)
  ) dut (
    .*
  );

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

  // test tasks: tests/ext_sdram_tests.sv
  `include "ext_sdram_tests.sv"

  always @(posedge clk) begin
    if (rst_n && m_axis.tvalid && m_axis.tready) begin
      if (output_count >= FRAME_PIXELS) begin
        $display("FAIL: too many output pixels");
        errors <= errors + 1;
      end else begin
        if (m_axis.tdata !== expected[output_count]) begin
          $display("FAIL pixel %0d got=%h expected=%h", output_count, m_axis.tdata, expected[output_count]);
          errors <= errors + 1;
        end
        if (m_axis.tlast !== ((output_count % WIDTH) == WIDTH-1)) begin
          $display("FAIL tlast at output pixel %0d", output_count);
          errors <= errors + 1;
        end
        if (m_axis.tuser !== (output_count == 0)) begin
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
    write_reg(8'h18, WIDTH);
    write_reg(8'h1C, HEIGHT);
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

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do this
  // when VCD=1; SURFER=1 then opens it, see synth/view_waves.sh).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_ext_sdram);
  end
`endif
endmodule