// ***************
// Filename: quad_dec.sv
// Author: FPGA Cores 4 U
// Description: Quadrature encoder decoder IP. A/B/index inputs pass two
//   flop synchronizers and a programmable stability filter, then a x4
//   decoder updates a 32 bit signed position counter, direction flag and
//   illegal transition (error) counter. Index pulse latches and optionally
//   clears the position. A window timer measures counts per window
//   (velocity) and emits each sample on an AXI-Stream master. Registers on the
//   cfg_* / sts_* ports; quad_dec_top.sv is the block with its AXI4-Lite
//   register map (src/include/quad_dec_regs.sv: ID "QDEC" / VERSION / DATE
//   at 0x00-0x08, 0x10 CTRL [0]en [1]clear pos (pulse) [2]index clears pos
//   [3]swap A/B [15:8]filter clocks, 0x14 POSITION, 0x18 VELOCITY, 0x1C
//   WINDOW clocks, 0x20 STATUS [0]dir [1]error [2]index seen (W1C), 0x24
//   ERR_COUNT, 0x28 INDEX_POS). Clock - single clock aclk, every input is
//   synchronous to it unless a two-flop synchronizer is mentioned. Reset -
//   synchronous active low aresetn, registers take the documented reset
//   values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-10-12
module quad_dec (
  input  logic        aclk,
  input  logic        aresetn,
  input  logic        enc_a_i,
  input  logic        enc_b_i,
  input  logic        enc_z_i,
  // Velocity samples (signed counts per window)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // register ports
  input  logic [15:0] cfg_ctrl,          // CTRL
  input  logic        cfg_ctrl_wr,       // CTRL write pulse (CLR_POS)
  input  logic [31:0] cfg_position,      // POSITION: data written ...
  input  logic        cfg_position_wr,   // ... and its write pulse (load)
  output logic [31:0] sts_position,      // POSITION: value read
  output logic [31:0] sts_velocity,      // VELOCITY
  input  logic [31:0] cfg_window,        // WINDOW
  input  logic [2:0]  cfg_status,        // STATUS: data written ...
  input  logic        cfg_status_wr,     // ... and its write pulse
  output logic [2:0]  sts_status,        // STATUS: value read
  output logic [31:0] sts_err_count,     // ERR_COUNT
  output logic [31:0] sts_index_pos      // INDEX_POS
);
  logic win_load;                // window boundary pulse
  wire en = cfg_ctrl[0];
  wire [7:0] filt = cfg_ctrl[15:8];

  // ---- Synchronize and filter the three inputs ----
  (* async_reg = "true" *) logic [2:0] s1, s2;
  logic [2:0] fil;               // filtered value
  logic [23:0] fcnt;             // 3 x 8 bit stability counters
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s1 <= '0;
      s2 <= '0;
      fil <= '0;
      fcnt <= '0;
    end
    else begin
      s1 <= {enc_z_i, enc_b_i, enc_a_i};
      s2 <= s1;
      for (int i = 0; i < 3; i++) begin
        if (s2[i] == fil[i]) fcnt[i*8 +: 8] <= '0;
        else if (fcnt[i*8 +: 8] >= filt) begin
          fil[i] <= s2[i];
          fcnt[i*8 +: 8] <= '0;
        end
        else fcnt[i*8 +: 8] <= fcnt[i*8 +: 8] + 8'd1;
      end
    end
  end

  wire a = cfg_ctrl[3] ? fil[1] : fil[0];
  wire b = cfg_ctrl[3] ? fil[0] : fil[1];
  logic [1:0] ab_prev;
  logic z_prev;

  // ---- x4 decode: forward sequence 00 -> 10 -> 11 -> 01 -> 00 ----
  logic signed [31:0] pos, idx_pos, win_cnt;
  logic dir, err_f, idx_f;
  logic [31:0] err_cnt;
  logic step_up, step_dn, step_err;
  wire [3:0] tr = {ab_prev, a, b};
  always_comb begin
    step_up = 1'b0;
    step_dn = 1'b0;
    step_err = 1'b0;
    case (tr)
      4'b0010, 4'b1011, 4'b1101, 4'b0100: step_up = 1'b1;
      4'b0001, 4'b0111, 4'b1110, 4'b1000: step_dn = 1'b1;
      4'b0011, 4'b1100, 4'b0110, 4'b1001: step_err = 1'b1;   // two bits changed
      default: ;
    endcase
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      pos <= '0;
      idx_pos <= '0;
      ab_prev <= '0;
      z_prev <= 1'b0;
      dir <= 1'b0;
      err_f <= 1'b0;
      idx_f <= 1'b0;
      err_cnt <= '0;
      win_cnt <= '0;
    end else begin
      ab_prev <= {a, b};
      z_prev <= fil[2];
      if (en) begin
        if (step_up) begin
          pos <= pos + 32'sd1;
          win_cnt <= win_cnt + 32'sd1;
          dir <= 1'b1;
        end
        if (step_dn) begin
          pos <= pos - 32'sd1;
          win_cnt <= win_cnt - 32'sd1;
          dir <= 1'b0;
        end
        if (step_err) begin
          err_f <= 1'b1;
          err_cnt <= err_cnt + 32'd1;
        end
        if (fil[2] & ~z_prev) begin                        // index rising edge
          idx_pos <= pos;
          idx_f <= 1'b1;
          if (cfg_ctrl[2]) pos <= '0;
        end
      end
      if (cfg_ctrl_wr & cfg_ctrl[1]) pos <= '0;
      if (cfg_position_wr) pos <= $signed(cfg_position);    // load position
      if (cfg_status_wr) begin
        if (cfg_status[1]) err_f <= 1'b0;
        if (cfg_status[2]) idx_f <= 1'b0;
      end
      if (win_load) win_cnt <= '0;
    end
  end

  // ---- Velocity window ----
  logic [31:0] wtmr;
  logic signed [31:0] vel;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wtmr <= '0;
      win_load <= 1'b0;
      vel <= '0;
      m_axis_tvalid <= 1'b0;
    end
    else begin
      win_load <= 1'b0;
      if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;
      if (en) begin
        if (wtmr >= cfg_window) begin
          wtmr <= '0;
          win_load <= 1'b1;
          vel <= win_cnt;
          m_axis_tvalid <= 1'b1;                            // drops if not consumed
        end else wtmr <= wtmr + 32'd1;
      end
    end
  end
  assign m_axis_tdata = vel;
  assign m_axis_tlast = 1'b1;

  assign sts_position = pos;
  assign sts_velocity = vel;
  assign sts_status = {idx_f, err_f, dir};
  assign sts_err_count = err_cnt;
  assign sts_index_pos = idx_pos;
endmodule
