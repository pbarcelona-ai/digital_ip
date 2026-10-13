// ***************
// Filename: watchdog_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the watchdog_tb testbench (watchdog_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     test_id_block  ID "WDOG", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                    0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                    offsets from bfm.base = 0x10, the map after the ID block)
//     test_setup     TIMEOUT 100 ticks of 4 clocks, pre-timeout at 60, enabled
//     test_kicks     Regular kicks keep it alive
//     test_timeout   Pre-timeout interrupt, then the timeout reset (stretched
//                    pulse); STATUS write 1 to clear
//     test_bad_key   A kick with a wrong key is ignored and flagged
//     test_window    Window mode: a kick before WINDOW_OPEN resets, one after
//                    it is accepted
//     test_lock      LOCK keeps the watchdog enabled
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
    check(id == "WDOG", $sformatf("ID %h (\"%s\"), expected \"WDOG\"", id, id));
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
    bfm.write(8'h04, 100); // 100 ticks of 4 clocks = 400 clocks
    bfm.write(8'h08, 3);
    bfm.write(8'h0C, 60);                            // pre-timeout at 60 ticks
    bfm.write(8'h00, 32'h1);
  endtask

  task automatic test_kicks();
    // ---- Test 1: regular kicks keep it alive ----
    repeat (5) begin
      repeat (250) @(posedge aclk);
      bfm.write(8'h14, 32'h5AFE_C0DE);
    end
    check(rst_events == 0, "reset while being kicked");
  endtask

  task automatic test_timeout();
    // ---- Test 2: pre-timeout then timeout ----
    repeat (260) @(posedge aclk);
    check(irq == 1, "pre-timeout irq missing");
    bfm.read(8'h18, rd);
    check(rd[0] == 1, "pre status");
    repeat (200) @(posedge aclk);
    check(rst_events == 1, $sformatf("timeout reset count %0d", rst_events));
    rst_len = 0;
    while (wdt_rst) begin
      @(posedge aclk);
      rst_len++;
    end
    bfm.read(8'h18, rd);
    check(rd[1] == 1, "expired status");
    bfm.write(8'h18, 32'h3);
    bfm.read(8'h18, rd);
    check(rd[1:0] == 0, "W1C");
  endtask

  task automatic test_bad_key();
    // ---- Test 3: wrong key ignored and flagged ----
    bfm.write(8'h14, 32'h1234_5678);
    bfm.read(8'h18, rd);
    check(rd[3] == 1, "bad key flag");
    bfm.write(8'h18, 32'h8);
  endtask

  task automatic test_window();
    // ---- Test 4: window mode: kick before WINDOW_OPEN resets ----
    bfm.write(8'h14, 32'h5AFE_C0DE);
    bfm.write(8'h10, 50); // window enabled
    bfm.write(8'h00, 32'h3);
    rst_events = 0;
    repeat (40) @(posedge aclk);                     // count ~ 10 < 50
    bfm.write(8'h14, 32'h5AFE_C0DE);
    repeat (5) @(posedge aclk);
    check(rst_events == 1, "early kick should reset");
    bfm.read(8'h18, rd);
    check(rd[2] == 1, "early flag");
    bfm.write(8'h18, 32'h4);
    while (wdt_rst) @(posedge aclk);
    // in-window kick accepted
    repeat (300) @(posedge aclk);                    // count ~ 75 > 50
    bfm.write(8'h14, 32'h5AFE_C0DE);
    repeat (5) @(posedge aclk);
    check(rst_events == 1, "in-window kick must not reset");
  endtask

  task automatic test_lock();
    // ---- Test 5: lock ----
    bfm.write(8'h00, 32'h5);                         // en + lock (window off)
    bfm.write(8'h00, 32'h0);                         // try to disable
    bfm.read(8'h00, rd);
    check(rd[0] == 1 && rd[2] == 1, "lock did not hold enable");
  endtask
