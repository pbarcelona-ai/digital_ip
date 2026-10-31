// ***************
// Filename: ddr_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the ddr_ctrl_tb testbench (ddr_ctrl_tb.sv),
//   `included into that module, so they use its signals and parameters
//   directly. Tasks, in file order:
//     check                  Counts an error and prints the message when the
//                            condition is not 1 (false, X or Z)
//     port_idle              Drives one port's AXI4 inputs to idle
//     waddr                  Byte address of (row, bank, column)
//     wbyte                  Test data byte for (address, seed)
//     axi_write              One write burst on a port (W gaps, B
//                            back-pressure), checks BID / BRESP, updates the
//                            shadow memory when OKAY
//     axi_read               One read burst on a port (R back-pressure),
//                            checks RID / RRESP / RLAST and the data against
//                            the shadow memory (0 for an error)
//     test_register_map      ID, VERSION, idle STATUS, SLVERR on a write to
//                            a read-only register
//     test_write_read        Bursts of 1 .. 16 beats on each port, across
//                            columns, banks and rows, read back
//     test_both_ports        Both ports write and read their own data at
//                            once (same bank, other rows: PRE / ACT
//                            between the bursts)
//     test_strobes           Partial WSTRB writes keep the other bytes
//     test_errors            SLVERR (size, FIXED burst) and DECERR (beyond
//                            the memory): read data 0, memory untouched
//     test_refresh           About one REF per T_REFI while idle
//     test_statistics        RD / WR beats, ACTs, HITS, REFS, ERRS against
//                            the DFI commands; CTRL[0] clears them
//     test_timing_kept       ddr_mem reported no timing violation
// Date: 2026-10-25
  int n_err_bursts = 0;

  task automatic check(input logic cond, input string msg);
    if (cond !== 1'b1) begin                     // X or Z counts as a failure
      errors++;
      $display("ERROR %0t: %s", $time, msg);
    end
  endtask

  task automatic port_idle(input int p);
    awid[p] = '0;
    awaddr[p] = '0;
    awlen[p] = '0;
    awsize[p] = 3'(3);
    awburst[p] = 2'b01;
    awvalid[p] = 1'b0;
    wdata[p] = '0;
    wstrb[p] = '0;
    wlast[p] = 1'b0;
    wvalid[p] = 1'b0;
    bready[p] = 1'b0;
    arid[p] = '0;
    araddr[p] = '0;
    arlen[p] = '0;
    arsize[p] = 3'(3);
    arburst[p] = 2'b01;
    arvalid[p] = 1'b0;
    rready[p] = 1'b0;
  endtask

  function automatic logic [AW-1:0] waddr(input int row, input int bank, input int col);
    waddr = AW'(((row << (BW + CW)) | (bank << CW) | col) * NB);
  endfunction

  function automatic logic [7:0] wbyte(input int a, input int seed);
    wbyte = 8'((a * 37 + seed * 101 + (a >> 8)) ^ (seed << 3));
  endfunction

  // one write burst; strb_all = 0 writes a random strobe per beat
  task automatic axi_write(input int p, input int id, input logic [AW-1:0] a, input int len, input int size,
                           input int burst, input int seed, input logic strb_all, input logic [1:0] exp_resp);
    int w0;
    w0 = int'(a) / NB;
    @(posedge clk);
    #1;
    awid[p] = IW'(id);
    awaddr[p] = a;
    awlen[p] = 8'(len);
    awsize[p] = 3'(size);
    awburst[p] = 2'(burst);
    awvalid[p] = 1'b1;
    fork
      begin
        do @(posedge clk);
        while (!s_awready[p]);
        #1 awvalid[p] = 1'b0;
      end
      begin
        for (int k = 0; k <= len; k++) begin
          logic [NB-1:0] s;
          s = strb_all ? '1 : NB'($urandom);
          for (int b = 0; b < NB; b++) begin
            wdata[p][8*b +: 8] = wbyte((w0 + k) * NB + b, seed);
            if (exp_resp == 2'b00 && s[b]) shadow[(w0 + k) * NB + b] = wbyte((w0 + k) * NB + b, seed);
          end
          wstrb[p] = s;
          wlast[p] = (k == len);
          if ($urandom % 4 == 0) repeat ($urandom % 3 + 1) @(posedge clk);   // gap on W
          #1 wvalid[p] = 1'b1;
          do @(posedge clk);
          while (!s_wready[p]);
          #1 wvalid[p] = 1'b0;
        end
        wlast[p] = 1'b0;
      end
    join
    while (!s_bvalid[p]) @(posedge clk);
    repeat ($urandom % 3) @(posedge clk);                                      // back-pressure on B
    #1 bready[p] = 1'b1;
    do @(posedge clk);
    while (!s_bvalid[p]);
    check(s_bid[p*IW +: IW] == IW'(id), $sformatf("port %0d BID %0d, expected %0d", p, s_bid[p*IW +: IW], id));
    check(s_bresp[p*2 +: 2] == exp_resp, $sformatf("port %0d BRESP %0d, expected %0d", p, s_bresp[p*2 +: 2],
                                                   exp_resp));
    #1 bready[p] = 1'b0;
    if (exp_resp != 2'b00) n_err_bursts++;
  endtask

  task automatic axi_read(input int p, input int id, input logic [AW-1:0] a, input int len, input int size,
                          input int burst, input logic [1:0] exp_resp);
    int w0;
    w0 = int'(a) / NB;
    @(posedge clk);
    #1;
    arid[p] = IW'(id);
    araddr[p] = a;
    arlen[p] = 8'(len);
    arsize[p] = 3'(size);
    arburst[p] = 2'(burst);
    arvalid[p] = 1'b1;
    do @(posedge clk);
    while (!s_arready[p]);
    #1 arvalid[p] = 1'b0;
    for (int k = 0; k <= len; k++) begin
      logic [DW-1:0] e;
      for (int b = 0; b < NB; b++) e[8*b +: 8] = (exp_resp == 2'b00) ? shadow[(w0 + k) * NB + b] : 8'h00;
`ifdef MUTATE
      e[0] = ~e[0];
`endif
      #1 rready[p] = ($urandom % 3 != 0);                                      // back-pressure on R
      @(posedge clk);
      while (!(s_rvalid[p] && rready[p])) begin
        #1 rready[p] = ($urandom % 3 != 0);
        @(posedge clk);
      end
      check(s_rdata[p*DW +: DW] == e, $sformatf("port %0d beat %0d @%0h: RDATA %h, expected %h", p, k, a,
                                                s_rdata[p*DW +: DW], e));
      check(s_rid[p*IW +: IW] == IW'(id), $sformatf("port %0d RID %0d, expected %0d", p, s_rid[p*IW +: IW], id));
      check(s_rresp[p*2 +: 2] == exp_resp, $sformatf("port %0d RRESP %0d, expected %0d", p, s_rresp[p*2 +: 2],
                                                     exp_resp));
      check(s_rlast[p] == (k == len), $sformatf("port %0d beat %0d of %0d: RLAST %0d", p, k, len, s_rlast[p]));
    end
    #1 rready[p] = 1'b0;
    if (exp_resp != 2'b00) n_err_bursts++;
  endtask

  task automatic test_register_map();
    logic [31:0] d;
    u_bfm.read(8'h00, d);
    check(d == "DDRC", $sformatf("ID %h", d));
    u_bfm.read(8'h04, d);
    check(d != 32'h0, "VERSION 0");
    u_bfm.read(8'h14, d);
    check(d[0] == 1'b0, $sformatf("STATUS %h: a burst active when idle", d));
    u_bfm.write(8'h00, 32'h1234);
    check(u_bfm.last_resp == 2'b10, $sformatf("write to ID answered %0d, expected SLVERR", u_bfm.last_resp));
    u_bfm.read(8'h00, d);
    check(d == "DDRC", "ID changed by a write");
  endtask

  task automatic test_write_read();
    int lens [6] = '{0, 1, 3, 7, 12, 15};
    for (int p = 0; p < NP; p++) begin
      for (int i = 0; i < 6; i++) begin
        logic [AW-1:0] a;
        a = waddr(2 * i + p, i % 4, (i * 3) % 8) + AW'($urandom % NB);   // low bits ignored
        axi_write(p, i + 1, a, lens[i], 3, 1, 10 * p + i, 1'b1, 2'b00);
        axi_read(p, i + 2, a, lens[i], 3, 1, 2'b00);
      end
    end
  endtask

  task automatic test_both_ports();
    fork
      begin
        axi_write(0, 5, waddr(12, 1, 0), 15, 3, 1, 40, 1'b1, 2'b00);
        axi_read(0, 6, waddr(12, 1, 8), 7, 3, 1, 2'b00);
        axi_read(0, 7, waddr(12, 1, 0), 15, 3, 1, 2'b00);
      end
      begin
        axi_write(1, 9, waddr(13, 1, 0), 15, 3, 1, 41, 1'b1, 2'b00);
        axi_read(1, 10, waddr(13, 1, 4), 7, 3, 1, 2'b00);
        axi_read(1, 11, waddr(13, 1, 0), 15, 3, 1, 2'b00);
      end
    join
  endtask

  task automatic test_strobes();
    axi_write(0, 3, waddr(14, 2, 0), 7, 3, 1, 50, 1'b1, 2'b00);
    axi_write(1, 4, waddr(14, 2, 0), 7, 3, 1, 51, 1'b0, 2'b00);   // random strobes over the first
    axi_read(0, 3, waddr(14, 2, 0), 7, 3, 1, 2'b00);
  endtask

  task automatic test_errors();
    axi_write(0, 1, waddr(15, 0, 0), 3, 2, 1, 60, 1'b1, 2'b10);          // 4-byte size: SLVERR
    axi_write(1, 2, waddr(15, 0, 0), 3, 3, 0, 61, 1'b1, 2'b10);          // FIXED: SLVERR
    axi_write(0, 3, waddr(15, 3, 6), 3, 3, 1, 62, 1'b1, 2'b11);          // beyond the memory: DECERR
    axi_read(1, 4, waddr(15, 0, 0), 3, 2, 1, 2'b10);
    axi_read(0, 5, waddr(15, 0, 0), 3, 3, 2, 2'b10);                      // WRAP: SLVERR
    axi_read(1, 6, waddr(15, 3, 6), 3, 3, 1, 2'b11);
    axi_read(0, 7, waddr(15, 0, 0), 3, 3, 1, 2'b00);                      // untouched (0)
    axi_read(1, 8, waddr(15, 3, 4), 3, 3, 1, 2'b00);                      // the last 4 words: in range
  endtask

  task automatic test_refresh();
    int r0;
    r0 = n_ref;
    repeat (10 * T_REFI) @(posedge clk);
    check(n_ref - r0 >= 9 && n_ref - r0 <= 11, $sformatf("%0d REFs in %0d clocks (T_REFI %0d)", n_ref - r0,
                                                         10 * T_REFI, T_REFI));
  endtask

  task automatic test_statistics();
    logic [31:0] rd, wr, act, hit, rf, er;
    u_bfm.read(8'h18, rd);
    u_bfm.read(8'h1C, wr);
    u_bfm.read(8'h20, act);
    u_bfm.read(8'h24, hit);
    u_bfm.read(8'h28, rf);
    u_bfm.read(8'h2C, er);
    check(rd == 32'(n_rd), $sformatf("RD_BEATS %0d, %0d RD commands", rd, n_rd));
    check(wr == 32'(n_wr), $sformatf("WR_BEATS %0d, %0d WR commands", wr, n_wr));
    check(act == 32'(n_act), $sformatf("ACTS %0d, %0d ACT commands", act, n_act));
    check(hit <= rd + wr && hit + act >= rd + wr, $sformatf("HITS %0d (beats %0d, ACTs %0d)", hit, rd + wr, act));
    check(rf + 1 >= 32'(n_ref) && rf <= 32'(n_ref), $sformatf("REFS %0d, %0d REF commands", rf, n_ref));
    check(er == 32'(n_err_bursts), $sformatf("ERRS %0d, %0d error bursts", er, n_err_bursts));
    check(rd != 0 && wr != 0 && act != 0 && hit != 0 && rf != 0 && er != 0, "a statistic stayed 0");
    u_bfm.write(8'h10, 32'h1);
    check(u_bfm.last_resp == 2'b00, "CTRL write answered an error");
    u_bfm.read(8'h18, rd);
    u_bfm.read(8'h1C, wr);
    u_bfm.read(8'h2C, er);
    check(rd == 0 && wr == 0 && er == 0, $sformatf("after clear: RD %0d WR %0d ERRS %0d", rd, wr, er));
  endtask

  task automatic test_timing_kept();
    check(mem_err_cnt == 16'd0, $sformatf("ddr_mem reported %0d timing violations (last code %0d)", mem_err_cnt,
                                          mem_err_code));
  endtask
