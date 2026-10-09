// ***************
// Filename: axi_lite_regs.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite slave register file. Holds all configuration
// registers (control/status, image size, radial/tangential
// coefficients, camera-calibration intrinsics, interpolation
// and distortion-model selects, homography matrix) and drives
// the two config-plane reciprocal computations coord_gen needs.
// Date: September 26, 2026
// ***************
// =============================================================================
// axi_lite_regs.sv
//
// AXI4-Lite slave. Register map (word-aligned, 32-bit):
//
//   0x00 CTRL       [0] soft_reset (self-clearing)
//   0x04 STATUS     [0] busy (RO, from top FSM)
//                   [1] frame_done (sticky, write-1-to-clear)
//                   [2] recip_busy (RO)
//   0x08 IMG_WIDTH  active frame width,  1..MAX_W
//   0x0C IMG_HEIGHT active frame height, 1..MAX_H
//   0x10 K1         signed Q16.16 radial coefficient (r^2 term)
//   0x14 K2         signed Q16.16 radial coefficient (r^4 term)
//   0x18 K3         signed Q16.16 radial coefficient (r^6 term)
//   0x1C CENTER_X   unsigned Q16.16, fraction of width  (0.5 = 0x0000_8000)
//   0x20 CENTER_Y   unsigned Q16.16, fraction of height (0.5 = 0x0000_8000)
//   0x24 SCALE      unsigned Q16.16, edge-crop zoom     (1.0 = 0x0001_0000)
//   0x28 VERSION    RO, 32'h0001_0000
//   0x2C INTERP_MODE [0] 0=bilinear (default), 1=bicubic. Must only be
//                    changed while the core is idle (not mid-frame) --
//                    see axis_out_ctrl.sv for the mode-dependent output
//                    timing this selects between.
//   0x30 CALIB_MODE [0] 0=legacy normalized center+scale (default: derive
//                    fx/fy/cx/cy from CENTER_X/CENTER_Y/SCALE/IMG_WIDTH/
//                    IMG_HEIGHT exactly as before this register existed),
//                    1=direct camera calibration (fx/fy/cx/cy taken
//                    literally, in pixels, from the FX/FY/CX/CY registers
//                    below -- standard pinhole intrinsic-matrix
//                    convention). See distortion_model_pkg.sv for the
//                    exact relationship between the two parameterizations.
//   0x34 FX         signed Q16.16 pixels -- focal length X. Used only
//                    when CALIB_MODE=1.
//   0x38 FY         signed Q16.16 pixels -- focal length Y. Used only
//                    when CALIB_MODE=1.
//   0x3C CX         signed Q16.16 pixels -- principal point X. Used only
//                    when CALIB_MODE=1.
//   0x40 CY         signed Q16.16 pixels -- principal point Y. Used only
//                    when CALIB_MODE=1.
//   0x44 P1         signed Q16.16 tangential ("plumb bob") distortion
//                    coefficient 1. Applied only when MODEL_SEL=RADIAL.
//   0x48 P2         signed Q16.16 tangential distortion coefficient 2.
//                    Applied only when MODEL_SEL=RADIAL.
//   0x4C MODEL_SEL  [2:0] which distortion model coord_gen applies --
//                    0=RADIAL (k1/k2/k3 + p1/p2, IMPLEMENTED, default),
//                    1=FISHEYE (division-model, reuses K1/K2, IMPLEMENTED),
//                    2=AFFINE (reserved ARCHITECTURE HOOK),
//                    3=PERSPECTIVE (3x3 homography, H11-H32 below, IMPLEMENTED),
//                    4=SCALING (reserved ARCHITECTURE HOOK),
//                    5=PANORAMIC (division-model, horizontal only, reuses
//                    K1, IMPLEMENTED). AFFINE/SCALING remain reserved
//                    hooks: selecting one makes coord_gen fall back to an
//                    identity mapping rather than applying any (not-yet-
//                    written) model-specific math. FISHEYE/PANORAMIC/
//                    PERSPECTIVE use a per-pixel reciprocal divide and do
//                    NOT sustain 1 pixel/clock -- see coord_gen.sv's
//                    "slow path" and README's "Interpolation modes"-style
//                    trade-off writeup for these three. See README.md
//                    "Extension hooks" for what AFFINE/SCALING would need.
//   0x50 H11        signed Q16.16. MODEL_PERSPECTIVE homography
//                    coefficient (top-left). Default 1.0 (identity row).
//   0x54 H12        signed Q16.16. Default 0.
//   0x58 H13        signed Q16.16, pixels (translation term). Default 0.
//   0x5C H21        signed Q16.16. Default 0.
//   0x60 H22        signed Q16.16. Default 1.0 (identity row).
//   0x64 H23        signed Q16.16, pixels (translation term). Default 0.
//   0x68 H31        signed Q16.16. Default 0.
//   0x6C H32        signed Q16.16. Default 0.
//                    (H33 is implicitly 1.0 -- a homography is only
//                    defined up to overall scale, so the last element is
//                    fixed rather than made a register. All 8 apply only
//                    when MODEL_SEL=PERSPECTIVE.)
//
// Writing IMG_WIDTH, IMG_HEIGHT, CENTER_X, CENTER_Y, SCALE, CALIB_MODE, FX,
// FY, CX or CY automatically (re)triggers the two reciprocal computations
// needed by coord_gen (1/fx_pix, 1/fy_pix); STATUS.recip_busy is set
// meanwhile. The core must not be started (a new frame captured) while
// recip_busy is high -- the top-level FSM enforces this.
// =============================================================================

