// ***************
// Filename: npu.sv
// Author: FPGA Cores 4 U
// Description: INT8 neural-network accelerator (golden model:
//   model/npu_model.py, NpuTop; every operation's DDR result equals the
//   model's bit for bit, the RTL's timing is its own). Version 1.1.0.
//   - Run: CMD[0] written with CTRL.EN set and no run active (CMD is
//     ignored otherwise; held while the frame writer stores a frame), or
//     with CTRL.AUTO after every frame the frame writer has stored. The command processor reads the 64-byte layer
//     descriptors from DESC_ADDR on, starts the engine of each operation
//     (word 0 [7:0]) and goes to the next one when it is done; END (0)
//     finishes the run: IRQ_STATUS[0], RUNS + 1, STATUS.FRAME cleared. An
//     unknown operation or a parameter the model rejects stops the run with
//     IRQ_STATUS[1] (RUNS and STATUS.FRAME unchanged; the operations before
//     it have written their results, as in the model).
//   - STATUS: [0] a run active, [1] a frame written since the last run;
//     CYCLES: clocks of the last run (the RTL's own count); DET_COUNT: the
//     detections of the last NMS (0 at the start of a run); irq_o = any
//     IRQ_STATUS bit with its IRQ_EN bit.
//   - Engines: npu_elt (ADD, UPSAMPLE, COPY), npu_pool (MAXPOOL), npu_input (INPUT; the frame and
//     letterbox registers taken at the start of the run), npu_conv (CONV on a PE_P x PE_O array),
//     npu_decode (DECODE; the run's candidates counted for NMS), npu_nms (NMS: the detection list, DET_COUNT);
//     npu_fw, the frame writer (CTRL.WRITE: the frames of s_axis to FRAME_ADDR; no frame while a run is
//     active, so the buffer being read is never written). One engine at a time owns the
//     DMA (npu_dma, the AXI4 master). npu_conv's output writes are posted
//     (each done once sent, so the next starts without waiting for the B
//     response); an operation counts as done only once every posted B is
//     back, so the next one (and the CPU, after END) sees its results
//     (within CONV the reads may pass its posted writes: they read other
//     tensors).
//   Register map: src/include/npu_regs.json (npu_top.sv joins it, ID "NPU8",
//   to the regs port, npu_regs_if).
//   Parameters: ADDR_W (AXI byte address), ID_W, PE_P / PE_O (the CONV array; the results do not
//   depend on them).
//   Clock - clk (the DDR controller's). Reset - synchronous active low rst_n
//   (the controller's reset). Clock-domain crossings - none.
// Date: 2026-10-26
module npu #(
  parameter int ADDR_W = 32,                     // AXI byte address bits
  parameter int ID_W   = 4,                      // AXI ID bits
  parameter int PE_P   = 64,                     // MAC array: output pixels per strip
  parameter int PE_O   = 64                      // MAC array: output channels per tile
) (
  input  logic                clk,               // clock
  input  logic                rst_n,             // synchronous, active low
  output logic                irq_o,             // IRQ_STATUS & IRQ_EN
  output logic                run_done_o,        // one clock: a run has finished (IRQ_STATUS[0] set)
  output logic                auto_o,            // CTRL.EN, AUTO and WRITE: a run follows every frame
  // s_axis: axis_if.monitor (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.monitor             s_axis,            // the video for the frame writer (RGB888, passive)
  // AXI4 master (a ddr_ctrl port)
  output logic [ID_W-1:0]     m_axi_awid,        // write address channel
  output logic [ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]          m_axi_awlen,
  output logic [2:0]          m_axi_awsize,
  output logic [1:0]          m_axi_awburst,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  output logic [255:0]        m_axi_wdata,       // write data channel
  output logic [31:0]         m_axi_wstrb,
  output logic                m_axi_wlast,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  input  logic [ID_W-1:0]     m_axi_bid,         // write response channel
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,
  output logic [ID_W-1:0]     m_axi_arid,        // read address channel
  output logic [ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]          m_axi_arlen,
  output logic [2:0]          m_axi_arsize,
  output logic [1:0]          m_axi_arburst,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  input  logic [ID_W-1:0]     m_axi_rid,         // read data channel
  input  logic [255:0]        m_axi_rdata,
  input  logic [1:0]          m_axi_rresp,
  input  logic                m_axi_rlast,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready,
  // regs: npu_regs_if.core (src/include/npu_regs_if.sv)
  npu_regs_if.core            regs
);
  localparam int NE = 8;                         // DMA clients
  localparam int E_CMD = 0, E_ELT = 1, E_POOL = 2, E_INP = 3, E_CONV = 4, E_DEC = 5, E_NMS = 6, E_FW = 7;
  localparam int SW = $clog2(NE);
  localparam logic [7:0] OP_END = 8'd0, OP_CONV = 8'd1, OP_POOL = 8'd2, OP_ADD = 8'd3, OP_UP = 8'd4, OP_COPY = 8'd5, OP_INPUT = 8'd6, OP_DECODE = 8'd7, OP_NMS = 8'd8;

  // ---------------- the DMA and its clients: one npu_dma_if per client, the owner (sel) drives the DMA
  npu_dma_if dc ();                              // the command processor's (descriptor reads)
  npu_dma_if de ();                              // npu_elt's
  npu_dma_if dp ();                              // npu_pool's
  npu_dma_if di ();                              // npu_input's
  npu_dma_if dv ();                              // npu_conv's
  npu_dma_if dd ();                              // npu_decode's
  npu_dma_if dn ();                              // npu_nms's
  npu_dma_if df ();                              // npu_fw's
  logic [SW-1:0] sel;                            // the client owning the DMA
  logic         d_rd_ready, d_rd_valid, d_rd_last, d_wr_ready, d_wr_rdy, d_wr_done, d_wr_idle;
  logic [255:0] d_rd_data;
  logic [5:0]   d_rd_cnt;
  logic [NE-1:0] c_rd_req, c_rd_rdy, c_wr_req, c_wr_valid;
  logic [31:0]  c_rd_addr [NE], c_rd_len [NE], c_wr_addr [NE], c_wr_len [NE];
  logic [255:0] c_wr_data [NE];
  logic [5:0]   c_wr_cnt [NE];
  // a client's requests into the arrays; the responses to it (handshakes only while it owns the DMA)
