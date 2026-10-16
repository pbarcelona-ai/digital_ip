// ***************
// Filename: vs_stream_adapter.sv
// Author: FPGA Cores 4 U
// Description: Glue between the video_pipeline insert point (a live camera
//   stream that must never stall for long) and vision_system (which captures
//   one whole frame, then generates the corrected frame, and accepts nothing
//   meanwhile). Version 1.0.0.
//     - Frame admission: a frame is forwarded only when vision_system is
//       ready (tready) and the return FIFO is empty (the previous corrected
//       frame has gone on) at the moment its SOF pixel arrives; otherwise the
//       whole frame is dropped (accepted and discarded) so the camera side
//       keeps flowing. Pixels before the first SOF are dropped too, so
//       vision_system always starts writing at a frame start.
//     - Line gaps: vision_system needs >= barrel_pkg::LINE_GAP_CYCLES idle
//       clocks between lines; GAP clocks are inserted after every forwarded
//       tlast (default 8 = LINE_GAP_CYCLES 5 + 3; a design using
//       vision_system passes barrel_pkg::LINE_GAP_CYCLES + 3).
//     - Return path: vision_system's output does not support back-pressure
//       (its bilinear datapath never stalls and it counts only accepted
//       beats, so one refused beat would hang it in T_OUTPUT). Its
//       m_axis_tready is therefore held high and the corrected frame goes
//       through a RET_FIFO-word FIFO towards the pipeline. Admission only
//       into an empty FIFO means RET_FIFO >= one frame (width x height)
//       never overflows; should it still fill, the beat is dropped and
//       counted (ret_drops_o) instead of hanging vision_system. For
//       full-size frames use an external frame buffer (axis_dma + DRAM)
//       here instead of on-chip RAM.
//   frames_o / drops_o count forwarded and dropped frames. Clock - clk.
//   Reset - synchronous rst_n (active low).
// Date: 2026-10-11
module vs_stream_adapter #(
  parameter int PIX_W = 24,
  parameter int GAP   = 8,                      // idle clocks after every forwarded line (>= 1)
  parameter int RET_FIFO = 1024                  // return FIFO words (power of two)
) (
  input  logic             clk,
  input  logic             rst_n,
  // from the insert point
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.slave s_axis,
  // to vision_system
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.master m_axis,
  // from vision_system (no back-pressure)
  // r_s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.slave r_s_axis,
  // back to the insert point
  // r_m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.master r_m_axis,
  output logic [31:0]      frames_o,
  output logic [31:0]      drops_o,
  output logic [31:0]      ret_drops_o
);
  assign m_axis.tkeep = '1;      // not used by this block
  // ---------------- return path ----------------
  logic rf_ready;
  logic [$clog2(RET_FIFO)+1:0] rf_level;
  assign r_s_axis.tready = 1'b1;
  axis_if #(.DATA_W(PIX_W)) u_ret_fifo_s ();
  assign u_ret_fifo_s.tdata = r_s_axis.tdata;
  assign u_ret_fifo_s.tlast = r_s_axis.tlast;
  assign u_ret_fifo_s.tuser = r_s_axis.tuser;
  assign u_ret_fifo_s.tvalid = r_s_axis.tvalid;
  assign rf_ready = u_ret_fifo_s.tready;
  ip_axis_fifo #(
    .DATA_W(PIX_W),
    .DEPTH(RET_FIFO)
  ) u_ret_fifo (
    .clk,
    .rst_n,
    .s(u_ret_fifo_s),
    .m(r_m_axis),
    .level_o(rf_level)
  );
  wire ret_empty = rf_level == 0 && !r_s_axis.tvalid;
  always_ff @(posedge clk) begin
    if (!rst_n) ret_drops_o <= '0;
    else if (r_s_axis.tvalid && !rf_ready) ret_drops_o <= ret_drops_o + 1'b1;
  end

  // ---------------- forward path ----------------
  typedef enum logic [1:0] {S_DROP, S_PASS, S_GAP} state_e;
  state_e st;
  logic [$clog2(GAP+1)-1:0] gap;
  wire sof  = s_axis.tvalid && s_axis.tuser;
  // A SOF decides the frame: forward it if vision_system takes it now
  wire take = sof ? (m_axis.tready && ret_empty) : (st == S_PASS);
  wire fwd  = (st != S_GAP) && take;

  assign m_axis.tdata  = s_axis.tdata;
  assign m_axis.tlast  = s_axis.tlast;
  assign m_axis.tuser  = s_axis.tuser;
  assign m_axis.tvalid = s_axis.tvalid && fwd;
  assign s_axis.tready = (st != S_GAP) && (fwd ? m_axis.tready : 1'b1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_DROP;
      gap <= '0;
      frames_o <= '0;
      drops_o <= '0;
    end else begin
      case (st)
        S_DROP, S_PASS: if (s_axis.tvalid && s_axis.tready) begin
          if (sof) begin
            if (fwd) frames_o <= frames_o + 1'b1;
            else drops_o <= drops_o + 1'b1;
          end
          if (fwd && s_axis.tlast) begin
            st <= S_GAP;
            gap <= GAP[$bits(gap)-1:0];
          end
          else if (sof && fwd) st <= S_PASS;
          else if (sof) st <= S_DROP;
        end
        S_GAP:
          if (gap == 1) st <= S_PASS;
          else gap <= gap - 1'b1;
        default: st <= S_DROP;
      endcase
    end
  end
endmodule
