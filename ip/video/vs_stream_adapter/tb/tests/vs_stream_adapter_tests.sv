// ***************
// Filename: vs_stream_adapter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the vs_stream_adapter_tb testbench
//   (vs_stream_adapter_tb.sv), `included into that module, so they use its
//   signals directly. Tasks, in file order:
//     check                    Counts an error and prints the message when
//                              the condition is false
//     pix                      Pixel value of frame label f at index i
//     send_frame               The camera sends frame label f (W x H, tuser
//                              on the first pixel, tlast at line ends) and
//                              returns the longest wait for tready
//     wait_return              Waits until the return side has delivered n
//                              pixels in total
//     check_return             The pixels returned since index r0 are frame
//                              label f, unchanged
//     test_reset               Counters 0, no output valid, r_s_axis_tready
//                              high after reset
//     test_leading_pixels      Pixels before the first frame start are
//                              dropped, then the frame is forwarded
//     test_forward             A frame sent while vision_system is idle is
//                              forwarded whole and unchanged and returned
//     test_line_gap            At least GAP idle clocks after every forwarded
//                              line
//     test_drop_busy           A frame arriving while vision_system is busy
//                              is dropped (drops_o) without holding up the
//                              camera, and the next one is forwarded
//     test_drop_return_full    A frame arriving while the return FIFO still
//                              holds the previous corrected frame is dropped
//     test_return_backpressure Ten frames with 50 % back-pressure on the
//                              return side: every forwarded frame returned
//                              intact, none lost (ret_drops_o 0)
//     test_ret_overflow        More return beats than the FIFO holds with the
//                              return side stopped: vision_system is never
//                              stalled, the excess is counted in ret_drops_o
//                              and the beats kept come out in order
// Date: 2026-10-11
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  function automatic logic [23:0] pix(input int f, input int i);
    return {8'(f), 8'(i), 8'(f * 7 + i * 3)};
  endfunction

  task automatic send_frame(input int f, output int max_wait);
    int w;
    max_wait = 0;
    for (int i = 0; i < NPIX; i++) begin
      @(negedge clk);
      s.tvalid = 1;
      s.tdata = pix(f, i);
      s.tuser = i == 0;
      s.tlast = i % W == W - 1;
      w = 0;
      while (!s.tready) begin
        @(negedge clk);
        w++;
      end
      if (w > max_wait) max_wait = w;
      @(posedge clk);
    end
    @(negedge clk);
    s.tvalid = 0;
  endtask

  task automatic wait_return(input int n);
    int t = 0;
    while (ret_n < n && t < 20000) begin
      @(posedge clk);
      t++;
    end
    check(ret_n >= n, $sformatf("return side: %0d pixels, %0d expected", ret_n, n));
  endtask

  task automatic check_return(input int r0, input int f, input string name);
    int bad = 0;
    for (int i = 0; i < NPIX; i++) if (ret[r0 + i] !== pix(f, i)) bad++;
    check(bad == 0, $sformatf("%s: %0d returned pixels differ from frame %0d", name, bad, f));
  endtask

  task automatic test_reset();
    check(frames_o == 0 && drops_o == 0 && ret_drops_o == 0, "counters not 0 after reset");
    check(!m.tvalid && !rm.tvalid, "valid outputs after reset");
    check(rs.tready === 1'b1, "r_s_axis_tready not high");
    $display("[%0t] test_reset: counters 0, outputs idle, return side always ready", $time);
  endtask

  task automatic test_leading_pixels();
    int w, r0;
    for (int i = 0; i < 5; i++) begin                  // the tail of a frame that started before reset
      @(negedge clk);
      s.tvalid = 1;
      s.tdata = 24'hDEAD00 + i;
      s.tuser = 0;
      s.tlast = i == 4;
      while (!s.tready) @(negedge clk);
      @(posedge clk);
      check(!m.tvalid, "pixel before the first frame start forwarded");
    end
    @(negedge clk);
    s.tvalid = 0;
    r0 = ret_n;
    send_frame(1, w);
    wait_return(r0 + NPIX);
    check_return(r0, 1, "first frame after leading pixels");
    check(frames_o == 1 && drops_o == 0, $sformatf("frames_o %0d drops_o %0d, expected 1 / 0", frames_o, drops_o));
    $display("[%0t] test_leading_pixels: pixels before the first frame start dropped", $time);
  endtask

  task automatic test_forward();
    int w, r0, f0;
    f0 = frames_o;
    r0 = ret_n;
    send_frame(2, w);
    wait_return(r0 + NPIX);
    check_return(r0, 2, "forwarded frame");
    check(frames_o == f0 + 1, "frames_o not incremented");
    check(cap[NPIX-1] == pix(2, NPIX - 1), "vision_system model captured another frame");
    $display("[%0t] test_forward: frame forwarded whole and returned unchanged", $time);
  endtask

  task automatic test_line_gap();
    min_gap = 1000;
    test_forward();
    check(min_gap >= GAP, $sformatf("only %0d idle clocks after a forwarded line, GAP = %0d", min_gap, GAP));
    $display("[%0t] test_line_gap: at least %0d idle clocks after every line (shortest %0d)", $time, GAP, min_gap);
  endtask

  task automatic test_drop_busy();
    int w, r0, d0, f0;
    busy_clks = 400;
    r0 = ret_n;
    d0 = drops_o;
    f0 = frames_o;
    send_frame(3, w);                                  // forwarded: vision_system now busy
    send_frame(4, w);                                  // arrives while busy: dropped
    check(w <= GAP, $sformatf("camera held up %0d clocks while a frame was dropped", w));
    check(drops_o == d0 + 1 && frames_o == f0 + 1, $sformatf("drops_o +%0d frames_o +%0d, expected +1 / +1",
                                                            drops_o - d0, frames_o - f0));
    wait_return(r0 + NPIX);
    check_return(r0, 3, "frame before the dropped one");
    busy_clks = 40;
    repeat (20) @(posedge clk);
    r0 = ret_n;
    send_frame(5, w);
    wait_return(r0 + NPIX);
    check_return(r0, 5, "frame after the dropped one");
    $display("[%0t] test_drop_busy: frame dropped while vision_system was busy, camera not held up", $time);
  endtask

  task automatic test_drop_return_full();
    int w, r0, d0;
    rbp_pct = 100;                                     // return side stopped: the FIFO keeps the frame
    r0 = ret_n;
    send_frame(6, w);
    while (vst != V_IDLE) @(posedge clk);
    repeat (5) @(posedge clk);
    d0 = drops_o;
    send_frame(7, w);                                  // vision_system idle, return FIFO not empty
    check(drops_o == d0 + 1, "frame forwarded although the return FIFO was not empty");
    rbp_pct = 0;
    wait_return(r0 + NPIX);
    check_return(r0, 6, "frame held in the return FIFO");
    repeat (10) @(posedge clk);
    check(ret_n == r0 + NPIX, "the dropped frame came back");
    $display("[%0t] test_drop_return_full: frame dropped while the return FIFO was not empty", $time);
  endtask

  task automatic test_return_backpressure();
    int w, r0, d0;
    rbp_pct = 50;
    d0 = ret_drops_o;
    for (int f = 10; f < 20; f++) begin
      r0 = ret_n;
      send_frame(f, w);
      wait_return(r0 + NPIX);
      check_return(r0, f, $sformatf("frame %0d with return back-pressure", f));
      while (dut.rf_level != 0) @(posedge clk);
    end
    check(ret_drops_o == d0, $sformatf("%0d return beats lost", ret_drops_o - d0));
    rbp_pct = 0;
    $display("[%0t] test_return_backpressure: 10 frames returned intact with 50 %% back-pressure", $time);
  endtask

  // vision_system emits more than the FIFO can hold while the return side is stopped
  task automatic test_ret_overflow();
    int n, kept, d0, r0;
    n = RET_FIFO + 20;
    rbp_pct = 100;
    repeat (5) @(posedge clk);
    d0 = ret_drops_o;
    r0 = ret_n;
    ov_i = 0;
    ov_left = n;
    while (ov_left > 0) @(posedge clk);
    repeat (2) @(posedge clk);
    kept = n - (ret_drops_o - d0);
    check(ret_drops_o - d0 > 0 && kept >= RET_FIFO, $sformatf("%0d beats sent, %0d counted lost, %0d kept (FIFO %0d)",
                                                             n, ret_drops_o - d0, kept, RET_FIFO));
    rbp_pct = 0;
    wait_return(r0 + kept);
    for (int i = 0; i < kept; i++) check(ret[r0 + i] === 24'hF00000 + i, $sformatf("kept beat %0d out of order", i));
    $display("[%0t] test_ret_overflow: %0d of %0d beats counted in ret_drops_o, vision_system never stalled", $time,
             n - kept, n);
  endtask