module axi_lite_regs #(
  parameter int COORD_W = barrel_pkg::COORD_W
) (
  input  logic         clk,
  input  logic         rst_n,

  // AXI4-Lite slave
  input  logic [7:0]   s_axil_awaddr,
  input  logic         s_axil_awvalid,
  output logic         s_axil_awready,
  input  logic [31:0]  s_axil_wdata,
  input  logic [3:0]   s_axil_wstrb,
  input  logic         s_axil_wvalid,
  output logic         s_axil_wready,
  output logic [1:0]   s_axil_bresp,
  output logic         s_axil_bvalid,
  input  logic         s_axil_bready,
  input  logic [7:0]   s_axil_araddr,
  input  logic         s_axil_arvalid,
  output logic         s_axil_arready,
  output logic [31:0]  s_axil_rdata,
  output logic [1:0]   s_axil_rresp,
  output logic         s_axil_rvalid,
  input  logic         s_axil_rready,

  // status inputs from top FSM
  input  logic         top_busy,
  input  logic         top_frame_done_pulse,

  // derived configuration, out to axis_out_ctrl / coord_gen -- bundled as
  // a single struct (see distortion_model_pkg.sv)
  output distortion_model_pkg::calib_params_t cfg_out,
  output logic [COORD_W-1:0] img_width,
  output logic [COORD_W-1:0] img_height,
  output logic                cfg_recip_busy,
  output logic                interp_mode      // 0=bilinear, 1=bicubic
);

  // ---- raw registers -----------------------------------------------------
  logic [31:0] reg_img_width, reg_img_height;
  logic [31:0] reg_k1, reg_k2, reg_k3;
  logic [31:0] reg_center_x, reg_center_y, reg_scale;
  logic [31:0] reg_interp_mode;
  logic [31:0] reg_calib_mode;
  logic [31:0] reg_fx, reg_fy, reg_cx, reg_cy;
  logic [31:0] reg_p1, reg_p2;
  logic [31:0] reg_model_sel;
  logic [31:0] reg_h11, reg_h12, reg_h13;
  logic [31:0] reg_h21, reg_h22, reg_h23;
  logic [31:0] reg_h31, reg_h32;
  logic        sticky_frame_done;

  localparam logic [31:0] VERSION = 32'h0001_0000;
  localparam logic [31:0] DEFAULT_CENTER = 32'h0000_8000; // 0.5
  localparam logic [31:0] DEFAULT_SCALE  = 32'h0001_0000; // 1.0
  localparam logic [31:0] DEFAULT_FXFY   = 32'h0001_0000; // 1.0 (safe default: CALIB_MODE=0 ignores these anyway)

  // ---- AXI4-Lite write channel (simple, single-outstanding) --------------
  logic aw_hs, w_hs;
  assign s_axil_awready = !s_axil_bvalid;
  assign s_axil_wready  = !s_axil_bvalid;
  assign aw_hs = s_axil_awvalid && s_axil_awready;
  assign w_hs  = s_axil_wvalid  && s_axil_wready;

  logic geom_write_pulse; // pulses when any geometry-affecting reg is written

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axil_bvalid <= 1'b0;
      s_axil_bresp <= 2'b00;
      reg_img_width <= 32'd64;
      reg_img_height <= 32'd64;
      reg_k1 <= '0;
      reg_k2 <= '0;
      reg_k3 <= '0;
      reg_center_x <= DEFAULT_CENTER;
      reg_center_y <= DEFAULT_CENTER;
      reg_scale <= DEFAULT_SCALE;
      reg_interp_mode <= 32'h0;
      reg_calib_mode <= 32'h0;
      reg_fx <= DEFAULT_FXFY;
      reg_fy <= DEFAULT_FXFY;
      reg_cx <= '0;
      reg_cy <= '0;
      reg_p1 <= '0;
      reg_p2 <= '0;
      reg_model_sel <= 32'h0;   // MODEL_RADIAL
      reg_h11 <= 32'h0001_0000; // identity homography
      reg_h12 <= '0;
      reg_h13 <= '0;
      reg_h21 <= '0;
      reg_h22 <= 32'h0001_0000;
      reg_h23 <= '0;
      reg_h31 <= '0;
      reg_h32 <= '0;
      sticky_frame_done <= 1'b0;
      geom_write_pulse <= 1'b0;
    end else begin
      geom_write_pulse <= 1'b0;
      if (top_frame_done_pulse) sticky_frame_done <= 1'b1;

      if (aw_hs && w_hs) begin
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= 2'b00;
        unique case (s_axil_awaddr[7:2])
          6'h00: begin end // CTRL: soft_reset not persisted (self-clearing, handled combinationally elsewhere if needed)
          6'h01: begin // STATUS write-1-to-clear
            if (s_axil_wdata[1]) sticky_frame_done <= 1'b0;
          end
          6'h02: begin
            reg_img_width  <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h03: begin
            reg_img_height <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h04: reg_k1 <= s_axil_wdata;
          6'h05: reg_k2 <= s_axil_wdata;
          6'h06: reg_k3 <= s_axil_wdata;
          6'h07: begin
            reg_center_x <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h08: begin
            reg_center_y <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h09: begin
            reg_scale    <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h0B: reg_interp_mode <= s_axil_wdata;
          6'h0C: begin
            reg_calib_mode <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h0D: begin
            reg_fx    <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h0E: begin
            reg_fy    <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h0F: begin
            reg_cx    <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h10: begin
            reg_cy    <= s_axil_wdata;
            geom_write_pulse <= 1'b1;
          end
          6'h11: reg_p1 <= s_axil_wdata;
          6'h12: reg_p2 <= s_axil_wdata;
          6'h13: reg_model_sel <= s_axil_wdata;
          6'h14: reg_h11 <= s_axil_wdata;
          6'h15: reg_h12 <= s_axil_wdata;
          6'h16: reg_h13 <= s_axil_wdata;
          6'h17: reg_h21 <= s_axil_wdata;
          6'h18: reg_h22 <= s_axil_wdata;
          6'h19: reg_h23 <= s_axil_wdata;
          6'h1A: reg_h31 <= s_axil_wdata;
          6'h1B: reg_h32 <= s_axil_wdata;
          default: ;
        endcase
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
    end
  end

  // ---- AXI4-Lite read channel ---------------------------------------------
  logic ar_hs;
  assign s_axil_arready = !s_axil_rvalid;
  assign ar_hs = s_axil_arvalid && s_axil_arready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata <= '0;
      s_axil_rresp <= 2'b00;
    end else begin
      if (ar_hs) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rresp  <= 2'b00;
        unique case (s_axil_araddr[7:2])
          6'h00: s_axil_rdata <= '0;
          6'h01: s_axil_rdata <= {29'd0, cfg_recip_busy, sticky_frame_done, top_busy};
          6'h02: s_axil_rdata <= reg_img_width;
          6'h03: s_axil_rdata <= reg_img_height;
          6'h04: s_axil_rdata <= reg_k1;
          6'h05: s_axil_rdata <= reg_k2;
          6'h06: s_axil_rdata <= reg_k3;
          6'h07: s_axil_rdata <= reg_center_x;
          6'h08: s_axil_rdata <= reg_center_y;
          6'h09: s_axil_rdata <= reg_scale;
          6'h0A: s_axil_rdata <= VERSION;
          6'h0B: s_axil_rdata <= reg_interp_mode;
          6'h0C: s_axil_rdata <= reg_calib_mode;
          6'h0D: s_axil_rdata <= reg_fx;
          6'h0E: s_axil_rdata <= reg_fy;
          6'h0F: s_axil_rdata <= reg_cx;
          6'h10: s_axil_rdata <= reg_cy;
          6'h11: s_axil_rdata <= reg_p1;
          6'h12: s_axil_rdata <= reg_p2;
          6'h13: s_axil_rdata <= reg_model_sel;
          6'h14: s_axil_rdata <= reg_h11;
          6'h15: s_axil_rdata <= reg_h12;
          6'h16: s_axil_rdata <= reg_h13;
          6'h17: s_axil_rdata <= reg_h21;
          6'h18: s_axil_rdata <= reg_h22;
          6'h19: s_axil_rdata <= reg_h23;
          6'h1A: s_axil_rdata <= reg_h31;
          6'h1B: s_axil_rdata <= reg_h32;
          default: s_axil_rdata <= 32'hDEAD_BEEF;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  assign img_width  = reg_img_width[COORD_W-1:0];
  assign img_height = reg_img_height[COORD_W-1:0];
  assign interp_mode = reg_interp_mode[0];

  // ---- Derived configuration compute (runs once per geom_write_pulse) ----
  logic signed [31:0] imgw_q16, imgh_q16;
  assign imgw_q16 = $signed({reg_img_width[15:0], 16'h0000});
  assign imgh_q16 = $signed({reg_img_height[15:0], 16'h0000});

  // CALIB_MODE=0 (default, legacy): fx/fy/cx/cy DERIVED from CENTER_X/
  // CENTER_Y/SCALE/IMG_WIDTH/IMG_HEIGHT exactly as before this register
  // existed. CALIB_MODE=1: fx/fy/cx/cy taken DIRECTLY (in pixels) from
  // the FX/FY/CX/CY registers -- standard pinhole camera-calibration
  // intrinsics, bypassing the width/scale-based derivation entirely.
  logic                calib_mode;
  assign calib_mode = reg_calib_mode[0];

  logic signed [31:0] cx_pix_c, cy_pix_c, fx_pix_c, fy_pix_c;
  logic signed [31:0] cx_pix_legacy, cy_pix_legacy, fx_pix_legacy, fy_pix_legacy;

  // The legacy derivations are multiplies (cx = center_x*width, fx =
  // width*0.5*scale, ...). They used to be combinational qmul() chains
  // feeding the register load -- two chained 32x32 multiplies in one
  // cycle, the design's worst top-level path. This is the config plane
  // (runs once per geometry write, latency does not matter), so they now
  // run through free-running mulq_s pipelines from the register values,
  // and the config FSM below simply waits CFG_SETTLE_CYCLES for them to
  // settle before latching. If a register is written mid-pass, `pending`
  // triggers another full pass, so the final result always reflects the
  // final register values (same convergence argument as before).
  // Signed views of the registers (intermediate wires, not $signed() in
  // port connections: Yosys 0.33 frontend signedness bug).
  logic signed [31:0] center_x_s, center_y_s, scale_s;
  assign center_x_s = reg_center_x;
  assign center_y_s = reg_center_y;
  assign scale_s    = reg_scale;

  localparam int CFG_SETTLE_CYCLES = 10;   // >= depth of the deepest pipeline (6)

  logic signed [47:0] m_cx, m_cy, m_wh, m_hh, m_fx, m_fy;
  logic signed [31:0] w_half, h_half;
  mulq_s u_m_cx (
    .clk,
    .a(center_x_s),
    .b(imgw_q16),
    .s(m_cx)
  );
  mulq_s u_m_cy (
    .clk,
    .a(center_y_s),
    .b(imgh_q16),
    .s(m_cy)
  );
  // half extents: qmul(size, 0.5)
  mulq_s u_m_wh (
    .clk,
    .a(imgw_q16),
    .b(32'sh0000_8000),
    .s(m_wh)
  );
  mulq_s u_m_hh (
    .clk,
    .a(imgh_q16),
    .b(32'sh0000_8000),
    .s(m_hh)
  );
  // f = half_extent * scale (second multiply, after the first is saturated)
  mulq_s u_m_fx (
    .clk,
    .a(w_half),
    .b(scale_s),
    .s(m_fx)
  );
  mulq_s u_m_fy (
    .clk,
    .a(h_half),
    .b(scale_s),
    .s(m_fy)
  );
  always_ff @(posedge clk) begin
    cx_pix_legacy <= barrel_pkg::qsat48(m_cx);
    cy_pix_legacy <= barrel_pkg::qsat48(m_cy);
    w_half        <= barrel_pkg::qsat48(m_wh);
    h_half        <= barrel_pkg::qsat48(m_hh);
    fx_pix_legacy <= barrel_pkg::qsat48(m_fx);
    fy_pix_legacy <= barrel_pkg::qsat48(m_fy);
  end

  assign cx_pix_c = calib_mode ? $signed(reg_cx) : cx_pix_legacy;
  assign cy_pix_c = calib_mode ? $signed(reg_cy) : cy_pix_legacy;
  assign fx_pix_c = calib_mode ? $signed(reg_fx) : fx_pix_legacy;
  assign fy_pix_c = calib_mode ? $signed(reg_fy) : fy_pix_legacy;

  // A geom_write_pulse can arrive at any time, including while a previous
  // recompute pass is still running (e.g. several AXI-Lite writes issued
  // back-to-back: CENTER_X, CENTER_Y, SCALE, IMG_WIDTH, IMG_HEIGHT). Any
  // such pulse latches `pending`; C_IDLE only clears `pending` at the
  // instant it (re)starts a pass, and it always recomputes cx_pix_c /
  // fx_pix_c etc. from the CURRENT register values at that instant
  // -- so a burst of writes always converges to a pass computed from the
  // final, settled register values, and no write is ever silently lost.
  typedef enum logic [2:0] {C_IDLE, C_SETTLE, C_START_W, C_WAIT_W, C_START_H, C_WAIT_H_DONE} cstate_t;
  cstate_t cstate;

  logic recip_w_start, recip_h_start, recip_w_done, recip_h_done, recip_w_busy, recip_h_busy;
  logic [31:0] recip_w_result, recip_h_result;
  logic pending;
  logic [3:0] settle_cnt;

  logic signed [31:0] cx_pix_r, cy_pix_r, fx_pix_r, fy_pix_r;
  logic        [31:0] recip_fx_r, recip_fy_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cstate <= C_IDLE;
      cx_pix_r <= '0;
      cy_pix_r <= '0;
      fx_pix_r <= 32'h0001_0000;
      fy_pix_r <= 32'h0001_0000;
      recip_fx_r <= 32'h0001_0000;
      recip_fy_r <= 32'h0001_0000;
      recip_w_start <= 1'b0;
      recip_h_start <= 1'b0;
      pending <= 1'b0;
      settle_cnt <= '0;
    end else begin
      recip_w_start <= 1'b0;
      recip_h_start <= 1'b0;
      if (geom_write_pulse) pending <= 1'b1;
      unique case (cstate)
        C_IDLE: begin
          if (pending || geom_write_pulse) begin
            pending    <= 1'b0;
            settle_cnt <= '0;
            cstate     <= C_SETTLE;         // let the derivation pipelines settle
          end
        end
        C_SETTLE: begin
          if (settle_cnt == CFG_SETTLE_CYCLES - 1) begin
            cx_pix_r         <= cx_pix_c;   // settled values from CURRENT regs
            cy_pix_r         <= cy_pix_c;
            fx_pix_r         <= fx_pix_c;
            fy_pix_r         <= fy_pix_c;
            recip_w_start    <= 1'b1;
            cstate           <= C_START_W;
          end else begin
            settle_cnt <= settle_cnt + 1'b1;
          end
        end
        C_START_W: cstate <= C_WAIT_W; // allow start pulse to register
        C_WAIT_W: begin
          if (recip_w_done) begin
            recip_fx_r      <= recip_w_result;
            recip_h_start   <= 1'b1;
            cstate          <= C_START_H;
          end
        end
        C_START_H: cstate <= C_WAIT_H_DONE;
        C_WAIT_H_DONE: begin
          if (recip_h_done) begin
            recip_fy_r      <= recip_h_result;
            cstate          <= C_IDLE;
          end
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

  assign cfg_recip_busy = (cstate != C_IDLE) || pending || geom_write_pulse;

  // Intermediate unsigned wires rather than $unsigned(fx_pix_c)/
  // $unsigned(fy_pix_c) written directly as the port-connection
  // expression below -- see coord_gen.sv's identical workaround comment
  // for the Yosys 0.33 frontend assertion this avoids.
  logic [31:0] fx_pix_c_u, fy_pix_c_u;
  assign fx_pix_c_u = fx_pix_c;
  assign fy_pix_c_u = fy_pix_c;

  fixed_recip #(.W(32)) u_recip_w (
    .clk,
    .rst_n,
    .start   (recip_w_start),
    .operand (fx_pix_c_u),
    .result  (recip_w_result),
    .busy    (recip_w_busy),
    .done    (recip_w_done)
  );

  fixed_recip #(.W(32)) u_recip_h (
    .clk,
    .rst_n,
    .start   (recip_h_start),
    .operand (fy_pix_c_u),
    .result  (recip_h_result),
    .busy    (recip_h_busy),
    .done    (recip_h_done)
  );

  // ---- Bundle everything coord_gen needs into the single struct output --
  // (individual field assigns rather than a '{...} struct-literal pattern
  // -- Icarus Verilog doesn't support the latter as a continuous-assignment
  // RHS)
  assign cfg_out.cx_pix    = cx_pix_r;
  assign cfg_out.cy_pix    = cy_pix_r;
  assign cfg_out.fx_pix    = fx_pix_r;
  assign cfg_out.fy_pix    = fy_pix_r;
  assign cfg_out.recip_fx  = recip_fx_r;
  assign cfg_out.recip_fy  = recip_fy_r;
  assign cfg_out.k1        = reg_k1;
  assign cfg_out.k2        = reg_k2;
  assign cfg_out.k3        = reg_k3;
  assign cfg_out.p1        = reg_p1;
  assign cfg_out.p2        = reg_p2;
  assign cfg_out.h11       = reg_h11;
  assign cfg_out.h12       = reg_h12;
  assign cfg_out.h13       = reg_h13;
  assign cfg_out.h21       = reg_h21;
  assign cfg_out.h22       = reg_h22;
  assign cfg_out.h23       = reg_h23;
  assign cfg_out.h31       = reg_h31;
  assign cfg_out.h32       = reg_h32;
  assign cfg_out.model_sel = distortion_model_pkg::distortion_model_e'(reg_model_sel[2:0]);

endmodule
