// ***************
// Filename: vs_stream_adapter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for vs_stream_adapter (GAP = 6,
//   RET_FIFO = 64, 8 x 6 frames). A camera driver sends labelled frames on
//   s_axis; a behavioural vision_system model takes one whole frame on
//   m_axis (ready while idle and capturing), stays busy for a while, then
//   returns it on r_s_axis without looking at tready (as vision_system
//   does); the return side r_m_axis has random back-pressure. Checks:
//   reset state, pixels before the first frame start dropped, frames
//   forwarded whole and unchanged, at least GAP idle clocks after every
//   forwarded line, frames dropped while vision_system is busy or the
//   return FIFO is not empty (and the camera never held up while
//   dropping), the return path intact under back-pressure, and a return
//   FIFO overflow counted in ret_drops_o without stalling vision_system.
//   Prints TEST PASSED on success; +vcd dumps vs_stream_adapter_tb.vcd. The
//   test tasks are in tests/vs_stream_adapter_tests.sv (`included).
// Date: 2026-10-11
`timescale 1ns/1ps
module vs_stream_adapter_tb;
  localparam int GAP = 6, RET_FIFO = 64, W = 8, H = 6, NPIX = W * H, MAXF = 64;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  axis_if #(.DATA_W(24), .USER_W(1)) rm ();
  axis_if #(.DATA_W(24), .USER_W(1)) rs ();
  axis_if #(.DATA_W(24), .USER_W(1)) m ();
  axis_if #(.DATA_W(24), .USER_W(1)) s ();
  logic [31:0] frames_o, drops_o, ret_drops_o;

  vs_stream_adapter #(
    .PIX_W(24),
    .GAP(GAP),
    .RET_FIFO(RET_FIFO)
  ) dut (
    .clk,
    .rst_n,
    .s_axis(s),
    .m_axis(m),
    .r_s_axis(rs),
    .r_m_axis(rm),
    .frames_o,
    .drops_o,
    .ret_drops_o
  );

  // ---------------- vision_system model: capture a frame, stay busy, return it (no back-pressure)
  int busy_clks = 40;                                // clocks between the end of capture and the output
  int vs_frames = 0;                                 // frames captured
  logic [23:0] cap [NPIX];
  int cap_n = 0;
  bit vs_hold = 0;                                   // test hook: not ready (another frame in progress)
  typedef enum {V_IDLE, V_CAP, V_BUSY, V_OUT} vstate_e;
  vstate_e vst = V_IDLE;
  int vcnt = 0;
  int ov_left = 0, ov_i = 0;                         // test_ret_overflow: extra beats the model emits
  assign m.tready = (vst == V_IDLE || vst == V_CAP) && !vs_hold;
  always @(posedge clk) begin
    if (!rst_n) begin
      vst <= V_IDLE;
      rs.tvalid <= 0;
      cap_n = 0;
    end else begin
      case (vst)
        V_IDLE, V_CAP: if (m.tvalid && m.tready) begin
          if (vst == V_IDLE && !m.tuser) begin
            errors++;
            $display("ERROR @%0t: vision_system model: first pixel without tuser", $time);
          end
          if (cap_n < NPIX) cap[cap_n] = m.tdata;
          cap_n++;
          vst <= V_CAP;
          if (cap_n == NPIX) begin
            vs_frames++;
            vst <= V_BUSY;
            vcnt = busy_clks;
          end
        end
        V_BUSY: if (vcnt == 0) begin
          vst <= V_OUT;
          vcnt = 0;
        end else vcnt--;
        V_OUT: begin
          rs.tvalid <= 1;
          rs.tdata <= cap[vcnt];
          rs.tuser <= vcnt == 0;
          rs.tlast <= vcnt % W == W - 1;
          if (!rs.tready) begin
            errors++;
            $display("ERROR @%0t: r_s_axis_tready low (vision_system cannot wait)", $time);
          end
          vcnt++;
          if (vcnt == NPIX) begin
            vst <= V_IDLE;
            cap_n = 0;
          end
        end
      endcase
      if (vst != V_OUT) rs.tvalid <= 0;
      if (ov_left > 0) begin
        rs.tvalid <= 1;
        rs.tdata <= 24'hF00000 + ov_i;
        rs.tuser <= ov_i == 0;
        rs.tlast <= 0;
        if (!rs.tready) begin
          errors++;
          $display("ERROR @%0t: r_s_axis_tready low during the overflow", $time);
        end
        ov_i++;
        ov_left--;
      end
    end
  end

  // ---------------- line gaps on m_axis: idle clocks after every forwarded tlast
  int idle = 1000, min_gap = 1000;
  bit after_last = 0;
  always @(posedge clk) if (rst_n) begin
    if (m.tvalid && m.tready) begin
      if (after_last && idle < min_gap) min_gap = idle;
      after_last = m.tlast;
      idle = 0;
    end else idle++;
  end

  // ---------------- return side: random back-pressure, frames collected
  int rbp_pct = 0;
  logic [23:0] ret [MAXF * NPIX];
  int ret_n = 0;
  always @(posedge clk) begin
    if (rm.tvalid && rm.tready) begin
      ret[ret_n] = rm.tdata;
      ret_n++;
    end
    rm.tready <= ($urandom_range(99) >= rbp_pct);
  end

  `include "vs_stream_adapter_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("vs_stream_adapter_tb.vcd");
      $dumpvars(0, vs_stream_adapter_tb);
    end
    s.tvalid = 0;
    s.tdata = 0;
    s.tlast = 0;
    s.tuser = 0;
    rs.tdata = 0;
    rs.tlast = 0;
    rs.tuser = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    test_reset();
    test_leading_pixels();
    test_forward();
    test_line_gap();
    test_drop_busy();
    test_drop_return_full();
    test_return_backpressure();
    test_ret_overflow();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5ms;
    $display("ERROR: timeout");
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
