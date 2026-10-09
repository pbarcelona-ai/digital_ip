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
//       tlast.
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
// Date: 2026-10-02
module vs_stream_adapter #(
  parameter int PIX_W = 24,
  parameter int GAP   = barrel_pkg::LINE_GAP_CYCLES + 3,
  parameter int RET_FIFO = 1024                  // return FIFO words (power of two)
) (
  input  logic             clk,
  input  logic             rst_n,
  // from the insert point
  input  logic [PIX_W-1:0] s_axis_tdata,
  input  logic             s_axis_tlast,
  input  logic             s_axis_tuser,
  input  logic             s_axis_tvalid,
  output logic             s_axis_tready,
  // to vision_system
  output logic [PIX_W-1:0] m_axis_tdata,
  output logic             m_axis_tlast,
  output logic             m_axis_tuser,
  output logic             m_axis_tvalid,
  input  logic             m_axis_tready,
  // from vision_system (no back-pressure)
  input  logic [PIX_W-1:0] r_s_axis_tdata,
  input  logic             r_s_axis_tlast,
  input  logic             r_s_axis_tuser,
  input  logic             r_s_axis_tvalid,
  output logic             r_s_axis_tready,      // always 1
  // back to the insert point
  output logic [PIX_W-1:0] r_m_axis_tdata,
  output logic             r_m_axis_tlast,
  output logic             r_m_axis_tuser,
  output logic             r_m_axis_tvalid,
  input  logic             r_m_axis_tready,
  output logic [31:0]      frames_o,
  output logic [31:0]      drops_o,
  output logic [31:0]      ret_drops_o
);
  // ---------------- return path ----------------
  logic rf_ready;
  logic [$clog2(RET_FIFO)+1:0] rf_level;
  assign r_s_axis_tready = 1'b1;
  ip_axis_fifo #(.DATA_W(PIX_W), .DEPTH(RET_FIFO)) u_ret_fifo (
    .clk,
    .rst_n,
    .s_tdata(r_s_axis_tdata),
    .s_tlast(r_s_axis_tlast),
    .s_tuser(r_s_axis_tuser),
    .s_tvalid(r_s_axis_tvalid),
    .s_tready(rf_ready),
    .m_tdata(r_m_axis_tdata),
    .m_tlast(r_m_axis_tlast),
    .m_tuser(r_m_axis_tuser),
    .m_tvalid(r_m_axis_tvalid),
    .m_tready(r_m_axis_tready),
    .level_o(rf_level)
  );
  wire ret_empty = rf_level == 0 && !r_s_axis_tvalid;
  always_ff @(posedge clk) begin
    if (!rst_n) ret_drops_o <= '0;
    else if (r_s_axis_tvalid && !rf_ready) ret_drops_o <= ret_drops_o + 1'b1;
  end

  // ---------------- forward path ----------------
  typedef enum logic [1:0] {S_DROP, S_PASS, S_GAP} state_e;
  state_e st;
  logic [$clog2(GAP+1)-1:0] gap;
  wire sof  = s_axis_tvalid && s_axis_tuser;
  // A SOF decides the frame: forward it if vision_system takes it now
  wire take = sof ? (m_axis_tready && ret_empty) : (st == S_PASS);
  wire fwd  = (st != S_GAP) && take;

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tuser  = s_axis_tuser;
  assign m_axis_tvalid = s_axis_tvalid && fwd;
  assign s_axis_tready = (st != S_GAP) && (fwd ? m_axis_tready : 1'b1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_DROP;
      gap <= '0;
      frames_o <= '0;
      drops_o <= '0;
    end else begin
      case (st)
        S_DROP, S_PASS: if (s_axis_tvalid && s_axis_tready) begin
          if (sof) begin
            if (fwd) frames_o <= frames_o + 1'b1;
            else drops_o <= drops_o + 1'b1;
          end
          if (fwd && s_axis_tlast) begin
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
