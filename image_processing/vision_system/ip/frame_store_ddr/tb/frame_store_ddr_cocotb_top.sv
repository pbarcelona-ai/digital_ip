// ***************
// Filename: frame_store_ddr_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: Cocotb testbench top for frame_store_ddr: connects frame_store_if
//   to the DUT and exposes a simple AXI4-Lite register interface for test
//   control. Golden model: model/frame_store_ddr_model.py (clock exact).
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module frame_store_ddr_cocotb_top #(
  parameter int PIX_W        = 24,
  parameter int ADDR_W       = 20,
  parameter int FRAME_WIDTH  = 64,
  parameter int FRAME_HEIGHT = 64,
  parameter int CACHE_LINES  = 4,
  parameter int CACHE_LINE_W = 6,
  // DDR controller parameters (small for simulation)
  parameter int DDR_NPORTS   = 2,
  parameter int DDR_DATA_W   = 64,
  parameter int DDR_ADDR_W   = 16,
  parameter int DDR_ID_W     = 2,
  parameter int DDR_BANK_W   = 2,
  parameter int DDR_ROW_W    = 8,
  parameter int DDR_COL_W    = 4,
  parameter int DDR_T_RCD    = 2,
  parameter int DDR_T_RP     = 2,
  parameter int DDR_T_RAS    = 4,
  parameter int DDR_T_CL     = 2,
  parameter int DDR_T_WR     = 2,
  parameter int DDR_T_RTP    = 1,
  parameter int DDR_T_WTR    = 1,
  parameter int DDR_T_RRD    = 1,
  parameter int DDR_T_RFC    = 8,
  parameter int DDR_T_REFI   = 64,
  parameter int DDR_PRIORITY = 0,
  parameter int DDR_RQ_DEPTH = 4,
  parameter int DDR_BQ_DEPTH = 2,
  // DDR memory parameters
  parameter int DDR_MEM_WORDS = 1 << 12,
  parameter int DDR_REF_MAX   = 9 * 64
) (
  input  logic clk,
  input  logic rst_n,
  // AXI4-Lite register interface (discrete ports for cocotb)
  input  logic [7:0]  axi_awaddr,
  input  logic        axi_awvalid,
  output logic        axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0]  axi_wstrb,
  input  logic        axi_wvalid,
  output logic        axi_wready,
  output logic [1:0]  axi_bresp,
  output logic        axi_bvalid,
  input  logic        axi_bready,
  input  logic [7:0]  axi_araddr,
  input  logic        axi_arvalid,
  output logic        axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0]  axi_rresp,
  output logic        axi_rvalid,
  input  logic        axi_rready
);

  // Internal AXI4-Lite interface
  axil_if #(.ADDR_W(8), .DATA_W(32)) bus ();

  // Connect discrete ports to interface
  assign bus.awaddr   = axi_awaddr;
  assign bus.awvalid  = axi_awvalid;
  assign axi_awready  = bus.awready;
  assign bus.wdata    = axi_wdata;
  assign bus.wstrb    = axi_wstrb;
  assign bus.wvalid   = axi_wvalid;
  assign axi_wready   = bus.wready;
  assign axi_bresp    = bus.bresp;
  assign axi_bvalid   = bus.bvalid;
  assign bus.bready   = axi_bready;
  assign bus.araddr   = axi_araddr;
  assign bus.arvalid  = axi_arvalid;
  assign axi_arready  = bus.arready;
  assign axi_rdata    = bus.rdata;
  assign axi_rresp    = bus.rresp;
  assign axi_rvalid   = bus.rvalid;
  assign bus.rready   = axi_rready;

  // Frame store interface
  frame_store_if #(
    .PIX_W(PIX_W),
    .ADDR_W(ADDR_W),
    .CACHE_LINES(CACHE_LINES),
    .CACHE_LINE_W(CACHE_LINE_W)
  ) fs ();

  // DUT
  frame_store_ddr #(
    .PIX_W(PIX_W),
    .ADDR_W(ADDR_W),
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .CACHE_LINES(CACHE_LINES),
    .CACHE_LINE_W(CACHE_LINE_W),
    .DDR_NPORTS(DDR_NPORTS),
    .DDR_DATA_W(DDR_DATA_W),
    .DDR_ADDR_W(DDR_ADDR_W),
    .DDR_ID_W(DDR_ID_W),
    .DDR_BANK_W(DDR_BANK_W),
    .DDR_ROW_W(DDR_ROW_W),
    .DDR_COL_W(DDR_COL_W),
    .DDR_T_RCD(DDR_T_RCD),
    .DDR_T_RP(DDR_T_RP),
    .DDR_T_RAS(DDR_T_RAS),
    .DDR_T_CL(DDR_T_CL),
    .DDR_T_WR(DDR_T_WR),
    .DDR_T_RTP(DDR_T_RTP),
    .DDR_T_WTR(DDR_T_WTR),
    .DDR_T_RRD(DDR_T_RRD),
    .DDR_T_RFC(DDR_T_RFC),
    .DDR_T_REFI(DDR_T_REFI),
    .DDR_PRIORITY(DDR_PRIORITY),
    .DDR_RQ_DEPTH(DDR_RQ_DEPTH),
    .DDR_BQ_DEPTH(DDR_BQ_DEPTH),
    .DDR_MEM_WORDS(DDR_MEM_WORDS),
    .DDR_REF_MAX(DDR_REF_MAX)
  ) u_dut (
    .clk,
    .rst_n,
    .wr_en(fs.wr_en),
    .wr_addr(fs.wr_addr),
    .wr_data(fs.wr_data),
    .wr_buf_sel(fs.wr_buf_sel),
    .wr_frame_done(fs.wr_frame_done),
    .wr_ready(fs.wr_ready),
    .swap_buf(fs.swap_buf),
    .cache_flush(fs.cache_flush),
    .buf_swapped(fs.buf_swapped),
    .cache_flushed(fs.cache_flushed),
    .store_idle(fs.store_idle),
    .wr_fill(fs.wr_fill),
    .rd_fill(fs.rd_fill),
    .rd_en(fs.rd_en),
    .rd_addr0(fs.rd_addr0),
    .rd_addr1(fs.rd_addr1),
    .rd_addr2(fs.rd_addr2),
    .rd_addr3(fs.rd_addr3),
    .rd_buf_sel(fs.rd_buf_sel),
    .rd_ready(fs.rd_ready),
    .rd_valid(fs.rd_valid),
    .rd_data0(fs.rd_data0),
    .rd_data1(fs.rd_data1),
    .rd_data2(fs.rd_data2),
    .rd_data3(fs.rd_data3),
    // DFI interface to DDR memory (connected to ddr_mem below)
    .dfi_cmd_o(),
    .dfi_bank_o(),
    .dfi_row_o(),
    .dfi_col_o(),
    .dfi_wrdata_o(),
    .dfi_wrstrb_o()
    // .dfi_rddata_valid_i and .dfi_rddata_i are driven by u_ddr_mem
  );

  // DDR memory model
  logic ddr_err;
  logic [3:0] ddr_err_code;
  logic [15:0] ddr_err_cnt;
  ddr_mem #(
    .DATA_W(DDR_DATA_W),
    .BANK_W(DDR_BANK_W),
    .ROW_W(DDR_ROW_W),
    .COL_W(DDR_COL_W),
    .MEM_WORDS(DDR_MEM_WORDS),
    .T_RCD(DDR_T_RCD),
    .T_RP(DDR_T_RP),
    .T_RAS(DDR_T_RAS),
    .T_CL(DDR_T_CL),
    .T_WR(DDR_T_WR),
    .T_RTP(DDR_T_RTP),
    .T_WTR(DDR_T_WTR),
    .T_RRD(DDR_T_RRD),
    .T_RFC(DDR_T_RFC),
    .REF_MAX(DDR_REF_MAX)
  ) u_ddr_mem (
    .clk,
    .rst_n,
    .cmd_i(u_dut.dfi_cmd_o),
    .bank_i(u_dut.dfi_bank_o),
    .row_i(u_dut.dfi_row_o),
    .col_i(u_dut.dfi_col_o),
    .wrdata_i(u_dut.dfi_wrdata_o),
    .wrstrb_i(u_dut.dfi_wrstrb_o),
    .rddata_valid_o(u_dut.dfi_rddata_valid_i),
    .rddata_o(u_dut.dfi_rddata_i),
    .err_o(ddr_err),
    .err_code_o(ddr_err_code),
    .err_cnt_o(ddr_err_cnt)
  );

  // Simple register map for test control (not the full DDR ctrl regs)
  // Register 0: CTRL
  //   [0] soft reset
  //   [1] swap_buf pulse
  //   [2] cache_flush pulse
  // Register 1: STATUS
  //   [0] store_idle
  //   [1] wr_ready
  //   [2] rd_ready
  //   [3] buf_swapped
  //   [4] cache_flushed
  // Register 2: WR_FILL (read-only)
  // Register 3: RD_FILL (read-only)
  // Register 4..7: Reserved

  logic aw_pending;
  logic w_pending;
  logic [7:0] awaddr_q;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic [31:0] ctrl_reg;
  logic ctrl_swap_pulse;
  logic ctrl_cache_flush_pulse;
  logic bvalid_q;

  assign bus.awready = !aw_pending && !bvalid_q;
  assign bus.wready = !w_pending && !bvalid_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      w_pending <= 1'b0;
      awaddr_q <= '0;
      wdata_q <= '0;
      wstrb_q <= '0;
      ctrl_reg <= '0;
      ctrl_swap_pulse <= 1'b0;
      ctrl_cache_flush_pulse <= 1'b0;
      bvalid_q <= 1'b0;
    end else begin
      ctrl_swap_pulse <= 1'b0;
      ctrl_cache_flush_pulse <= 1'b0;

      if (bus.awvalid && bus.awready) begin
        awaddr_q <= bus.awaddr;
        aw_pending <= 1'b1;
      end
      if (bus.wvalid && bus.wready) begin
        wdata_q <= bus.wdata;
        wstrb_q <= bus.wstrb;
        w_pending <= 1'b1;
      end

      if (aw_pending && w_pending && !bvalid_q) begin
        if (awaddr_q == 8'h00) begin
          for (int lane = 0; lane < 4; lane++) begin
            if (wstrb_q[lane]) ctrl_reg[lane*8 +: 8] <= wdata_q[lane*8 +: 8];
          end
          ctrl_swap_pulse <= wstrb_q[0] && wdata_q[1];
          ctrl_cache_flush_pulse <= wstrb_q[0] && wdata_q[2];
        end
        aw_pending <= 1'b0;
        w_pending <= 1'b0;
        bvalid_q <= 1'b1;
      end else if (bvalid_q && bus.bready) begin
        bvalid_q <= 1'b0;
      end
    end
  end

  assign bus.bvalid = bvalid_q;
  assign bus.bresp = 2'b00;

  logic [7:0] araddr_q;
  logic ar_pending;
  logic [31:0] rdata_q;
  logic rvalid_q;

  assign bus.arready = !ar_pending && !rvalid_q;
  assign bus.rvalid = rvalid_q;
  assign bus.rresp = 2'b00;
  assign bus.rdata = rdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      araddr_q <= '0;
      ar_pending <= 1'b0;
      rdata_q <= '0;
      rvalid_q <= 1'b0;
    end else begin
      if (bus.arvalid && bus.arready) begin
        araddr_q <= bus.araddr;
        ar_pending <= 1'b1;
      end
      if (ar_pending && !rvalid_q) begin
        case (araddr_q)
          8'h00: rdata_q <= ctrl_reg;
          8'h04: rdata_q <= {12'd0, fs.rd_fill, fs.wr_fill, 11'd0,
                             fs.cache_flushed, fs.buf_swapped, fs.rd_ready,
                             fs.wr_ready, fs.store_idle};
          8'h08: rdata_q <= {30'd0, fs.wr_fill};
          8'h0C: rdata_q <= {30'd0, fs.rd_fill};
          default: rdata_q <= 32'd0;
        endcase
        ar_pending <= 1'b0;
        rvalid_q <= 1'b1;
      end else if (rvalid_q && bus.rready) begin
        rvalid_q <= 1'b0;
      end
    end
  end

  // Drive frame store control from register
  assign fs.swap_buf    = ctrl_swap_pulse;
  assign fs.cache_flush = ctrl_cache_flush_pulse;

  // Soft reset (not connected, but register bit exists)
  logic soft_rst_q;
  always_ff @(posedge clk) begin
    if (!rst_n) soft_rst_q <= 1'b0;
    else soft_rst_q <= ctrl_reg[0];
  end


  // Debug: expose DDR controller internal state
  logic ddr_ctrl_busy;
  logic [3:0] ddr_ctrl_owed;
  logic [7:0] ddr_ctrl_g_ref;
  logic ddr_ctrl_grant_v;
  logic ddr_ctrl_awready_0;
  logic ddr_ctrl_wready_0;
  logic ddr_ctrl_arready_1;
  logic [2:0] ddr_ctrl_dfi_cmd;
  logic [DDR_BANK_W-1:0] ddr_ctrl_dfi_bank;
  logic [DDR_ROW_W-1:0] ddr_ctrl_dfi_row;
  logic [DDR_COL_W-1:0] ddr_ctrl_dfi_col;
  logic ddr_mem_err;
  logic [3:0] ddr_mem_err_code;
  logic [15:0] ddr_mem_err_cnt;

  assign ddr_ctrl_busy        = u_dut.u_ddr_ctrl.busy;
  assign ddr_ctrl_owed        = u_dut.u_ddr_ctrl.owed;
  assign ddr_ctrl_g_ref       = u_dut.u_ddr_ctrl.g_ref;
  assign ddr_ctrl_grant_v     = u_dut.u_ddr_ctrl.grant_v;
  assign ddr_ctrl_awready_0   = u_dut.u_ddr_ctrl.s_axi_awready[0];
  assign ddr_ctrl_wready_0    = u_dut.u_ddr_ctrl.s_axi_wready[0];
  assign ddr_ctrl_arready_1   = u_dut.u_ddr_ctrl.s_axi_arready[1];
  assign ddr_ctrl_dfi_cmd     = u_dut.u_ddr_ctrl.dfi_cmd_o;
  assign ddr_ctrl_dfi_bank    = u_dut.u_ddr_ctrl.dfi_bank_o;
  assign ddr_ctrl_dfi_row     = u_dut.u_ddr_ctrl.dfi_row_o;
  assign ddr_ctrl_dfi_col     = u_dut.u_ddr_ctrl.dfi_col_o;
  assign ddr_mem_err          = u_ddr_mem.err_o;
  assign ddr_mem_err_code     = u_ddr_mem.err_code_o;
  assign ddr_mem_err_cnt      = u_ddr_mem.err_cnt_o;

endmodule