`define NPU_DMA_CLIENT(IF, E) \
  assign c_rd_req[E] = IF.rd_req; \
  assign c_rd_addr[E] = IF.rd_addr; \
  assign c_rd_len[E] = IF.rd_len; \
  assign c_rd_rdy[E] = IF.rd_rdy; \
  assign c_wr_req[E] = IF.wr_req; \
  assign c_wr_addr[E] = IF.wr_addr; \
  assign c_wr_len[E] = IF.wr_len; \
  assign c_wr_valid[E] = IF.wr_valid; \
  assign c_wr_data[E] = IF.wr_data; \
  assign c_wr_cnt[E] = IF.wr_cnt; \
  assign IF.rd_ready = d_rd_ready && sel == SW'(E); \
  assign IF.rd_valid = d_rd_valid && sel == SW'(E); \
  assign IF.rd_data = d_rd_data; \
  assign IF.rd_cnt = d_rd_cnt; \
  assign IF.rd_last = d_rd_last; \
  assign IF.wr_ready = d_wr_ready && sel == SW'(E); \
  assign IF.wr_rdy = d_wr_rdy && sel == SW'(E); \
  assign IF.wr_done = d_wr_done && sel == SW'(E);
  `NPU_DMA_CLIENT(dc, E_CMD)
  `NPU_DMA_CLIENT(de, E_ELT)
  `NPU_DMA_CLIENT(dp, E_POOL)
  `NPU_DMA_CLIENT(di, E_INP)
  `NPU_DMA_CLIENT(dv, E_CONV)
  `NPU_DMA_CLIENT(dd, E_DEC)
  `NPU_DMA_CLIENT(dn, E_NMS)
  `NPU_DMA_CLIENT(df, E_FW)
`undef NPU_DMA_CLIENT
  npu_dma #(
    .ADDR_W(ADDR_W),
    .ID_W(ID_W)
  ) u_dma (
    .clk,
    .rst_n,
    .rd_req_i(c_rd_req[sel]),
    .rd_ready_o(d_rd_ready),
    .rd_addr_i(ADDR_W'(c_rd_addr[sel])),
    .rd_len_i(c_rd_len[sel]),
    .rd_valid_o(d_rd_valid),
    .rd_rdy_i(c_rd_rdy[sel]),
    .rd_data_o(d_rd_data),
    .rd_cnt_o(d_rd_cnt),
    .rd_last_o(d_rd_last),
    .wr_req_i(c_wr_req[sel]),
    .wr_post_i(sel == SW'(E_CONV)),              // CONV's per-channel strip writes are posted
    .wr_ready_o(d_wr_ready),
    .wr_addr_i(ADDR_W'(c_wr_addr[sel])),
    .wr_len_i(c_wr_len[sel]),
    .wr_valid_i(c_wr_valid[sel]),
    .wr_rdy_o(d_wr_rdy),
    .wr_data_i(c_wr_data[sel]),
    .wr_cnt_i(c_wr_cnt[sel]),
    .wr_done_o(d_wr_done),
    .wr_idle_o(d_wr_idle),
    .m_axi_awid,
    .m_axi_awaddr,
    .m_axi_awlen,
    .m_axi_awsize,
    .m_axi_awburst,
    .m_axi_awvalid,
    .m_axi_awready,
    .m_axi_wdata,
    .m_axi_wstrb,
    .m_axi_wlast,
    .m_axi_wvalid,
    .m_axi_wready,
    .m_axi_bid,
    .m_axi_bresp,
    .m_axi_bvalid,
    .m_axi_bready,
    .m_axi_arid,
    .m_axi_araddr,
    .m_axi_arlen,
    .m_axi_arsize,
    .m_axi_arburst,
    .m_axi_arvalid,
    .m_axi_arready,
    .m_axi_rid,
    .m_axi_rdata,
    .m_axi_rresp,
    .m_axi_rlast,
    .m_axi_rvalid,
    .m_axi_rready
  );

  // ---------------- engines
  logic         elt_start, elt_done, elt_err, pool_start, pool_done, pool_err;
  logic [511:0] desc;                            // the current descriptor
  wire  [7:0]   op = desc[7:0];
  npu_elt u_elt (
    .clk,
    .rst_n,
    .start_i(elt_start),
    .op_i(op),
    .d_i(desc),
    .done_o(elt_done),
    .err_o(elt_err),
    .dma(de)
  );
  // the frame and letterbox registers of the run (taken at its start, as the model)
  logic [271:0] geom;
  logic         inp_start, inp_done, inp_err;
  npu_input u_inp (
    .clk,
    .rst_n,
    .start_i(inp_start),
    .d_i(desc),
    .geom_i(geom),
    .done_o(inp_done),
    .err_o(inp_err),
    .dma(di)
  );
  logic         conv_start, conv_done, conv_err;
  npu_conv #(
    .PE_P(PE_P),
    .PE_O(PE_O)
  ) u_conv (
    .clk,
    .rst_n,
    .start_i(conv_start),
    .d_i(desc),
    .done_o(conv_done),
    .err_o(conv_err),
    .dma(dv)
  );
  logic         dec_start, dec_done, dec_err, dec_cand;
  logic [63:0]  inv;                             // LB_INV, LB2_INV of the run
  logic [11:0]  ncand;                           // DECODE candidates of the run
  npu_decode u_dec (
    .clk,
    .rst_n,
    .start_i(dec_start),
    .d_i(desc),
    .geom_i(geom),
    .inv_i(inv),
    .ncand_i(ncand),
    .cand_o(dec_cand),
    .done_o(dec_done),
    .err_o(dec_err),
    .dma(dd)
  );
  logic         nms_start, nms_done, nms_err;
  logic [15:0]  nms_det, det_count, det_max;
  logic [31:0]  det_addr;                        // DET_ADDR / DET_MAX of the run
  npu_nms u_nms (
    .clk,
    .rst_n,
    .start_i(nms_start),
    .d_i(desc),
    .ncand_i(ncand),
    .det_addr_i(det_addr),
    .det_max_i(det_max),
    .done_o(nms_done),
    .err_o(nms_err),
    .det_o(nms_det),
    .dma(dn)
  );
  // command processor state (declared here: the frame writer's busy_i uses it)
  typedef enum logic [2:0] {C_IDLE, C_FETCH, C_RUN, C_NEXT} cstate_e;
  cstate_e      cst;
  logic         cmd_pend, auto_pend;
  logic         fw_active, fw_frame, fw_written;
  npu_fw u_fw (
    .clk,
    .rst_n,
    .s_axis,
    .en_i(regs.cfg_ctrl[0] && regs.cfg_ctrl[2]),
    .busy_i(cst != C_IDLE || cmd_pend || auto_pend),
    .addr_i(regs.cfg_frame_addr),
    .stride_i(regs.cfg_frame_stride),
    .height_i(regs.cfg_frame_size[31:16]),
    .active_o(fw_active),
    .frame_o(fw_frame),
    .written_o(fw_written),
    .dma(df)
  );
  npu_pool u_pool (
    .clk,
    .rst_n,
    .start_i(pool_start),
    .d_i(desc),
    .done_o(pool_done),
    .err_o(pool_err),
    .dma(dp)
  );

  // ---------------- command processor
  logic [31:0]  daddr;                           // the current descriptor's address
  logic         rq;                              // the descriptor read presented
  logic         half;                            // the descriptor's second 32 bytes
  logic [31:0]  cycles, cyc_last, runs;
  logic         frame_q;                         // STATUS.FRAME
  logic [1:0]   irq_set;
  logic         e_fin, e_bad;                    // the engine is done (with an error); waiting for posted B's
  // a run starts on CMD (held while the frame writer stores a frame) or, with AUTO, after a frame
  // (a request waits for the frame being stored; the frame writer takes no new frame while one waits)
  wire          start = (cmd_pend || auto_pend) && regs.cfg_ctrl[0] && cst == C_IDLE && !fw_active;
  wire          eng_done = elt_done || pool_done || inp_done || conv_done || dec_done || nms_done;
  wire          eng_err = elt_err || pool_err || inp_err || conv_err || dec_err || nms_err;
  assign dc.rd_req = rq;
  assign dc.rd_addr = daddr;
  assign dc.rd_len = 32'd64;
  assign dc.rd_rdy = 1'b1;
  assign dc.wr_req = 1'b0;
  assign dc.wr_addr = '0;
  assign dc.wr_len = 32'd1;
  assign dc.wr_valid = 1'b0;
  assign dc.wr_data = '0;
  assign dc.wr_cnt = 6'd32;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cst <= C_IDLE;
      daddr <= '0;
      rq <= 1'b0;
      half <= 1'b0;
      desc <= '0;
      sel <= SW'(E_CMD);
      elt_start <= 1'b0;
      pool_start <= 1'b0;
      inp_start <= 1'b0;
      conv_start <= 1'b0;
      dec_start <= 1'b0;
      nms_start <= 1'b0;
      det_count <= '0;
      det_addr <= '0;
      det_max <= '0;
      inv <= '0;
      ncand <= '0;
      geom <= '0;
      cycles <= '0;
      cyc_last <= '0;
      runs <= '0;
      frame_q <= 1'b0;
      cmd_pend <= 1'b0;
      auto_pend <= 1'b0;
      irq_set <= '0;
      e_fin <= 1'b0;
      e_bad <= 1'b0;
    end else begin
      if (regs.cfg_cmd_wr && regs.cfg_cmd && regs.cfg_ctrl[0] && cst == C_IDLE) cmd_pend <= 1'b1;
      if (fw_frame && regs.cfg_ctrl[0] && regs.cfg_ctrl[1]) auto_pend <= 1'b1;
      if (start) begin
        cmd_pend <= 1'b0;
        auto_pend <= 1'b0;
      end
      if (fw_written) frame_q <= 1'b1;
      elt_start <= 1'b0;
      pool_start <= 1'b0;
      inp_start <= 1'b0;
      conv_start <= 1'b0;
      dec_start <= 1'b0;
      nms_start <= 1'b0;
      if (nms_done) det_count <= nms_det;
      if (dec_cand) ncand <= ncand + 12'd1;
      irq_set <= '0;
      if (rq && dc.rd_ready) rq <= 1'b0;
      if (cst != C_IDLE) cycles <= cycles + 32'd1;
      unique case (cst)
        C_IDLE: if (!start) begin
          sel <= SW'(E_FW);                      // the frame writer owns the DMA between runs
        end else begin
          daddr <= regs.cfg_desc_addr;
          geom <= {regs.cfg_lb2_size, regs.cfg_lb2_offset, regs.cfg_lb2_step, regs.cfg_lb_size, regs.cfg_lb_offset,
                   regs.cfg_lb_step, regs.cfg_frame_size, regs.cfg_frame_stride, regs.cfg_frame_addr};
          inv <= {regs.cfg_lb2_inv, regs.cfg_lb_inv};
          ncand <= '0;
          det_count <= '0;
          det_addr <= regs.cfg_det_addr;
          det_max <= regs.cfg_det_max;
          cycles <= 32'd1;
          sel <= SW'(E_CMD);
          rq <= 1'b1;
          half <= 1'b0;
          cst <= C_FETCH;
        end
        C_FETCH: if (dc.rd_valid) begin
          desc[256*half +: 256] <= dc.rd_data;
          half <= 1'b1;
          if (dc.rd_last) begin
            cst <= C_RUN;
          end
        end
        C_RUN: begin                             // dispatch the descriptor just read
          unique case (op)
            OP_END: begin
              cyc_last <= cycles;
              runs <= runs + 32'd1;
              frame_q <= fw_written;             // a frame written in this clock stays
              irq_set <= 2'b01;
              cst <= C_IDLE;
            end
            OP_NMS: begin
              sel <= SW'(E_NMS);
              nms_start <= 1'b1;
              cst <= C_NEXT;
            end
            OP_DECODE: begin
              sel <= SW'(E_DEC);
              dec_start <= 1'b1;
              cst <= C_NEXT;
            end
            OP_CONV: begin
              sel <= SW'(E_CONV);
              conv_start <= 1'b1;
              cst <= C_NEXT;
            end
            OP_INPUT: begin
              sel <= SW'(E_INP);
              inp_start <= 1'b1;
              cst <= C_NEXT;
            end
            OP_POOL: begin
              sel <= SW'(E_POOL);
              pool_start <= 1'b1;
              cst <= C_NEXT;
            end
            OP_ADD, OP_UP, OP_COPY: begin
              sel <= SW'(E_ELT);
              elt_start <= 1'b1;
              cst <= C_NEXT;
            end
            default: begin                       // an unknown operation: the run stops with the error flag
              cyc_last <= cycles;
              irq_set <= 2'b10;
              cst <= C_IDLE;
            end
          endcase
        end
        C_NEXT: begin
          if (eng_done) begin
            e_fin <= 1'b1;
            e_bad <= eng_err;
          end
          if (e_fin && d_wr_idle) begin            // the engine done and its posted writes in memory
            e_fin <= 1'b0;
            if (e_bad) begin
              cyc_last <= cycles;
              irq_set <= 2'b10;
              sel <= SW'(E_CMD);
              cst <= C_IDLE;
            end else begin
              daddr <= daddr + 32'd64;
              sel <= SW'(E_CMD);
              rq <= 1'b1;
              half <= 1'b0;
              cst <= C_FETCH;
            end
          end
        end
        default: cst <= C_IDLE;
      endcase
    end
  end
  assign regs.sts_status = {frame_q, cst != C_IDLE};
  assign regs.sts_irq_status_set = irq_set;
  assign regs.sts_det_count = det_count;
  assign regs.sts_cycles = cyc_last;
  assign regs.sts_runs = runs;
  assign irq_o = |(regs.cfg_irq_status & regs.cfg_irq_en);
  assign run_done_o = irq_set[0];
  assign auto_o = regs.cfg_ctrl[0] && regs.cfg_ctrl[1] && regs.cfg_ctrl[2];
  // not used here: the write pulses of the configuration registers (each value is taken when needed: at the
  // run's start or by the frame writer), the command processor's write side and read count
  wire unused_regs = &{1'b0, regs.cfg_ctrl_wr, regs.cfg_irq_en_wr, regs.cfg_irq_status_wr, regs.cfg_desc_addr_wr,
                       regs.cfg_det_addr_wr, regs.cfg_det_max_wr, regs.cfg_frame_addr_wr, regs.cfg_frame_stride_wr,
                       regs.cfg_frame_size_wr, regs.cfg_lb_step_wr, regs.cfg_lb_offset_wr, regs.cfg_lb_size_wr,
                       regs.cfg_lb_inv_wr, regs.cfg_lb2_step_wr, regs.cfg_lb2_offset_wr, regs.cfg_lb2_size_wr,
                       regs.cfg_lb2_inv_wr, dc.wr_ready, dc.wr_rdy, dc.wr_done, dc.rd_cnt, 1'b0};
endmodule
