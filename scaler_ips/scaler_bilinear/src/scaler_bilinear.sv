// ***************
// Filename: scaler_bilinear.sv
// Author: Paul Barcelona
// Description: Bilinear (2x2) image scaler IP.
//   The 16.16 source coordinate s is rounded to PB = PHASE_BITS bits:
//     s_r = s + 2^(15-PB); i = s_r >>> 16; f = s_r[15 -: PB]
//   With ONE = 2^PHASE_BITS and taps p00 p01 / p10 p11 at (i, i+1):
//     top = p00*(ONE-fx) + p01*fx
//     bot = p10*(ONE-fx) + p11*fx
//     out = (top*(ONE-fy) + bot*fy + ONE^2/2) >> (2*PHASE_BITS)
//   Weights are computed in hardware; no coefficient tables.
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame.
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_bilinear #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int PHASE_BITS = 8,        // sub-pixel phase resolution
  localparam int PIX_W   = CHANNELS * COMP_W   // bits per pixel
)(
  input  logic              clk,            // clock
  input  logic              rst_n,          // async reset, active low
  // AXI4-Lite control slave (register map in the file header)
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // AXI4-Stream video in (raster order)
  input  logic [PIX_W-1:0]  s_axis_tdata,   // pixel, component 0 in LSBs
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,  // low while generating
  input  logic              s_axis_tuser,   // start of frame
  input  logic              s_axis_tlast,   // end of line
  // AXI4-Stream video out (raster order)
  output logic [PIX_W-1:0]  m_axis_tdata,   // scaled pixel
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,  // back-pressure stalls all
  output logic              m_axis_tuser,   // start of frame
  output logic              m_axis_tlast    // end of line
);

  // Identification: IP_ID = ASCII "BLIN";
  // CAPS = {PHASE_BITS, COMP_W, CHANNELS, taps}
  localparam logic [31:0] IP_ID = 32'h424C_494E;             // "BLIN"
  localparam logic [31:0] CAPS  = {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'd2};
  localparam int          ONE   = 1 << PHASE_BITS;         // weight 1.0

  // ---------------------------------------------------------------- control
  // scaler_ctrl implements the AXI-Lite common registers, captures the
  // input frame into the frame buffer and sequences capture/generate.
  logic               fb_we;           // frame buffer write port
  logic [15:0]        fb_wx, fb_wy;
  logic [PIX_W-1:0]   fb_wdata;
  logic               gen_start, gen_done;  // frame captured / frame sent
  logic [15:0]        in_w, in_h, out_w, out_h;   // IN_SIZE / OUT_SIZE
  logic [31:0]        step_x, step_y;  // STEP_X/Y   (u16.16)
  logic signed [31:0] offs_x, offs_y;  // OFFS_X/Y   (s16.16)
  logic               ext_wr, ext_rd;  // IP register bus (>= 0x040)
  logic [ADDR_W-1:0]  ext_waddr, ext_raddr;
  logic [31:0]        ext_wdata;

  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(IP_ID), .CAPS(CAPS)) u_ctrl (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
    .fb_we, .fb_wx, .fb_wy, .fb_wdata,
    .gen_start, .gen_done,
    .cfg_in_w(in_w), .cfg_in_h(in_h), .cfg_out_w(out_w), .cfg_out_h(out_h),
    .cfg_step_x(step_x), .cfg_step_y(step_y), .cfg_offs_x(offs_x), .cfg_offs_y(offs_y),
    .ext_wr, .ext_waddr, .ext_wdata, .ext_rd, .ext_raddr, .ext_rdata(32'd0)
  );

  // ---------------------------------------------------------------- pipeline
  // Global pipeline advance: every stage moves forward unless the output
  // register holds a beat the sink has not accepted yet.
  wire adv = !m_axis_tvalid || m_axis_tready;

  // stage 0 : DDA - source coordinate (s16.16) of each output pixel
  logic               d_valid, d_sof, d_eol, d_eof, d_busy;
  logic signed [31:0] d_x, d_y;

  // DDA: raster scan of the output, source coordinate per pixel
  scaler_dda u_dda (
    .clk, .rst_n, .start(gen_start), .adv,
    .out_w, .out_h, .step_x, .step_y, .offs_x, .offs_y,
    .busy(d_busy), .o_valid(d_valid), .o_x(d_x), .o_y(d_y),
    .o_sof(d_sof), .o_eol(d_eol), .o_eof(d_eof)
  );

  // Round the source coordinate to the PHASE_BITS grid: integer part =
  // window position, top PHASE_BITS fraction bits = sub-pixel phase.
  localparam logic signed [31:0] RND = 32'sd1 <<< (16 - PHASE_BITS - 1);
  wire signed [31:0]     rx = d_x + RND;
  wire signed [31:0]     ry = d_y + RND;
  wire signed [17:0]     ix = 18'(rx >>> 16);      // left tap column
  wire signed [17:0]     iy = 18'(ry >>> 16);      // top tap row
  wire [PHASE_BITS-1:0]  fx = rx[15 -: PHASE_BITS]; // x weight of p01
  wire [PHASE_BITS-1:0]  fy = ry[15 -: PHASE_BITS]; // y weight of row 1

  // stages 1-2 : 2x2 window p00 p01 / p10 p11 from the frame buffer
  logic [4*PIX_W-1:0] win;
  banked_framebuf #(.PIX_W(PIX_W), .TAPS(2), .MAX_W(MAX_W), .MAX_H(MAX_H)) u_fb (
    .clk,
    .wr_en(fb_we), .wr_x(fb_wx), .wr_y(fb_wy), .wr_data(fb_wdata),
    .rd_adv(adv), .rd_x0(ix), .rd_y0(iy), .img_w(in_w), .img_h(in_h),
    .rd_win(win)
  );

  localparam int HW = COMP_W + PHASE_BITS + 1;   // horizontal sum width
  localparam int VW = HW + PHASE_BITS + 1;       // vertical sum width

  // Pipeline registers: [0] stage A, [1] stage B (window), [2] stage 3
  logic [2:0]            v_q;                    // valid per stage
  logic [2:0]            f_q [3];                // {eof, eol, sof}
  logic [PHASE_BITS-1:0] fx_q [2], fy_q [3];     // phases, delayed
  logic [HW-1:0]         top_q [CHANNELS], bot_q [CHANNELS];  // stage 3
  logic                  m_eof;

  // stage 3 (comb): horizontal interpolation of the top and bottom rows
  logic [HW-1:0] top_c [CHANNELS], bot_c [CHANNELS];
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [COMP_W-1:0] p00, p01, p10, p11;
      p00 = win[(0*PIX_W) + c*COMP_W +: COMP_W];
      p01 = win[(1*PIX_W) + c*COMP_W +: COMP_W];
      p10 = win[(2*PIX_W) + c*COMP_W +: COMP_W];
      p11 = win[(3*PIX_W) + c*COMP_W +: COMP_W];
      top_c[c] = HW'(p00) * HW'(ONE - fx_q[1]) + HW'(p01) * HW'(fx_q[1]);
      bot_c[c] = HW'(p10) * HW'(ONE - fx_q[1]) + HW'(p11) * HW'(fx_q[1]);
    end
  end

  // stage 4 (comb): vertical interpolation with rounding; the result is
  // always within [0, 2^COMP_W-1] because the weights are convex
  logic [PIX_W-1:0] out_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [VW-1:0] s;
      s = VW'(top_q[c]) * VW'(ONE - fy_q[2]) + VW'(bot_q[c]) * VW'(fy_q[2])
        + VW'(1) * VW'(ONE * ONE / 2);
      out_c[c*COMP_W +: COMP_W] = COMP_W'(s >> (2 * PHASE_BITS));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q           <= '0;
      for (int k = 0; k < 3; k++) f_q[k] <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= '0;
      m_axis_tuser  <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_eof         <= 1'b0;
    end else if (gen_start) begin
      v_q           <= '0;           // flush at the start of a frame
    end else if (adv) begin
      // valid/flags follow the data through stages A, B and 3; the
      // result of stage 4 is registered straight into the output
      v_q[0] <= d_valid;
      f_q[0] <= {d_eof, d_eol, d_sof};
      for (int k = 1; k < 3; k++) begin
        v_q[k] <= v_q[k-1];
        f_q[k] <= f_q[k-1];
      end
      m_axis_tvalid <= v_q[2];
      m_axis_tdata  <= out_c;
      {m_eof, m_axis_tlast, m_axis_tuser} <= f_q[2];
    end
  end

  // Data path registers (no reset needed); phases delayed to meet the
  // window, then the stage-3 partial sums
  always_ff @(posedge clk) begin
    if (adv) begin
      fx_q[0] <= fx;  fx_q[1] <= fx_q[0];
      fy_q[0] <= fy;  fy_q[1] <= fy_q[0];  fy_q[2] <= fy_q[1];
      for (int c = 0; c < CHANNELS; c++) begin
        top_q[c] <= top_c[c];
        bot_q[c] <= bot_c[c];
      end
    end
  end

  // Frame finished when the last output pixel is accepted by the sink
  assign gen_done = m_axis_tvalid && m_axis_tready && m_eof;

endmodule
