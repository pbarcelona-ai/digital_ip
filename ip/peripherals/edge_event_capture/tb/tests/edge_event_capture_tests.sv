// ***************
// Filename: edge_event_capture_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the edge_event_capture_tb testbench
//   (edge_event_capture_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     test_id_block   ID "EDGE", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                     0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                     offsets from bfm.base = 0x10, the map after the ID block)
//     test_setup      Rising edges on inputs 0-3, falling on 4-7, all interrupts
//     test_edges      Rise / fall detection, masks, pending W1C, irq_o
//     test_records    Event records {timestamp, fall, rise} on the stream
//     test_debounce   DEBOUNCE 8 rejects a 4-clock glitch
//     test_multi      Simultaneous edges of several inputs in one record
//     test_overflow   A full FIFO counts dropped records
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "EDGE", $sformatf("ID %h (\"%s\"), expected \"EDGE\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_setup();
    bfm.write(8'h04, 32'h0F); // rise: 0-3, fall: 4-7
    bfm.write(8'h08, 32'hF0);
    bfm.write(8'h24, 32'hFF);
  endtask

  task automatic test_edges();
    // ---- Test 1: basic rise/fall, masks ----
    sig[1] = 1;
    repeat (6) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h02, $sformatf("rise pend %h", rd));
    sig[5] = 1; // rise on masked (fall-only) channel
    repeat (6) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h02, "channel 5 rise must be masked");
    sig[5] = 0;
    repeat (6) @(posedge aclk);
    bfm.read(8'h14, rd);
    check(rd == 32'h20, $sformatf("fall pend %h", rd));
    check(irq == 1, "irq");
    bfm.write(8'h10, 32'hFF);
    bfm.write(8'h14, 32'hFF);
    repeat (3) @(posedge aclk);
    check(irq == 0, "irq should clear");
    bfm.read(8'h10, rd);
    check(rd == 0, "W1C rise");
    bfm.read(8'h18, rd);
    check(rd == 2, $sformatf("event count %0d", rd));
  endtask

  task automatic test_records();
    // ---- Test 2: event records ----
    check(ev_q.size() == 2, $sformatf("records %0d", ev_q.size()));
    if (ev_q.size() == 2) begin
      e0 = ev_q[0];
      e1 = ev_q[1];
      check(e0[W-1:0] == 8'h02 && e0[2*W-1:W] == 0, "record 0 flags");
      check(e1[W-1:0] == 0 && e1[2*W-1:W] == 8'h20, "record 1 flags");
      check(e1[TS_W+2*W-1:2*W] > e0[TS_W+2*W-1:2*W], "timestamps must increase");
    end
  endtask

  task automatic test_debounce();
    // ---- Test 3: debounce 8 clocks rejects a 4 clock glitch ----
    bfm.write(8'h0C, 8);
    ev_q.delete();
    sig[2] = 1;
    repeat (4) @(posedge aclk);
    sig[2] = 0;
    repeat (20) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 0, "glitch should be filtered");
    sig[2] = 1;
    repeat (30) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h04, "stable input should pass debounce");
  endtask

  task automatic test_multi();
    // ---- Test 4: simultaneous multi-channel edges in one record ----
    bfm.write(8'h0C, 0);
    bfm.write(8'h10, 32'hFF);
    ev_q.delete();
    sig[0] = 1; // ~7-cycle capture latency + margin
    sig[3] = 1;
    sig[7] = 0;
    repeat (12) @(posedge aclk);
    e0 = ev_q[0];
    check(ev_q.size() >= 1 && e0[W-1:0] == 8'h09, "combined rise flags");
  endtask

  task automatic test_overflow();
    // ---- Test 5: FIFO overflow counts drops ----
    m_tready = 0;
    bfm.write(8'h0C, 0);
    repeat (40) begin
      sig[6] = ~sig[6];
      repeat (4) @(posedge aclk);
    end
    bfm.read(8'h20, rd);
    check(rd > 0, "drops expected with stalled stream");
    m_tready = 1;
  endtask
