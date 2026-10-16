// ***************
// Filename: frame_counter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the frame_counter_tb testbench
//   (frame_counter_tb.sv), `included into that module, so they use its
//   signals directly. Tasks, in file order:
//     check                Counts an error and prints the message when the
//                          condition is false
//     compare              Every COUNT, STATUS, IRQ_EN and irq_o equal the
//                          reference model
//     pulse                One end-of-frame pulse on the given channels
//     test_id_block        ID, VERSION ("d.dd") and DATE (BCD mm/dd/yyyy) at
//                          the base address, read only; the map after them at 0x10
//     test_registers       reset values of IRQ_EN, STATUS, EVENT, EV_EN and
//                          every COUNT
//     test_count           Pulses on single channels and on several at once
//                          are counted per channel
//     test_irq             irq_o = STATUS & IRQ_EN per channel; STATUS stays
//                          set until written with 1 (write 0 keeps it)
//     test_clear           CLEAR zeroes only the channels written with 1
//     test_clear_collision An end of frame in the clock of a CLEAR counts
//                          (the count becomes 1) and one in the clock of a
//                          STATUS clear keeps STATUS set
//     test_random          2000 clocks of random pulses with random
//                          CLEAR, STATUS and IRQ_EN writes, checked against
//                          the model after every register access
//     pop_events           Reads and removes every logged event, comparing
//                          each with the model's log (channel, count, time)
//     test_time            TIME advances by one every TS_DIV clocks
//     test_event_order     Markers on every channel, apart and interleaved:
//                          logged in marker order with the channel's count
//                          and the timestamp of the marker; reading EVENT
//                          does not remove it, EVENT_POP does
//     test_event_same_clock Markers of several channels in one clock and a
//                          lower channel in the next clock: one timestamp,
//                          lowest channel first, the later marker after them
//     test_event_overflow  More markers than the log holds: the first EVQ
//                          kept in order, EVENT[30] set until EVENT_POP[1]
//     test_event_disabled  A channel not enabled in EV_EN is counted but not
//                          logged
// Date: 2026-10-11
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic compare(input string where);
    logic [31:0] v;
    repeat (2) @(posedge clk);
    for (int i = 0; i < NCH; i++) begin
      bfm.read(8'h20 + 4 * i, v);
      check(v == m_count[i], $sformatf("%s: COUNT%0d %0d, model %0d", where, i, v, m_count[i]));
    end
    bfm.read(8'h0C, v);
    check(v[NCH-1:0] == m_status, $sformatf("%s: STATUS %b, model %b", where, v[NCH-1:0], m_status));
    bfm.read(8'h08, v);
    check(v[NCH-1:0] == m_en, $sformatf("%s: IRQ_EN %b, model %b", where, v[NCH-1:0], m_en));
    check(irq_o == (m_status & m_en), $sformatf("%s: irq_o %b, expected %b", where, irq_o, m_status & m_en));
  endtask

  task automatic pulse(input logic [NCH-1:0] ch);
    @(negedge clk);
    eof_i = ch;
    @(negedge clk);
    eof_i = '0;
  endtask

  task automatic test_registers();
    logic [31:0] v;
    bfm.read(8'h14, v);
    check(v == 0, $sformatf("reset EVENT %h (empty log)", v));
    bfm.read(8'h44, v);
    check(v == 0, $sformatf("reset EV_EN %h", v));
    compare("reset");
    check(irq_o == '0, "irq_o not 0 after reset");
    $display("[%0t] test_registers: reset values", $time);
  endtask

  task automatic test_count();
    for (int i = 0; i < NCH; i++) repeat (i + 2) pulse(NCH'(1) << i);
    repeat (3) pulse('1);
    compare("counting");
    check(m_count[0] == 5 && m_count[1] == 6 && m_count[2] == 7, "model counts unexpected");
    $display("[%0t] test_count: %0d / %0d / %0d frames counted", $time, m_count[0], m_count[1], m_count[2]);
  endtask

  task automatic test_irq();
    bfm.write(8'h0C, '1);                            // clear STATUS
    bfm.write(8'h08, 3'b101);                        // IRQ_EN channels 0 and 2
    compare("irq enable");
    check(irq_o == '0, "irq_o set with STATUS clear");
    pulse(3'b111);
    compare("irq after end of frame");
    check(irq_o == 3'b101, $sformatf("irq_o %b, expected 101", irq_o));
    bfm.write(8'h0C, 3'b000);                        // writing 0 keeps STATUS
    compare("STATUS write 0");
    bfm.write(8'h0C, 3'b001);
    compare("STATUS write 1 to channel 0");
    check(irq_o == 3'b100, $sformatf("irq_o %b after clearing channel 0, expected 100", irq_o));
    bfm.write(8'h0C, '1);
    compare("STATUS cleared");
    $display("[%0t] test_irq: level interrupts, write 1 to clear", $time);
  endtask

  task automatic test_clear();
    pulse(3'b111);
    bfm.write(8'h10, 3'b010);
    compare("CLEAR channel 1");
    check(m_count[1] == 0 && m_count[0] != 0 && m_count[2] != 0, "CLEAR touched the wrong channels");
    bfm.write(8'h10, '1);
    compare("CLEAR all");
    $display("[%0t] test_clear: only the channels written with 1 are cleared", $time);
  endtask

  // a pulse exactly in the clock of the register write pulse
  task automatic test_clear_collision();
    pulse(3'b011);
    fork
      bfm.write(8'h10, 3'b001);
      begin
        do @(negedge clk); // the write pulse is high until the next edge
        while (!dut.u_core.clear);
        eof_i = 3'b001;
        @(negedge clk);
        eof_i = '0;
      end
    join
    compare("end of frame with CLEAR");
    check(m_count[0] == 1, $sformatf("count %0d after a clear with an end of frame, expected 1", m_count[0]));
    fork
      bfm.write(8'h0C, 3'b001);
      begin
        do @(negedge clk); // the write pulse is high until the next edge
        while (!(dut.u_regs.wr_en && dut.u_regs.wa == 8'h1C));
        eof_i = 3'b001;
        @(negedge clk);
        eof_i = '0;
      end
    join
    compare("end of frame with STATUS clear");
    check(m_status[0], "STATUS cleared although an end of frame came in the same clock");
    $display("[%0t] test_clear_collision: an end of frame wins over a clear in the same clock", $time);
  endtask

  task automatic test_random();
    for (int n = 0; n < 2000; n++) begin
      @(negedge clk);
      eof_i = NCH'($urandom) & NCH'($urandom);
      if ($urandom_range(19) == 0) begin
        case ($urandom_range(2))
          0: bfm.write(8'h10, $urandom);
          1: bfm.write(8'h0C, $urandom);
          default: bfm.write(8'h08, $urandom);
        endcase
        @(negedge clk);
        eof_i = '0;
        compare($sformatf("random step %0d", n));
      end
    end
    @(negedge clk);
    eof_i = '0;
    compare("random end");
    $display("[%0t] test_random: random pulses and register writes match the model", $time);
  endtask

  // every logged event, oldest first, against the model's log
  task automatic pop_events(input string where, input int expect_n);
    logic [31:0] v, t;
    int n = 0;
    repeat (4) @(posedge clk);
    bfm.read(8'h14, v);
    while (v[31]) begin
      bfm.read(8'h18, t);
      if (m_ev.size() == 0) check(0, $sformatf("%s: event %h not in the model", where, v));
      else begin
        check({5'd0, v[26:0]} == m_ev[0] && t == m_ev_t[0],
              $sformatf("%s: event %0d channel %0d count %0d time %0d, model channel %0d count %0d time %0d", where, n,
                        v[26:24], v[23:0], t, m_ev[0] >> 24, m_ev[0] & 24'hFFFFFF, m_ev_t[0]));
        void'(m_ev.pop_front());
        void'(m_ev_t.pop_front());
      end
      bfm.write(8'h1C, 1);
      n++;
      bfm.read(8'h14, v);
    end
    check(n == expect_n, $sformatf("%s: %0d events logged, %0d expected", where, n, expect_n));
    check(m_ev.size() == 0, $sformatf("%s: %0d model events not logged", where, m_ev.size()));
    m_ev.delete();
    m_ev_t.delete();
  endtask

  task automatic test_time();
    logic [31:0] t0, t1;
    realtime r0, r1;
    bfm.read(8'h40, t0);
    r0 = $realtime;
    repeat (300) @(posedge clk);
    bfm.read(8'h40, t1);
    r1 = $realtime;
    check(t1 - t0 >= 99 && t1 - t0 <= 101 + 2 * 10, $sformatf("TIME advanced %0d in about 300 clocks + 2 reads (TS_DIV %0d)", t1 - t0, TS_DIV));
    $display("[%0t] test_time: TIME advanced %0d ticks over %0t (TS_DIV = %0d)", $time, t1 - t0, r1 - r0, TS_DIV);
  endtask

  task automatic test_event_order();
    logic [31:0] v, v2;
    bfm.write(8'h10, '1);                            // counts from 0
    bfm.write(8'h44, '1);                            // log every channel
    repeat (2) @(posedge clk);
    pulse(3'b001);
    repeat (7) @(negedge clk);
    pulse(3'b100);
    repeat (4) @(negedge clk);
    pulse(3'b010);
    pulse(3'b001);
    repeat (11) @(negedge clk);
    pulse(3'b100);
    repeat (5) @(posedge clk);
    bfm.read(8'h14, v);
    bfm.read(8'h14, v2);
    check(v == v2 && v[31], "reading EVENT changed the log");
    pop_events("events in marker order", 5);
    $display("[%0t] test_event_order: 5 events logged in marker order with counts and times", $time);
  endtask

  task automatic test_event_same_clock();
    pulse(3'b110);                                   // channels 1 and 2 in one clock
    pulse(3'b001);                                   // channel 0 one clock later
    pulse(3'b111);                                   // all three in one clock
    pop_events("markers in one clock and the next", 6);
    $display("[%0t] test_event_same_clock: one timestamp, lowest channel first, later markers after", $time);
  endtask

  task automatic test_event_overflow();
    logic [31:0] v;
    for (int k = 0; k < EVQ + 3; k++) begin
      pulse(3'b001);
      repeat (2) @(negedge clk);
    end
    repeat (4) @(posedge clk);
    bfm.read(8'h14, v);
    check(v[31] && v[30], $sformatf("EVENT %h after %0d markers: valid and overflow expected", v, EVQ + 3));
    while (m_ev.size() > EVQ) begin                  // the last ones were lost
      void'(m_ev.pop_back());
      void'(m_ev_t.pop_back());
    end
    pop_events("full log", EVQ);
    bfm.read(8'h14, v);
    check(v[30], "overflow flag cleared by EVENT_POP[0]");
    bfm.write(8'h1C, 2);
    bfm.read(8'h14, v);
    check(v == 0, $sformatf("EVENT %h after EVENT_POP[1], expected empty and no overflow", v));
    $display("[%0t] test_event_overflow: %0d events kept in order, overflow flagged until cleared", $time, EVQ);
  endtask

  task automatic test_event_disabled();
    logic [31:0] c0;
    bfm.write(8'h44, 3'b101);                        // channel 1 not logged
    repeat (2) @(posedge clk);
    bfm.read(8'h24, c0);
    pulse(3'b010);
    pulse(3'b100);
    pulse(3'b010);
    pop_events("channel 1 not logged", 1);
    compare("channel 1 still counted");
    check(m_count[1] == c0 + 2, "channel 1 not counted while not logged");
    bfm.write(8'h44, 0);
    $display("[%0t] test_event_disabled: a channel not in EV_EN is counted but not logged", $time);
  endtask

  // ID block at the base address: ID, VERSION (ASCII "d.dd"), DATE (BCD mm/dd/yyyy), 0x0C reserved;
  // read only (writes ignored); the rest of the map starts at 0x10 (bfm.base)
  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "FCNT", $sformatf("ID %h (\"%s\"), expected \"FCNT\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:28] <= 1 && date[27:24] <= 9 && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[19:16] <= 9 && date[15:0] >= 16'h2000 &&
          date[15:12] <= 9 && date[11:8] <= 9 && date[7:4] <= 9 && date[3:0] <= 9,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
    bfm.read_abs(8'h4, v);
    check(v == ver, "VERSION changed by a write");
    bfm.read_abs(8'h8, v);
    check(v == date, "DATE changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask
