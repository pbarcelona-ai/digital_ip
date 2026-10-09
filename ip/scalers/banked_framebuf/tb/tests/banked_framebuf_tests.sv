// ***************
// Filename: banked_framebuf_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of fb_checker, the test-case module of the
//   banked_framebuf testbench (banked_framebuf_tb.sv), moved out of it and
//   `included into that module, so they use its signals, parameters and
//   models directly. Tasks, in file order:
//     write_row   Expected-window queue (pipeline model driven by rd_adv)
//     read_cycle  One read cycle
//     flush
// Date: 2026-10-08
// ***************
  // expected-window queue (pipeline model driven by rd_adv)
  task automatic write_row(input int b, input int y);
    for (int x = 0; x < w; x++) begin
      @(negedge clk);
      wr_en = 1; wr_buf = b; wr_x = x; wr_y = y; wr_data = PIX_W'($urandom);
      ref_img[b][y][x] = wr_data;
    end
    @(negedge clk) wr_en = 0;
  endtask

  // one read cycle: issue a window at (x0, y0) of buffer b (issue = 0 only
  // flushes the pipeline), then compare the window that comes out
  task automatic read_cycle(input bit issue, input int b, input int x0, input int y0,
                            input bit adv);
    @(negedge clk);
    rd_adv = adv; rd_buf = b; rd_x0 = 18'(x0); rd_y0 = 18'(y0);
    @(posedge clk);
    if (adv) begin
      qv[2] = qv[1]; qx[2] = qx[1]; qy[2] = qy[1]; qb[2] = qb[1];
      qv[1] = issue; qx[1] = x0;    qy[1] = y0;    qb[1] = b;
    end
    #1;
    if (qv[2]) begin
      for (int j = 0; j < TAPS; j++)
        for (int i = 0; i < TAPS; i++) begin
          logic [PIX_W-1:0] e;
          e = ref_img[qb[2]][cl(qy[2] + j, h - 1)][cl(qx[2] + i, w - 1)];
          checks++;
          if (rd_win[((j*TAPS)+i)*PIX_W +: PIX_W] !== e) begin
            errors++;
            if (errors < 6)
              $display("ERROR: TAPS=%0d NBUF=%0d RING=%0d buf%0d win(%0d,%0d) tap(%0d,%0d) got %0h exp %0h",
                       TAPS, NBUF, RING, qb[2], qx[2], qy[2], j, i,
                       rd_win[((j*TAPS)+i)*PIX_W +: PIX_W], e);
          end
        end
      qv[2] = 0;
    end
  endtask

  task automatic flush();
    read_cycle(0, 0, 0, 0, 1);
    read_cycle(0, 0, 0, 0, 1);
    @(negedge clk) rd_adv = 0;
  endtask
