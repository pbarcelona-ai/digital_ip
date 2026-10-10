`timescale 1ns/1ps
import barrel_pkg::*;

module tb_ext_frame_buffer;
  localparam int PIX_W = 24;
  localparam int ADDR_W = 8;
  localparam int COL_W = 4;
  localparam int SDRAM_A_W = 13;

  logic clk = 0;
  logic rst_n = 0;
  logic wr_en = 0;
  wire wr_ready;
  logic [ADDR_W-1:0] wr_addr = 0;
  logic [PIX_W-1:0] wr_data = 0;
  wire wr_idle;
  logic rd_en = 0;
  wire rd_ready;
  logic [ADDR_W-1:0] rd_addr0 = 0, rd_addr1 = 0, rd_addr2 = 0, rd_addr3 = 0;
  wire rd_valid;
  wire [PIX_W-1:0] rd_data0, rd_data1, rd_data2, rd_data3;
  wire sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
  wire [SDRAM_A_W-1:0] sdram_a;
  wire [1:0] sdram_ba;
  wire [7:0] sdram_dqm;
  tri [63:0] sdram_dq;

  ext_frame_buffer #(
    .PIX_W(PIX_W),
    .ADDR_W(ADDR_W),
    .SDRAM_DQ_W(64),
    .SDRAM_A_W(SDRAM_A_W),
    .COL_W(COL_W),
    .FIFO_DEPTH(8),
    .FIFO_AW(3),
    .INIT_WAIT_CYCLES(4),
    .T_RP_CYCLES(1),
    .T_RCD_CYCLES(1),
    .T_RFC_CYCLES(1),
    .T_MRD_CYCLES(1),
    .T_WR_CYCLES(1),
    .CAS_LATENCY(2),
    .REFRESH_INTERVAL_CYCLES(12)
  ) dut (.*);

  always #5 clk = ~clk;

  logic [63:0] dram [0:(1<<ADDR_W)-1];
  logic [SDRAM_A_W-1:0] model_row;
  logic model_row_open;
  logic model_dq_oe;
  logic [63:0] model_dq_out;
  logic read_pending;
  int read_wait;
  int refresh_count;
  logic [SDRAM_A_W-1:0] pending_row;
  logic [COL_W-1:0] pending_col;
  assign sdram_dq = model_dq_oe ? model_dq_out : 64'bz;

  always @(posedge clk) begin
    model_dq_oe <= 1'b0;
    if (!rst_n) begin
      model_row <= '0;
      model_row_open <= 1'b0;
      read_pending <= 1'b0;
      read_wait <= 0;
      refresh_count <= 0;
      pending_row <= '0;
      pending_col <= '0;
    end else begin
      if (read_pending) begin
        if (read_wait <= 1) begin
          model_dq_out <= dram[(pending_row << COL_W) | pending_col];
          model_dq_oe <= 1'b1;
          read_pending <= 1'b0;
        end else read_wait <= read_wait - 1;
      end

      if (!sdram_cs_n) begin
        if (!sdram_ras_n && sdram_cas_n && sdram_we_n) begin
          model_row <= sdram_a;
          model_row_open <= 1'b1;
        end else if (!sdram_ras_n && sdram_cas_n && !sdram_we_n) begin
          model_row_open <= 1'b0;
        end else if (!sdram_ras_n && !sdram_cas_n && !sdram_we_n) begin
          model_row_open <= 1'b0;
        end else if (!sdram_ras_n && !sdram_cas_n && sdram_we_n) begin
          refresh_count <= refresh_count + 1;
        end else if (sdram_ras_n && !sdram_cas_n && sdram_we_n) begin
          if (!model_row_open) $fatal(1, "READ issued without an active row");
          pending_row <= model_row;
          pending_col <= sdram_a[COL_W-1:0];
          read_wait <= 2;
          read_pending <= 1'b1;
        end else if (sdram_ras_n && !sdram_cas_n && !sdram_we_n) begin
          if (!model_row_open) $fatal(1, "WRITE issued without an active row");
          dram[(model_row << COL_W) | sdram_a[COL_W-1:0]] <= sdram_dq;
        end
      end
    end
  end

  // test tasks: tests/ext_frame_buffer_tests.sv
  `include "ext_frame_buffer_tests.sv"

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int n = 0; n < 12; n++) begin
      write_pixel(ADDR_W'(n * 13), PIX_W'(24'hab1200 + n));
    end

    wait (wr_idle);
    if (refresh_count < 3) $fatal(1, "periodic SDRAM refresh was not issued during writes");
    @(negedge clk);
    if (!rd_ready) $fatal(1, "read interface did not become ready after writes drained");
    rd_addr0 = 0;
    rd_addr1 = 13;
    rd_addr2 = 26;
    rd_addr3 = 143;
    rd_en = 1'b1;
    @(negedge clk);
    rd_en = 1'b0;

    for (int timeout = 0; timeout < 500; timeout++) begin
      @(negedge clk);
      if (rd_valid) begin
        if (rd_data0 !== 24'hab1200 || rd_data1 !== 24'hab1201 ||
            rd_data2 !== 24'hab1202 || rd_data3 !== 24'hab120b)
          $fatal(1, "bad read data: %h %h %h %h", rd_data0, rd_data1, rd_data2, rd_data3);
        $display("EXT FRAME BUFFER PASS: initialization, queued writes, and four reads");
        $display(">>> PASS <<<");
        $finish;
      end
    end
    $fatal(1, "timed out waiting for serialized read response");
  end

  initial begin
    #1000000;
    $fatal(1, "SDRAM write/refresh test timed out");
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do this
  // when VCD=1; SURFER=1 then opens it, see synth/view_waves.sh).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_ext_frame_buffer);
  end
`endif
endmodule