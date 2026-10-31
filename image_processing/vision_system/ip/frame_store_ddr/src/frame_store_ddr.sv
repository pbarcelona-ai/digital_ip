// ***************
// Filename: frame_store_ddr.sv
// Author: FPGA Cores 4 U
// Description: Double-buffered DDR-backed frame store with on-chip row cache for
//   vision_system. The store uses ddr_ctrl (AXI4 multi-port) and ddr_mem (DFI
//   memory model) to store frames in external DDR. Two frame buffers in DDR
//   (ping-pong): the writer fills one while the reader reads from the other.
//   At frame boundaries the buffers swap. An on-chip row cache keeps recently-
//   accessed source rows (the correction mapping is locally smooth).
//   Write port: sequential raster writes (wr_en, wr_addr, wr_data)
//   Read port: four-address reads for bilinear/bicubic interpolation
//   (rd_en, rd_addr0..3 -> rd_data0..3, rd_valid)
//   Golden model: model/frame_store_ddr_model.py (clock exact; tb/python).
//   Parameters: PIX_W, ADDR_W, frame dimensions, DDR parameters, cache size.
//   Clock - clk. Reset - synchronous active low rst_n.
//   Clock-domain crossings - none (single clock).
// Date: 2026-10-24
module frame_store_ddr #(
  parameter int PIX_W        = 24,              // pixel width (RGB888)
  parameter int ADDR_W       = 20,              // address bits per frame
  parameter int FRAME_WIDTH  = 1920,            // frame width in pixels
  parameter int FRAME_HEIGHT = 1080,            // frame height in pixels
  parameter int CACHE_LINES  = 8,               // number of cached rows
  parameter int CACHE_LINE_W = 11,              // log2 pixels per cached row (2048)
  // DDR controller parameters
  parameter int DDR_NPORTS   = 2,               // write port + read port
  parameter int DDR_DATA_W   = 256,             // DDR data width
  parameter int DDR_ADDR_W   = 32,              // DDR address width (byte address)
  parameter int DDR_ID_W     = 4,               // DDR ID width
  parameter int DDR_BANK_W   = 3,               // DDR bank bits
  parameter int DDR_ROW_W    = 14,              // DDR row bits
  parameter int DDR_COL_W    = 8,               // DDR column bits
  parameter int DDR_T_RCD    = 4,
  parameter int DDR_T_RP     = 4,
  parameter int DDR_T_RAS    = 10,
  parameter int DDR_T_CL     = 5,
  parameter int DDR_T_WR     = 4,
  parameter int DDR_T_RTP    = 2,
  parameter int DDR_T_WTR    = 2,
  parameter int DDR_T_RRD    = 2,
  parameter int DDR_T_RFC    = 30,
  parameter int DDR_T_REFI   = 1950,
  parameter int DDR_PRIORITY = 0,               // 0 round robin, 1 fixed
  parameter int DDR_RQ_DEPTH = 16,
  parameter int DDR_BQ_DEPTH = 2,
  // DDR memory parameters
  parameter int DDR_MEM_WORDS = 1 << 16,
  parameter int DDR_REF_MAX   = 9 * 1950
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // Write port (writer modport)
  input  logic                       wr_en,
  input  logic [ADDR_W-1:0]          wr_addr,
  input  logic [PIX_W-1:0]           wr_data,
  input  logic                       wr_buf_sel,      // 0 or 1
  input  logic                       wr_frame_done,   // frame write complete
  output logic                       wr_ready,
  input  logic                       swap_buf,        // swap buffers
  input  logic                       cache_flush,     // flush row cache
  output logic                       buf_swapped,
  output logic                       cache_flushed,
  output logic                       store_idle,
  output logic [1:0]                 wr_fill,         // 0 empty, 1 partial, 2 full, 3 overflow
  output logic [1:0]                 rd_fill,

  // Read port (reader modport)
  input  logic                       rd_en,
  input  logic [ADDR_W-1:0]          rd_addr0,
  input  logic [ADDR_W-1:0]          rd_addr1,
  input  logic [ADDR_W-1:0]          rd_addr2,
  input  logic [ADDR_W-1:0]          rd_addr3,
  input  logic                       rd_buf_sel,      // 0 or 1
  output logic                       rd_ready,
  output logic                       rd_valid,
  output logic [PIX_W-1:0]           rd_data0,
  output logic [PIX_W-1:0]           rd_data1,
  output logic [PIX_W-1:0]           rd_data2,
  output logic [PIX_W-1:0]           rd_data3,

  // AXI4-Lite register interface (for DDR controller config)
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
  // ddr_ctrl_regs_if is connected internally
  // (registers exposed through ddr_ctrl_top.sv's s_axil)

  // DDR controller DFI interface (to ddr_mem)
  output logic [2:0]                 dfi_cmd_o,
  output logic [DDR_BANK_W-1:0]      dfi_bank_o,
  output logic [DDR_ROW_W-1:0]       dfi_row_o,
  output logic [DDR_COL_W-1:0]       dfi_col_o,
  output logic [DDR_DATA_W-1:0]      dfi_wrdata_o,
  output logic [DDR_DATA_W/8-1:0]    dfi_wrstrb_o,
  input  logic                       dfi_rddata_valid_i,
  input  logic [DDR_DATA_W-1:0]      dfi_rddata_i
);

  // ---------------------------------------------------------------------------
  // Local parameters and constants
  // ---------------------------------------------------------------------------
  localparam int FRAME_SIZE     = FRAME_WIDTH * FRAME_HEIGHT;
  // Pixels per DDR word (floor) - used for address stride
  localparam int PIX_PER_WORD   = DDR_DATA_W / PIX_W;
  // Bytes per DDR word
  localparam int BYTES_PER_WORD = DDR_DATA_W / 8;
  // Byte offset bits within DDR word
  localparam int OFF            = $clog2(BYTES_PER_WORD);
  // Frame words with padding (each pixel group gets a full word)
  localparam int FRAME_WORDS    = (FRAME_SIZE + PIX_PER_WORD - 1) / PIX_PER_WORD;
  // Frame bytes (aligned to DDR word boundary)
  localparam int FRAME_BYTES    = FRAME_WORDS * BYTES_PER_WORD;
  localparam int FRAME0_BASE    = 32'h0000_0000;
  localparam int FRAME1_BASE    = FRAME0_BASE + FRAME_BYTES;

  // Compile-time check: PIX_W must divide DDR_DATA_W for simple packing
  // If not, cross-word packing is required (not implemented)
  initial begin
    if (DDR_DATA_W % PIX_W != 0) begin
      $error("frame_store_ddr: PIX_W (%0d) must divide DDR_DATA_W (%0d) for current implementation", PIX_W, DDR_DATA_W);
    end
  end

  // ---------------------------------------------------------------------------
  // DDR controller instance (ddr_ctrl.sv directly)
  // ---------------------------------------------------------------------------
  logic [DDR_NPORTS*DDR_ID_W-1:0]     s_axi_awid;
  logic [DDR_NPORTS*DDR_ADDR_W-1:0]   s_axi_awaddr;
  logic [DDR_NPORTS*8-1:0]            s_axi_awlen;
  logic [DDR_NPORTS*3-1:0]            s_axi_awsize;
  logic [DDR_NPORTS*2-1:0]            s_axi_awburst;
  logic [DDR_NPORTS-1:0]              s_axi_awvalid;
  logic [DDR_NPORTS-1:0]              s_axi_awready;
  logic [DDR_NPORTS*DDR_DATA_W-1:0]   s_axi_wdata;
  logic [DDR_NPORTS*DDR_DATA_W/8-1:0] s_axi_wstrb;
  logic [DDR_NPORTS-1:0]              s_axi_wlast;
  logic [DDR_NPORTS-1:0]              s_axi_wvalid;
  logic [DDR_NPORTS-1:0]              s_axi_wready;
  logic [DDR_NPORTS*DDR_ID_W-1:0]     s_axi_bid;
  logic [DDR_NPORTS*2-1:0]            s_axi_bresp;
  logic [DDR_NPORTS-1:0]              s_axi_bvalid;
  logic [DDR_NPORTS-1:0]              s_axi_bready;
  logic [DDR_NPORTS*DDR_ID_W-1:0]     s_axi_arid;
  logic [DDR_NPORTS*DDR_ADDR_W-1:0]   s_axi_araddr;
  logic [DDR_NPORTS*8-1:0]            s_axi_arlen;
  logic [DDR_NPORTS*3-1:0]            s_axi_arsize;
  logic [DDR_NPORTS*2-1:0]            s_axi_arburst;
  logic [DDR_NPORTS-1:0]              s_axi_arvalid;
  logic [DDR_NPORTS-1:0]              s_axi_arready;
  logic [DDR_NPORTS*DDR_ID_W-1:0]     s_axi_rid;
  logic [DDR_NPORTS*DDR_DATA_W-1:0]   s_axi_rdata;
  logic [DDR_NPORTS*2-1:0]            s_axi_rresp;
  logic [DDR_NPORTS-1:0]              s_axi_rlast;
  logic [DDR_NPORTS-1:0]              s_axi_rvalid;
  logic [DDR_NPORTS-1:0]              s_axi_rready;

  // DDR controller register interface (not used for software access)
  ddr_ctrl_regs_if u_ddr_ctrl_regs_if ();
  assign u_ddr_ctrl_regs_if.cfg_ctrl = 1'b0;
  assign u_ddr_ctrl_regs_if.cfg_ctrl_wr = 1'b0;

  ddr_ctrl #(
    .NPORTS(DDR_NPORTS),
    .DATA_W(DDR_DATA_W),
    .ADDR_W(DDR_ADDR_W),
    .ID_W(DDR_ID_W),
    .BANK_W(DDR_BANK_W),
    .ROW_W(DDR_ROW_W),
    .COL_W(DDR_COL_W),
    .T_RCD(DDR_T_RCD),
    .T_RP(DDR_T_RP),
    .T_RAS(DDR_T_RAS),
    .T_CL(DDR_T_CL),
    .T_WR(DDR_T_WR),
    .T_RTP(DDR_T_RTP),
    .T_WTR(DDR_T_WTR),
    .T_RRD(DDR_T_RRD),
    .T_RFC(DDR_T_RFC),
    .T_REFI(DDR_T_REFI),
    .PRIORITY(DDR_PRIORITY),
    .RQ_DEPTH(DDR_RQ_DEPTH),
    .BQ_DEPTH(DDR_BQ_DEPTH)
  ) u_ddr_ctrl (
    .clk,
    .rst_n,
    .s_axi_awid,
    .s_axi_awaddr,
    .s_axi_awlen,
    .s_axi_awsize,
    .s_axi_awburst,
    .s_axi_awvalid,
    .s_axi_awready,
    .s_axi_wdata,
    .s_axi_wstrb,
    .s_axi_wlast,
    .s_axi_wvalid,
    .s_axi_wready,
    .s_axi_bid,
    .s_axi_bresp,
    .s_axi_bvalid,
    .s_axi_bready,
    .s_axi_arid,
    .s_axi_araddr,
    .s_axi_arlen,
    .s_axi_arsize,
    .s_axi_arburst,
    .s_axi_arvalid,
    .s_axi_arready,
    .s_axi_rid,
    .s_axi_rdata,
    .s_axi_rresp,
    .s_axi_rlast,
    .s_axi_rvalid,
    .s_axi_rready,
    .dfi_cmd_o,
    .dfi_bank_o,
    .dfi_row_o,
    .dfi_col_o,
    .dfi_wrdata_o,
    .dfi_wrstrb_o,
    .dfi_rddata_valid_i,
    .dfi_rddata_i,
    .regs(u_ddr_ctrl_regs_if)
  );

  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Frame store logic: write and read FSMs, buffer management, row cache
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    WR_IDLE,
    WR_BURST,
    WR_WAIT_BRESP
  } wr_state_t;

  typedef enum logic [1:0] {
    RD_IDLE,
    RD_ISSUE,
    RD_WAIT
  } rd_state_t;

  wr_state_t wr_state;
  rd_state_t rd_state;

  logic [ADDR_W-1:0] wr_addr_next;
  logic [31:0] wr_pixel_count;
  logic [31:0] rd_pixel_count;

  // Buffer bases in DDR (BYTE addresses)
  logic [DDR_ADDR_W-1:0] buf0_base_bytes, buf1_base_bytes;
  // Active buffer indices (0 or 1) - internal tracking
  logic                  wr_buf_q, rd_buf_q;
  logic                  swap_pending;
  logic                  frame0_written, frame1_written;

  // Write burst assembly: pack PIX_W pixels into DDR_DATA_W words
  logic [$clog2(PIX_PER_WORD):0] wr_pack_cnt;
  logic [DDR_DATA_W-1:0]         wr_pack_data;
  logic [DDR_DATA_W/8-1:0]       wr_pack_strb;
  logic                          wr_burst_active;
  logic [7:0]                    wr_burst_len;
  logic [DDR_ADDR_W-1:0]         wr_burst_addr;
  logic                          wr_aw_pending;    // AW channel pending
  logic                          wr_w_pending;     // W channel pending
  // Read side: issue 4-address reads as separate AXI reads
  logic [1:0]                    rd_addr_idx;
  logic [1:0]                    rd_resp_idx;   // which of the 4 responses we're receiving
  logic [3:0]                    rd_issued;     // which requests have been issued (AR handshake)
  logic [3:0]                    rd_completed;  // which responses have been received

  // Read address queue (latched at RD_ISSUE entry) - DECLARED BEFORE USE
  logic [ADDR_W-1:0] rd_addr_q [4];
  logic              rd_buf_q_latched;

  // Row cache storage (metadata only for now)
  typedef struct packed {
    logic                       valid;
    logic [ADDR_W-1:0]          row_base_addr;
    logic                       buf_sel;
  } cache_line_t;
  cache_line_t cache [0:CACHE_LINES-1];
  logic [$clog2(CACHE_LINES)-1:0] cache_victim;

  // ---------------------------------------------------------------------------
  // AXI channel combinational assignments
  // ---------------------------------------------------------------------------
  always_comb begin
    // Default assignments
    s_axi_awid    = '0;
    s_axi_awaddr  = '0;
    s_axi_awlen   = '0;
    s_axi_awsize  = '0;
    s_axi_awburst = '0;
    s_axi_awvalid = '0;
    s_axi_wdata   = '0;
    s_axi_wstrb   = '0;
    s_axi_wlast   = '0;
    s_axi_wvalid  = '0;
    s_axi_bready  = '0;
    s_axi_arid    = '0;
    s_axi_araddr  = '0;
    s_axi_arlen   = '0;
    s_axi_arsize  = '0;
    s_axi_arburst = '0;
    s_axi_arvalid = '0;
    s_axi_rready  = '0;

    // Port 0: write port
    if (wr_burst_active) begin
      s_axi_awid[DDR_ID_W-1:0]        = '0;
      s_axi_awaddr[DDR_ADDR_W-1:0]    = wr_burst_addr;  // BYTE address
      s_axi_awlen[7:0]                = wr_burst_len;
      s_axi_awsize[2:0]               = 3'(OFF);
      s_axi_awburst[1:0]              = 2'b01;  // INCR
      s_axi_awvalid[0]                = wr_aw_pending;
      s_axi_wdata[DDR_DATA_W-1:0]     = wr_pack_data;
      s_axi_wstrb[DDR_DATA_W/8-1:0]   = wr_pack_strb;
      s_axi_wlast[0]                  = 1'b1;
      s_axi_wvalid[0]                 = wr_w_pending;
    end
    // Port 1: read port
    if (rd_state == RD_ISSUE) begin
      logic [ADDR_W-1:0] addr_arr [4];
      logic [DDR_ADDR_W-1:0] word_addr;
      logic [DDR_ADDR_W-1:0] byte_addr;

      addr_arr[0] = rd_addr_q[0];
      addr_arr[1] = rd_addr_q[1];
      addr_arr[2] = rd_addr_q[2];
      addr_arr[3] = rd_addr_q[3];
      // Convert pixel address to byte address
      // word_addr = base_bytes/BYTES_PER_WORD + pixel_addr/PIX_PER_WORD
      // byte_addr = word_addr * BYTES_PER_WORD = base_bytes + (pixel_addr/PIX_PER_WORD)*BYTES_PER_WORD
      word_addr = ((rd_buf_q_latched == 1'b0 ? buf0_base_bytes : buf1_base_bytes) / BYTES_PER_WORD)
                  + (addr_arr[rd_addr_idx] / PIX_PER_WORD);
      byte_addr = word_addr * BYTES_PER_WORD;

      // Port 1 slices: [2*WIDTH-1:WIDTH] for all concatenated signals (port 0 is write-only)
      s_axi_arid[2*DDR_ID_W-1:DDR_ID_W]        = rd_addr_idx[DDR_ID_W-1:0];  // Use index as ID to track responses
      s_axi_araddr[2*DDR_ADDR_W-1:DDR_ADDR_W]  = byte_addr;
      s_axi_arlen[15:8]                        = 0;  // single beat
      s_axi_arsize[5:3]                        = 3'(OFF);
      s_axi_arburst[3:2]                       = 2'b01;  // INCR
      s_axi_arvalid[1]                         = 1'b1;
    end

    // Always ready for read data and write response
    s_axi_rready[1] = 1'b1;
    s_axi_bready[0] = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Write FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_state         <= WR_IDLE;
      wr_addr_next     <= '0;
      wr_pixel_count   <= '0;
      wr_pack_cnt      <= '0;
      wr_pack_data     <= '0;
      wr_pack_strb     <= '0;
      wr_burst_active  <= 1'b0;
      wr_burst_len     <= '0;
      wr_burst_addr    <= '0;
      wr_aw_pending    <= 1'b0;
      wr_w_pending     <= 1'b0;
      wr_buf_q         <= 1'b0;
      rd_buf_q         <= 1'b1;  // Initialize read buffer (single driver)
      wr_ready         <= 1'b1;
      wr_fill          <= 2'd0;
      frame0_written   <= 1'b0;
      frame1_written   <= 1'b0;
      buf0_base_bytes  <= FRAME0_BASE;
      buf1_base_bytes  <= FRAME1_BASE;
      buf_swapped      <= 1'b0;
      cache_flushed    <= 1'b0;
    end else begin
      wr_ready <= 1'b0;
      buf_swapped <= 1'b0;
      cache_flushed <= 1'b0;

      case (wr_state)
        WR_IDLE: begin
          wr_ready <= 1'b1;
          wr_fill <= 2'd1;  // partial when active

          if (wr_en) begin
            // Pack pixel into DDR word
            wr_pack_data[wr_pack_cnt*PIX_W +: PIX_W] <= wr_data;
            wr_pack_strb[wr_pack_cnt*(PIX_W/8) +: (PIX_W/8)] <= '1;
            wr_pack_cnt <= wr_pack_cnt + 1'b1;
            wr_addr_next <= wr_addr + 1'b1;
            wr_pixel_count <= wr_pixel_count + 1'b1;

            if (wr_pack_cnt == PIX_PER_WORD - 1) begin
              // Word full, issue burst (single beat)
              wr_burst_active <= 1'b1;
              wr_aw_pending   <= 1'b1;
              wr_w_pending    <= 1'b1;
              wr_burst_addr <= (wr_buf_q == 1'b0 ? buf0_base_bytes : buf1_base_bytes)
                              + ((wr_pixel_count / PIX_PER_WORD) * BYTES_PER_WORD);
              wr_burst_len <= 0;
              wr_state <= WR_BURST;
              wr_pack_cnt <= '0;
              wr_pack_data <= '0;
              wr_pack_strb <= '0;
            end
          end

          if (wr_frame_done) begin
            // Flush partial word if any
            if (wr_pack_cnt != 0) begin
              wr_burst_active <= 1'b1;
              wr_aw_pending   <= 1'b1;
              wr_w_pending    <= 1'b1;
              wr_burst_addr <= (wr_buf_q == 1'b0 ? buf0_base_bytes : buf1_base_bytes);
              wr_burst_len <= 0;
              wr_state <= WR_BURST;
              wr_pack_cnt <= '0;
              wr_pack_data <= '0;
              wr_pack_strb <= '0;
            end else begin
              wr_state <= WR_WAIT_BRESP;
            end
            if (wr_buf_q == 1'b0) frame0_written <= 1'b1;
            else frame1_written <= 1'b1;
            wr_fill <= 2'd2;  // full
          end
        end

        WR_BURST: begin
          if (s_axi_awready[0]) wr_aw_pending <= 1'b0;
          if (s_axi_wready[0])  wr_w_pending  <= 1'b0;
          if (!wr_aw_pending && !wr_w_pending) begin
            wr_burst_active <= 1'b0;
            if (wr_frame_done) begin
              wr_state <= WR_WAIT_BRESP;
            end else begin
              wr_state <= WR_IDLE;
            end
          end
        end
        WR_WAIT_BRESP: begin
          // Wait for write to complete (B channel)
          if (s_axi_bvalid[0]) begin
            wr_state <= WR_IDLE;
          end
        end
      endcase

      // Buffer swap (priority over cache_flush if both asserted same cycle)
      // All cache/buffer updates in this block to avoid multiple drivers
      if (swap_buf) begin
        wr_buf_q <= rd_buf_q;
        rd_buf_q <= wr_buf_q;
        swap_pending <= 1'b0;
        buf_swapped <= 1'b1;
        // Flush cache on buffer swap
        for (int i = 0; i < CACHE_LINES; i++) begin
          cache[i] <= '0;
        end
        cache_victim <= '0;
      end else if (cache_flush) begin
        for (int i = 0; i < CACHE_LINES; i++) begin
          cache[i] <= '0;
        end
        cache_victim <= '0;
        cache_flushed <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_state        <= RD_IDLE;
      rd_addr_idx     <= '0;
      rd_resp_idx     <= '0;
      rd_issued       <= '0;
      rd_completed    <= '0;
      rd_valid        <= 1'b0;
      rd_data0        <= '0;
      rd_data1        <= '0;
      rd_data2        <= '0;
      rd_data3        <= '0;
      rd_ready        <= 1'b1;
      rd_fill         <= 2'd0;
      rd_pixel_count  <= '0;
      rd_buf_q_latched <= 1'b1;
      for (int i = 0; i < 4; i++) begin
        rd_addr_q[i] <= '0;
      end
    end else begin
      rd_valid <= 1'b0;
      rd_ready <= 1'b0;

      case (rd_state)
        RD_IDLE: begin
          rd_ready <= 1'b1;
          rd_fill <= 2'd0;
          if (rd_en) begin
            rd_addr_q[0] <= rd_addr0;
            rd_addr_q[1] <= rd_addr1;
            rd_addr_q[2] <= rd_addr2;
            rd_addr_q[3] <= rd_addr3;
            rd_buf_q_latched <= rd_buf_q;  // Use internal buffer selection
            rd_addr_idx     <= '0;
            rd_issued       <= 4'b0000;
            rd_completed    <= 4'b0000;
            rd_resp_idx     <= '0;
            rd_state        <= RD_ISSUE;
            rd_pixel_count  <= rd_pixel_count + 1'b1;
            rd_fill         <= 2'd1;
          end
        end

        RD_ISSUE: begin
          rd_fill <= 2'd2;
          if (s_axi_arready[1]) begin
            rd_issued[rd_addr_idx] <= 1'b1;
            rd_addr_idx <= rd_addr_idx + 1'b1;
            if (rd_addr_idx == 2'd3) begin
              rd_state    <= RD_WAIT;
              rd_resp_idx <= '0;
            end
          end
        end

        RD_WAIT: begin
          rd_fill <= 2'd2;
          if (s_axi_rvalid[1]) begin
            // Extract pixel from the DDR word using the response ID (which equals addr index)
            logic [DDR_DATA_W-1:0] rdata_port1;
            logic [$clog2(PIX_PER_WORD)-1:0] pixel_in_word;
            logic [DDR_ID_W-1:0] rid_port1;
            logic [1:0] resp_idx;

            rdata_port1 = s_axi_rdata[2*DDR_DATA_W-1:DDR_DATA_W];
            rid_port1   = s_axi_rid[2*DDR_ID_W-1:DDR_ID_W];  // Port 1's RID
            resp_idx    = rid_port1[1:0];           // Lower 2 bits as index

            // pixel offset within the DDR word
            pixel_in_word = (rd_addr_q[resp_idx] % PIX_PER_WORD);

            case (resp_idx)
              2'd0: rd_data0 <= rdata_port1[pixel_in_word*PIX_W +: PIX_W];
              2'd1: rd_data1 <= rdata_port1[pixel_in_word*PIX_W +: PIX_W];
              2'd2: rd_data2 <= rdata_port1[pixel_in_word*PIX_W +: PIX_W];
              2'd3: rd_data3 <= rdata_port1[pixel_in_word*PIX_W +: PIX_W];
            endcase
            rd_completed[resp_idx] <= 1'b1;
            rd_resp_idx <= rd_resp_idx + 1'b1;

            // Check completion: all 4 responses received
            if (rd_completed == 4'b1111) begin
              rd_valid <= 1'b1;
              rd_state <= RD_IDLE;
            end
          end
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Store idle when both sides idle and no pending operations
  // ---------------------------------------------------------------------------
  assign store_idle = (wr_state == WR_IDLE) && (rd_state == RD_IDLE) &&
                      !wr_burst_active && (rd_issued == rd_completed);

  // Unused signals
  wire unused_ok = &{1'b0, s_axi_rid, s_axi_rresp, s_axi_rlast, s_axi_bid, s_axi_bresp, 1'b0};

endmodule
