// ***************
// Filename: pcie_tl_ep_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the pcie_tl_ep_tb testbench
//   (pcie_tl_ep_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     axil_write  (offset from reg_base = 0x10, the map after the ID block;
//                  axil_write_abs / axil_read_abs: absolute, BRESP in last_bresp)
//     axil_write  AXI4-Lite write of one register
//     axil_read   AXI4-Lite read of one register
//     wait_pkt
//     no_pkt
//     check_cpl   Completion field checks
//     test_id_block       ID "PCIE", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                         0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_cfg_id         CfgRd0 of the ID register
//     test_bar_sizing     BAR0 sizing
//     test_bar_program    Program BAR0 and command (memory + bus master); STATUS, BAR0
//     test_mem_rw         Memory write then read, 3DW headers
//     test_byte_enables   Byte enables (bytes 0 and 2 written)
//     test_4dw_read       4DW header memory read
//     test_partial_be     Partial byte enables shrink the byte count
//     test_stream_window  Stream window (upper BAR half) to m_axis
//     test_unsupported    Unsupported request handling
//     test_dma            DMA memory writes to the host (3DW then 4DW header)
//     test_counters       TLP counters
// Date: 2026-10-12
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    axil_write_abs(a + reg_base, d);
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    axil_read_abs(a + reg_base, d);
  endtask

  task automatic axil_write_abs(input [7:0] a, input [31:0] d);
    @(posedge aclk);
    #1;
    awaddr = a;
    awvalid = 1;
    wdata = d;
    wstrb = 4'hF;
    wvalid = 1;
    bready = 1;
    fork
      begin
        wait (awready);
        @(posedge aclk);
        #1 awvalid = 0;
      end
      begin
        wait (wready);
        @(posedge aclk);
        #1 wvalid = 0;
      end
    join
    wait (bvalid);
    last_bresp = bresp;
    @(posedge aclk);
    #1;
  endtask

  task automatic axil_read_abs(input [7:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    araddr = a;
    arvalid = 1;
    rready = 1;
    wait (arready);
    @(posedge aclk);
    #1 arvalid = 0;
    wait (rvalid);
    d = rdata;
    @(posedge aclk);
    #1;
  endtask

  task automatic wait_pkt();
    int t = 0;
    while (pcie.tx_len.size() <= pkts_read && t < 2000) begin
      @(posedge aclk);
      t++;
    end
    check(pcie.tx_len.size() > pkts_read, "timeout waiting for a TLP from the endpoint");
    if (pcie.tx_len.size() > pkts_read) begin
      rp_n = pcie.tx_len[pkts_read];
      for (int i = 0; i < rp_n; i++) rp[i] = pcie.tx_flat[rd_off + i];
      rd_off += rp_n;
      pkts_read++;
    end
  endtask

  task automatic no_pkt(input string what);
    repeat (60) @(posedge aclk);
    check(pcie.tx_len.size() == pkts_read, {"unexpected TLP after ", what});
  endtask

  // Completion field checks
  task automatic check_cpl(input bit data, input int len, input logic [2:0] status,
                           input logic [7:0] tag, input logic [11:0] bytes,
                           input logic [6:0] low, input string what);
    check(rp[0][31:29] == (data ? 3'b010 : 3'b000) && rp[0][28:24] == 5'b01010,
          {what, ": completion fmt/type"});
    check(rp[0][9:0] == (data ? len : 0), {what, ": completion length"});
    check(rp[1][15:13] == status, {what, ": completion status"});
    check(rp[1][11:0] == bytes, $sformatf("%s: byte count %0d exp %0d", what, rp[1][11:0], bytes));
    check(rp[2][31:16] == HOST_ID && rp[2][15:8] == tag, {what, ": requester/tag"});
    check(rp[2][6:0] == low, {what, ": lower address"});
    check(rp_n == (data ? 3 + len : 3), $sformatf("%s: TLP DW count %0d", what, rp_n));
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "PCIE", $sformatf("ID %h (\"%s\"), expected \"PCIE\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      axil_write_abs(8'(a), 32'hA5A5_5A5A);
      check(last_bresp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, last_bresp));
    end

    axil_read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_cfg_id();
    // ---- Test 1: CfgRd0 of the ID register ----
    pcie.cfg_tlp(0, 0, 8'h11, 0);
    wait_pkt();
    check_cpl(1, 1, 3'b000, 8'h11, 12'd4, 7'd0, "CfgRd0 id");
    check(rp_n == 4 && rp[3] == 32'h5678_1234, $sformatf("ID data %h", rp[3]));
    check(rp[1][31:16] == 16'h0100, "completer ID not captured from config request");
  endtask

  task automatic test_bar_sizing();
    // ---- Test 2: BAR0 sizing ----
    pcie.cfg_tlp(1, 4, 8'h12, 32'hFFFF_FFFF);
    wait_pkt();
    check_cpl(0, 0, 3'b000, 8'h12, 12'd4, 7'd0, "CfgWr0 bar");
    pcie.cfg_tlp(0, 4, 8'h13, 0);
    wait_pkt();
    check(rp_n == 4 && rp[3] == 32'hFFFF_E000, $sformatf("BAR0 size probe %h", rp[3]));
  endtask

  task automatic test_bar_program();
    // ---- Test 3: program BAR0 and command (mem + bus master) ----
    pcie.cfg_tlp(1, 4, 8'h14, BAR_BASE);
    wait_pkt();
    pcie.cfg_tlp(0, 4, 8'h15, 0);
    wait_pkt();
    check(rp[3] == BAR_BASE, "BAR0 readback");
    pcie.cfg_tlp(1, 1, 8'h16, 32'h0000_0006);
    wait_pkt();
    pcie.cfg_tlp(0, 1, 8'h17, 0);
    wait_pkt();
    check(rp[3][15:0] == 16'h0006, "command readback");
    axil_read(8'h10, rd);
    check(rd[1:0] == 2'b11, "STATUS mem_en/bus_master");
    axil_read(8'h18, rd);
    check(rd == BAR_BASE, "BAR0 register");
  endtask

  task automatic test_mem_rw();
    // ---- Test 4: memory write then read, 3DW headers ----
    pcie.mem_wr(BAR_BASE + 32'h10, 4, 0, 4'hF, 4'hF, 8'h20, 32'h11);
    no_pkt("posted write");
    pcie.mem_rd(BAR_BASE + 32'h10, 4, 0, 4'hF, 4'hF, 8'h21);
    wait_pkt();
    check_cpl(1, 4, 3'b000, 8'h21, 12'd16, 7'h10, "MRd 4DW");
    check(rp_n == 7 && rp[3] == 32'h11 && rp[4] == 32'h12 && rp[5] == 32'h13 &&
          rp[6] == 32'h14, "MRd data mismatch");
  endtask

  task automatic test_byte_enables();
    // ---- Test 5: byte enables (bytes 0 and 2 written) ----
    pcie.mem_wr(BAR_BASE + 32'h10, 1, 0, 4'b0101, 4'b0000, 8'h22, 32'hAABB_CCDD);
    pcie.mem_rd(BAR_BASE + 32'h10, 1, 0, 4'hF, 4'h0, 8'h23);
    wait_pkt();
    check(rp_n == 4 && rp[3] == 32'h00BB_00DD, $sformatf("byte enable merge %h", rp[3]));
  endtask

  task automatic test_4dw_read();
    // ---- Test 6: 4DW header memory read ----
    pcie.mem_rd(BAR_BASE + 32'h14, 3, 1, 4'hF, 4'hF, 8'h24);
    wait_pkt();
    check_cpl(1, 3, 3'b000, 8'h24, 12'd12, 7'h14, "MRd 4DW header");
    check(rp[3] == 32'h12 && rp[4] == 32'h13 && rp[5] == 32'h14, "4DW MRd data");
  endtask

  task automatic test_partial_be();
    // ---- Test 7: partial byte enables shrink the byte count ----
    pcie.mem_rd(BAR_BASE + 32'h14, 2, 0, 4'b1100, 4'b0011, 8'h25);
    wait_pkt();
    check_cpl(1, 2, 3'b000, 8'h25, 12'd4, 7'h16, "MRd partial BE");
  endtask

  task automatic test_stream_window();
    // ---- Test 8: stream window (upper BAR half) ----
    pcie.mem_wr(BAR_BASE + 32'h1000, 5, 0, 4'hF, 4'hF, 8'h26, 32'hC0DE_0000);
    repeat (40) @(posedge aclk);
    check(str_q.size() == 5, $sformatf("stream window got %0d words", str_q.size()));
    if (str_q.size() == 5) begin
      for (int i = 0; i < 5; i++) check(str_q[i] == 32'hC0DE_0000 + i, "stream data");
      check(str_l_q[4] == 1 && str_l_q[0] == 0, "stream tlast on the last word only");
    end
  endtask

  task automatic test_unsupported();
    // ---- Test 9: unsupported request handling ----
    pcie.mem_rd(32'hB000_0000, 1, 0, 4'hF, 4'h0, 8'h27);
    wait_pkt();
    check_cpl(0, 0, 3'b001, 8'h27, 12'd4, 7'd0, "UR for bad address");
    pcie.mem_wr(32'hB000_0000, 2, 0, 4'hF, 4'hF, 8'h28, 32'h0);
    no_pkt("posted write to bad address");
    pcie.tlp[0] = pcie.dw0(3'b000, 5'b00010, 1);
    pcie.tlp[1] = {HOST_ID, 8'h29, 4'h0, 4'hF};
    pcie.tlp[2] = 32'h100; // I/O read
    pcie.tlp_n = 3;
    pcie.send_tlp();
    wait_pkt();
    check_cpl(0, 0, 3'b001, 8'h29, 12'd4, 7'd0, "UR for I/O read");
    pcie.mem_rd(BAR_BASE + 32'h10, 1, 0, 4'hF, 4'h0, 8'h2A); // still alive
    wait_pkt();
    check(rp[3] == 32'h00BB_00DD, "endpoint recovered after UR");
  endtask

  task automatic test_dma();
    // ---- Test 10: DMA memory writes to host (3DW then 4DW header) ----
    axil_write(8'h04, 32'h1234_5000);
    axil_write(8'h08, 32'h0);
    axil_write(8'h0C, 32'd4);
    axil_write(8'h00, 32'h1);
    for (int i = 0; i < 8; i++) begin
      @(posedge aclk);
      #1 s_d = 32'hD0D0_0000 + i;
      s_v = 1;
      s_l = (i == 7);
      wait (s_r);
      @(posedge aclk);
      #1 s_v = 0;
      s_l = 0;
    end
    wait_pkt();
    check(rp_n == 7 && rp[0] == pcie.dw0(3'b010, 5'b00000, 4), "DMA TLP0 header");
    check(rp[1] == {16'h0100, 8'h00, 4'hF, 4'hF}, $sformatf("DMA TLP0 dw1 %h", rp[1]));
    check(rp[2] == 32'h1234_5000, "DMA TLP0 address");
    for (int i = 0; i < 4; i++) check(rp[3+i] == 32'hD0D0_0000 + i, "DMA TLP0 data");
    wait_pkt();
    check(rp_n == 7 && rp[2] == 32'h1234_5010 && rp[1][15:8] == 8'h01, "DMA TLP1 address/tag");
    for (int i = 0; i < 4; i++) check(rp[3+i] == 32'hD0D0_0004 + i, "DMA TLP1 data");
    axil_write(8'h00, 32'h0);
    axil_write(8'h04, 32'h0000_0100); // > 4 GB
    axil_write(8'h08, 32'h0000_0001);
    axil_write(8'h0C, 32'd1);
    axil_write(8'h00, 32'h1);
    @(posedge aclk);
    #1 s_d = 32'hFEED_BEEF;
    s_v = 1;
    s_l = 1;
    wait (s_r);
    @(posedge aclk);
    #1 s_v = 0;
    s_l = 0;
    wait_pkt();
    check(rp_n == 5 && rp[0] == pcie.dw0(3'b011, 5'b00000, 1), "DMA 4DW header fmt");
    check(rp[1][7:0] == 8'h0F, "single DW write must use lastBE = 0 and firstBE = F");
    check(rp[2] == 32'h1 && rp[3] == 32'h100 && rp[4] == 32'hFEED_BEEF, "DMA 4DW address/data");
    axil_write(8'h00, 32'h0);
  endtask

  task automatic test_counters();
    // ---- Test 11: counters ----
    axil_read(8'h1C, rd);
    check(rd == 18, $sformatf("RX_TLP counter %0d", rd));
    axil_read(8'h20, rd);
    check(rd == 4, $sformatf("MWR counter %0d", rd));
    axil_read(8'h28, rd);
    check(rd == 7, $sformatf("CFG counter %0d", rd));
    axil_read(8'h2C, rd);
    check(rd == 2, $sformatf("UR counter %0d", rd));
    axil_read(8'h30, rd);
    check(rd == 3, $sformatf("DMA TLP counter %0d", rd));
  endtask
