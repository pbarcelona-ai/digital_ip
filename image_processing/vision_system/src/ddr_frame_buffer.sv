// ***************
// Filename: ddr_frame_buffer.sv
// Author: FPGA Cores 4 U
// Description: DDR-backed frame buffer for vision_system (replaces ext_frame_buffer).
//   Two ping-pong frame buffers in DDR (base addresses FB0_BASE, FB1_BASE).
//   Write path: queued AXI4 write bursts (64-byte aligned, up to 256 beats).
//   Read path: AXI4 read bursts with on-chip line cache (caches source rows
//   needed by the distortion correction's bilinear/bicubic interpolation).
//   Golden model: model/ddr_frame_buffer_model.py (clock exact; tb/python).
//   AXI4: full-width (DATA_W), INCR bursts, IDs passed through.
//   Clock - clk. Reset - synchronous active low rst_n.
// Date: 2026-10-24
module ddr_frame_buffer #(
  parameter int PIX_W = barrel_pkg::PIX_W,
  parameter int ADDR_W = barrel_pkg::ADDR_W,
  parameter int AXI_DATA_W = 256,
  parameter int AXI_ID_W = 4,
  parameter int AXI_ADDR_W = 32,
  parameter int CACHE_LINES = 8,              // number of source rows cached on-chip
  parameter int CACHE_LINE_W = 1024           // bits per cached line (AXI_DATA_W * beats)
) (
  input  logic clk,
  input  logic rst_n,

  // Write port (from axis_in_ctrl)
  input  logic                 wr_en,
  output logic                 wr_ready,
  input  logic [ADDR_W-1:0]    wr_addr,
  input  logic [PIX_W-1:0]     wr_data,
  output logic                 wr_idle,       // all writes completed

  // Read port (to axis_out_ctrl) - four addresses per cycle for bilinear/bicubic
  input  logic                 rd_en,
  output logic                 rd_ready,
  input  logic [ADDR_W-1:0]    rd_addr0,
  input  logic [ADDR_W-1:0]    rd_addr1,
  input  logic [ADDR_W-1:0]    rd_addr2,
  input  logic [ADDR_W-1:0]    rd_addr3,
  output logic                 rd_valid,
  output logic [PIX_W-1:0]     rd_data0,
  output logic [PIX_W-1:0]     rd_data1,
  output logic [PIX_W-1:0]     rd_data2,
  output logic [PIX_W-1:0]     rd_data3,

  // AXI4 master interface (to ddr_ctrl)
  output logic [AXI_ID_W-1:0]     m_axi_awid,
  output logic [AXI_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [AXI_DATA_W-1:0]   m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [AXI_ID_W-1:0]     m_axi_bid,
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,
  output logic [AXI_ID_W-1:0]     m_axi_arid,
  output logic [AXI_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [AXI_ID_W-1:0]     m_axi_rid,
  input  logic [AXI_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready,

  // Frame buffer base addresses (set via AXI4-Lite registers in vision_system)
  input  logic [AXI_ADDR_W-1:0]   fb0_base,
  input  logic [AXI_ADDR_W-1:0]   fb1_base,
  input  logic                    fb_select,      // 0: write to fb0, read from fb1; 1: write to fb1, read from fb0
  input  logic                    frame_done,     // pulse: swap buffers
  input  logic [ADDR_W-1:0]       frame_pixels    // IMG_WIDTH * IMG_HEIGHT
);

  localparam int PIX_PER_BEAT = AXI_DATA_W / PIX_W;
  localparam int BEATS_PER_LINE = 64;  // configurable based on line length
  localparam int AW = $clog2(AXI_DATA_W/8);

  // Write FIFO
  localparam int WR_FIFO_DEPTH = 32;
  localparam int WR_FIFO_AW = $clog2(WR_FIFO_DEPTH);
  logic [ADDR_W-1:0] wr_fifo_addr [WR_FIFO_DEPTH-1:0];
  logic [PIX_W-1:0]  wr_fifo_data [WR_FIFO_DEPTH-1:0];
  logic [WR_FIFO_AW-1:0] wr_rd_ptr, wr_wr_ptr;
  logic [WR_FIFO_AW:0] wr_count;

  // Read cache
  localparam int CACHE_TAG_W = ADDR_W - $clog2(CACHE_LINE_W/PIX_W);
  logic [CACHE_LINES-1:0] cache_valid;
  logic [CACHE_TAG_W-1:0] cache_tag [CACHE_LINES-1:0];
  logic [CACHE_LINE_W-1:0] cache_data [CACHE_LINES-1:0];
  logic [$clog2(CACHE_LINES)-1:0] cache_lru [CACHE_LINES-1:0];

  // AXI write state machine
  typedef enum logic [2:0] {
    WR_IDLE, WR_AR, WR_DATA, WR_RESP
  } wr_state_t;
  wr_state_t wr_state;
  logic [AXI_ADDR_W-1:0] wr_axi_addr;
  logic [7:0] wr_axi_len;
  logic [AXI_ID_W-1:0] wr_axi_id;
  logic wr_burst_active;
  logic [7:0] wr_beats_sent;

  // AXI read state machine
  typedef enum logic [2:0] {
    RD_IDLE, RD_CHECK_CACHE, RD_AR, RD_DATA
  } rd_state_t;
  rd_state_t rd_state;
  logic [ADDR_W-1:0] rd_addr_q [0:3];
  logic [1:0] rd_index;
  logic [AXI_ADDR_W-1:0] rd_axi_addr;
  logic [7:0] rd_axi_len;
  logic [AXI_ID_W-1:0] rd_axi_id;
  logic rd_burst_active;

  // Frame buffer swap
  logic fb_write_base, fb_read_base;
  logic frame_done_q;

  // Write path
  assign wr_ready = (wr_count < WR_FIFO_DEPTH) && !wr_burst_active && (wr_state == WR_IDLE);

  // Write FIFO push/pop
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_rd_ptr <= '0;
      wr_wr_ptr <= '0;
      wr_count <= '0;
    end else begin
      if (wr_en && wr_ready) begin
        wr_fifo_addr[wr_wr_ptr] <= wr_addr;
        wr_fifo_data[wr_wr_ptr] <= wr_data;
        wr_wr_ptr <= wr_wr_ptr + 1'b1;
      end
      if (wr_state == WR_DATA && m_axi_wready && wr_beats_sent == wr_axi_len) begin
        wr_rd_ptr <= wr_rd_ptr + 1'b1;
      end
      case ({wr_en && wr_ready, wr_state == WR_DATA && m_axi_wready && wr_beats_sent == wr_axi_len})
        2'b10: wr_count <= wr_count + 1'b1;
        2'b01: wr_count <= wr_count - 1'b1;
        default: ;
      endcase
    end
  end

  assign wr_idle = (wr_count == 0) && !wr_burst_active && (wr_state == WR_IDLE);

  // Write state machine
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_state <= WR_IDLE;
      wr_burst_active <= 1'b0;
      wr_axi_id <= '0;
      wr_beats_sent <= '0;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid <= 1'b0;
      m_axi_wlast <= 1'b0;
      m_axi_bready <= 1'b1;
    end else begin
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid <= 1'b0;
      m_axi_wlast <= 1'b0;

      case (wr_state)
        WR_IDLE: begin
          if (wr_count != 0 && !wr_burst_active) begin
            // Start a new write burst
            logic [ADDR_W-1:0] addr;
            addr = wr_fifo_addr[wr_rd_ptr];
            wr_axi_addr = {fb_write_base ? fb1_base : fb0_base} + (addr << AW);
            wr_axi_len = 8'd15;  // 16 beats = 512 bytes (adjust based on line length)
            wr_axi_id <= wr_axi_id + 1'b1;
            wr_beats_sent <= '0;
            wr_burst_active <= 1'b1;
            wr_state <= WR_AR;
          end
        end
        WR_AR: begin
          m_axi_awid <= wr_axi_id;
          m_axi_awaddr <= wr_axi_addr;
          m_axi_awlen <= wr_axi_len;
          m_axi_awsize <= 3'b100;  // 16 bytes (128 bits) - adjust for AXI_DATA_W
          m_axi_awburst <= 2'b01;
          m_axi_awvalid <= 1'b1;
          if (m_axi_awready) begin
            wr_state <= WR_DATA;
          end
        end
        WR_DATA: begin
          logic [PIX_PER_BEAT*PIX_W-1:0] beat_data;
          logic [PIX_PER_BEAT-1:0] beat_valid;
          
          // Pack pixels into AXI beat
          for (int i = 0; i < PIX_PER_BEAT; i++) begin
            if (wr_rd_ptr + i < wr_wr_ptr || (wr_rd_ptr + i - wr_wr_ptr + WR_FIFO_DEPTH) < wr_count) begin
              beat_data[i*PIX_W +: PIX_W] = wr_fifo_data[(wr_rd_ptr + i) % WR_FIFO_DEPTH];
              beat_valid[i] = 1'b1;
            end else begin
              beat_data[i*PIX_W +: PIX_W] = '0;
              beat_valid[i] = 1'b0;
            end
          end

          m_axi_wdata <= beat_data;
          m_axi_wstrb <= {PIX_PER_BEAT{1'b1}};
          m_axi_wvalid <= 1'b1;
          m_axi_wlast <= (wr_beats_sent == wr_axi_len);
          
          if (m_axi_wready) begin
            wr_beats_sent <= wr_beats_sent + 1'b1;
            if (wr_beats_sent == wr_axi_len) begin
              wr_state <= WR_RESP;
            end
          end
        end
        WR_RESP: begin
          if (m_axi_bvalid) begin
            wr_burst_active <= 1'b0;
            wr_state <= WR_IDLE;
          end
        end
      endcase
    end
  end

  // Read cache lookup
  function automatic logic [$clog2(CACHE_LINES)-1:0] cache_lookup(input logic [ADDR_W-1:0] addr);
    logic [CACHE_TAG_W-1:0] tag;
    tag = addr >> $clog2(CACHE_LINE_W/PIX_W);
    for (int i = 0; i < CACHE_LINES; i++) begin
      if (cache_valid[i] && cache_tag[i] == tag) begin
        return i[$clog2(CACHE_LINES)-1:0];
      end
    end
    return '0;  // not found (will trigger miss)
  endfunction

  // Read state machine (simplified - just shows structure)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_state <= RD_IDLE;
      rd_index <= '0;
      rd_burst_active <= 1'b0;
      rd_axi_id <= '0;
      rd_valid <= 1'b0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready <= 1'b1;
      cache_valid <= '0;
      for (int i = 0; i < CACHE_LINES; i++) begin
        cache_tag[i] <= '0;
        cache_lru[i] <= i[$clog2(CACHE_LINES)-1:0];
      end
    end else begin
      rd_valid <= 1'b0;
      m_axi_arvalid <= 1'b0;

      case (rd_state)
        RD_IDLE: begin
          if (rd_en && rd_ready) begin
            rd_addr_q[0] <= rd_addr0;
            rd_addr_q[1] <= rd_addr1;
            rd_addr_q[2] <= rd_addr2;
            rd_addr_q[3] <= rd_addr3;
            rd_index <= '0;
            rd_state <= RD_CHECK_CACHE;
          end
        end
        RD_CHECK_CACHE: begin
          // Check cache for rd_addr_q[rd_index]
          logic [$clog2(CACHE_LINES)-1:0] line;
          line = cache_lookup(rd_addr_q[rd_index]);
          if (cache_valid[line] && cache_tag[line] == (rd_addr_q[rd_index] >> $clog2(CACHE_LINE_W/PIX_W))) begin
            // Cache hit
            logic [CACHE_LINE_W-1:0] line_data;
            line_data = cache_data[line];
            logic [$clog2(CACHE_LINE_W/PIX_W)-1:0] offset;
            offset = rd_addr_q[rd_index][$clog2(CACHE_LINE_W/PIX_W)-1:0];
            case (rd_index)
              2'd0: rd_data0 <= line_data[offset*PIX_W +: PIX_W];
              2'd1: rd_data1 <= line_data[offset*PIX_W +: PIX_W];
              2'd2: rd_data2 <= line_data[offset*PIX_W +: PIX_W];
              2'd3: rd_data3 <= line_data[offset*PIX_W +: PIX_W];
            endcase
            // Update LRU
            for (int i = 0; i < CACHE_LINES; i++) begin
              if (cache_lru[i] > cache_lru[line]) cache_lru[i] <= cache_lru[i] - 1'b1;
            end
            cache_lru[line] <= CACHE_LINES - 1;

            if (rd_index == 2'd3) begin
              rd_valid <= 1'b1;
              rd_state <= RD_IDLE;
            end else begin
              rd_index <= rd_index + 1'b1;
            end
          end else begin
            // Cache miss - issue AXI read burst
            rd_axi_addr = {fb_read_base ? fb1_base : fb0_base} + (rd_addr_q[rd_index] << AW);
            rd_axi_len = 8'd15;  // read a full cache line
            rd_axi_id <= rd_axi_id + 1'b1;
            rd_burst_active <= 1'b1;
            rd_state <= RD_AR;
          end
        end
        RD_AR: begin
          m_axi_arid <= rd_axi_id;
          m_axi_araddr <= rd_axi_addr;
          m_axi_arlen <= rd_axi_len;
          m_axi_arsize <= 3'b100;
          m_axi_arburst <= 2'b01;
          m_axi_arvalid <= 1'b1;
          if (m_axi_arready) begin
            rd_state <= RD_DATA;
          end
        end
        RD_DATA: begin
          if (m_axi_rvalid) begin
            // Store in cache
            logic [$clog2(CACHE_LINES)-1:0] victim;
            victim = '0;
            for (int i = 1; i < CACHE_LINES; i++) begin
              if (cache_lru[i] > cache_lru[victim]) victim = i[$clog2(CACHE_LINES)-1:0];
            end
            cache_valid[victim] <= 1'b1;
            cache_tag[victim] <= rd_axi_addr >> (AW + $clog2(CACHE_LINE_W/PIX_W));
            cache_data[victim] <= m_axi_rdata;
            for (int i = 0; i < CACHE_LINES; i++) begin
              if (cache_lru[i] > cache_lru[victim]) cache_lru[i] <= cache_lru[i] - 1'b1;
            end
            cache_lru[victim] <= CACHE_LINES - 1;

            // Return data
            logic [$clog2(CACHE_LINE_W/PIX_W)-1:0] offset;
            offset = rd_addr_q[rd_index][$clog2(CACHE_LINE_W/PIX_W)-1:0];
            case (rd_index)
              2'd0: rd_data0 <= m_axi_rdata[offset*PIX_W +: PIX_W];
              2'd1: rd_data1 <= m_axi_rdata[offset*PIX_W +: PIX_W];
              2'd2: rd_data2 <= m_axi_rdata[offset*PIX_W +: PIX_W];
              2'd3: rd_data3 <= m_axi_rdata[offset*PIX_W +: PIX_W];
            endcase

            if (m_axi_rlast) begin
              rd_burst_active <= 1'b0;
              if (rd_index == 2'd3) begin
                rd_valid <= 1'b1;
                rd_state <= RD_IDLE;
              end else begin
                rd_index <= rd_index + 1'b1;
                rd_state <= RD_CHECK_CACHE;
              end
            end
          end
        end
      endcase
    end
  end

  // Frame buffer swap on frame_done pulse
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fb_write_base <= 1'b0;
      fb_read_base <= 1'b1;
      frame_done_q <= 1'b0;
    end else begin
      frame_done_q <= frame_done;
      if (frame_done && !frame_done_q) begin
        fb_write_base <= ~fb_write_base;
        fb_read_base <= ~fb_read_base;
        cache_valid <= '0;  // invalidate cache on buffer swap
      end
    end
  end

  // rd_ready when not in active read burst and cache can accept
  assign rd_ready = (rd_state == RD_IDLE) || (rd_state == RD_CHECK_CACHE && 
    (cache_valid[cache_lookup(rd_addr_q[rd_index])] && 
     cache_tag[cache_lookup(rd_addr_q[rd_index])] == (rd_addr_q[rd_index] >> $clog2(CACHE_LINE_W/PIX_W))));

endmodule
