// ***************
// Filename: ddr_frame_store_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of tb_ddr_frame_store (tb_ddr_frame_store.sv),
//   `included into that module, so they use its signals and parameters
//   directly. Tasks, in file order:
//     check                  Counts an error and prints the message when the
//                            condition is not 1 (false, X or Z)
//     pix                    Test pixel of (buffer, address, seed)
//     write_pixel            One pixel write (wr_en until wr_ready), random
//                            gap before
//     write_frame            A whole frame in raster order into a buffer,
//                            the scoreboard updated
//     wait_idle              Waits for wr_idle
//     read4                  One four-address request (optional rd_flush),
//                            returns the pixels at rd_valid
//     read_check             read4, then compares with expected pixels
//     test_write_read        A frame into buffer 0, read back in bilinear
//                            and bicubic neighbourhoods
//     test_double_buffer     Buffer 1 written while buffer 0 is read: the
//                            read frame stays intact
//     test_rewrite_flush     A rewritten buffer reads its old (cached) pixel
//                            without rd_flush, the new one with it
//     test_scattered_writes  Single pixels at scattered addresses (partial
//                            words) read back after wr_idle and rd_flush
//     test_wr_idle           wr_idle falls with a write, rises once it is in
//                            memory
//     test_clear             clear during a line fill drops the request; the
//                            next request is answered
//     test_timing_kept       ddr_mem reported no timing violation
// Date: 2026-10-25
  task automatic check(input logic cond, input string msg);
    if (cond !== 1'b1) begin                     // X or Z counts as a failure
      errors++;
      $display("ERROR %0t: %s", $time, msg);
    end
  endtask

  function automatic logic [PW-1:0] pix(input int b, input int a, input int seed);
    pix = PW'((a * 7919 + b * 104729 + seed * 1299709) ^ (a << 9));
  endfunction

  task automatic write_pixel(input logic b, input int a, input logic [PW-1:0] d);
    if ($urandom % 4 == 0) repeat ($urandom % 3 + 1) @(posedge clk);   // gap
    @(posedge clk);
    #1;
    wr_en = 1'b1;
    wr_buf = b;
    wr_addr = AW'(a);
    wr_data = d;
    do @(posedge clk);
    while (!wr_ready);
    #1 wr_en = 1'b0;
  endtask

  task automatic write_frame(input logic b, input int seed);
    for (int a = 0; a < NPIX; a++) begin
      write_pixel(b, a, pix(b, a, seed));
      sb[b][a] = pix(b, a, seed);
    end
  endtask

  task automatic wait_idle();
    @(posedge clk);
    while (!wr_idle) @(posedge clk);
  endtask

  task automatic read4(input logic b, input int a0, input int a1, input int a2, input int a3, input logic flush,
                       output logic [PW-1:0] got [4]);
    @(posedge clk);
    #1;
    rd_en = 1'b1;
    rd_buf = b;
    rd_flush = flush;
    rd_addr[0] = AW'(a0);
    rd_addr[1] = AW'(a1);
    rd_addr[2] = AW'(a2);
    rd_addr[3] = AW'(a3);
    do @(posedge clk);
    while (!rd_ready);
    #1;
    rd_en = 1'b0;
    rd_flush = 1'b0;
    do @(posedge clk);
    while (!rd_valid);
    for (int k = 0; k < 4; k++) got[k] = rd_data[k];
  endtask

  task automatic read_check(input logic b, input int a0, input int a1, input int a2, input int a3,
                            input logic flush, input string what);
    logic [PW-1:0] got [4];
    logic [PW-1:0] e [4];
    int a [4];
    a[0] = a0;
    a[1] = a1;
    a[2] = a2;
    a[3] = a3;
    for (int k = 0; k < 4; k++) e[k] = sb[b][a[k]];
`ifdef MUTATE
    e[0][0] = ~e[0][0];
`endif
    read4(b, a0, a1, a2, a3, flush, got);
    for (int k = 0; k < 4; k++)
      check(got[k] == e[k], $sformatf("%s: buffer %0d pixel %0d: %h, expected %h", what, b, a[k], got[k], e[k]));
  endtask

  function automatic int at(input int x, input int y);
    at = (y < 0 ? 0 : (y >= FH ? FH - 1 : y)) * FW + (x < 0 ? 0 : (x >= FW ? FW - 1 : x));
  endfunction

  task automatic test_write_read();
    write_frame(1'b0, 1);
    wait_idle();
    for (int y = 0; y < FH - 1; y += 3) begin
      for (int x = 0; x < FW; x++) begin
        read_check(1'b0, at(x, y), at(x + 1, y), at(x, y + 1), at(x + 1, y + 1), x == 0 && y == 0, "bilinear");
        read_check(1'b0, at(x - 1, y + 2), at(x, y + 2), at(x + 1, y + 2), at(x + 2, y + 2), 1'b0, "bicubic");
      end
    end
  endtask

  task automatic test_double_buffer();
    fork
      write_frame(1'b1, 2);
      for (int n = 0; n < 80; n++) begin
        int x, y;
        x = int'($urandom % FW);
        y = int'($urandom % FH);
        read_check(1'b0, at(x, y), at(x + 1, y), at(x, y + 1), at(x + 1, y + 1), 1'b0, "read during write");
      end
    join
    wait_idle();
    for (int a = 0; a < NPIX; a += 4) read_check(1'b1, a, a + 1, a + 2, a + 3, a == 0, "written during read");
  endtask

  task automatic test_rewrite_flush();
    logic [PW-1:0] old_px, got [4];
    old_px = sb[0][at(5, 5)];
    read_check(1'b0, at(5, 5), at(5, 5), at(5, 5), at(5, 5), 1'b1, "before the rewrite");   // line cached
    write_frame(1'b0, 3);
    wait_idle();
    read4(1'b0, at(5, 5), at(5, 5), at(5, 5), at(5, 5), 1'b0, got);
    check(got[0] == old_px, $sformatf("without rd_flush: %h, expected the cached %h", got[0], old_px));
    read_check(1'b0, at(5, 5), at(6, 5), at(5, 6), at(6, 6), 1'b1, "after rd_flush");
  endtask

  task automatic test_scattered_writes();
    for (int n = 0; n < 40; n++) begin
      int a;
      a = int'(($urandom % (NPIX / 11)) * 11);
      sb[1][a] = PW'($urandom);
      write_pixel(1'b1, a, sb[1][a]);
      repeat (6) @(posedge clk);                                     // past FLUSH_IDLE: a partial word
    end
    wait_idle();
    for (int a = 0; a + 33 < NPIX; a += 44)
      read_check(1'b1, a, a + 11, a + 22, a + 33, a == 0, "scattered");
  endtask

  task automatic test_wr_idle();
    int n;
    wait_idle();
    check(wr_idle, "wr_idle low with nothing written");
    sb[0][7] = PW'(24'hA5A5A5);
    write_pixel(1'b0, 7, sb[0][7]);
    check(!wr_idle, "wr_idle high right after a write");
    n = 0;
    while (!wr_idle && n < 200) begin
      @(posedge clk);
      n++;
    end
    check(wr_idle, "wr_idle did not return within 200 clocks");
    read_check(1'b0, 7, 7, 6, 8, 1'b1, "after wr_idle");
  endtask

  task automatic test_clear();
    int n, seen;
    @(posedge clk);
    #1;
    rd_en = 1'b1;
    rd_buf = 1'b1;
    rd_flush = 1'b1;                                                 // nothing cached: the lookup misses
    for (int k = 0; k < 4; k++) rd_addr[k] = AW'(k);
    do @(posedge clk);
    while (!rd_ready);
    #1;
    rd_en = 1'b0;
    rd_flush = 1'b0;
    repeat (2) @(posedge clk);                                       // the line fill under way
    #1 clear = 1'b1;
    @(posedge clk);
    #1 clear = 1'b0;
    seen = 0;
    n = 0;
    while (!rd_ready && n < 300) begin
      @(posedge clk);
      seen += int'(rd_valid);
      n++;
    end
    repeat (8) begin
      @(posedge clk);
      seen += int'(rd_valid);
    end
    check(rd_ready, "not ready again after a clear during a fill");
    check(seen == 0, $sformatf("%0d rd_valid after the clear", seen));
    read_check(1'b1, 0, 1, 2, 3, 1'b0, "after a clear");
  endtask

  task automatic test_timing_kept();
    check(mem_err_cnt == 16'd0, $sformatf("ddr_mem reported %0d timing violations (last code %0d)", mem_err_cnt,
                                          mem_err_code));
  endtask
