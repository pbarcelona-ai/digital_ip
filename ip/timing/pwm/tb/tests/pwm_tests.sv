// ***************
// Filename: pwm_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the pwm_tb testbench (pwm_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     check    Counts an error and prints the message when the condition is
//              false
//     measure  Measure high count of channel ch and period length over one
//              full period
//     test_id_block       ID "PWMT", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                         0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                         offsets from bfm.base = 0x10, the map after the ID block)
//     test_setup          Period 100 clocks, duties 25 / 50 / 75 / 10, enabled
//     test_edge_aligned   Edge aligned period and duty per channel; pwm_n is
//                         the inverse without complementary mode
//     test_duty_update    A duty change takes effect at the period boundary
//     test_invert         INVERT flips a channel
//     test_prescale       PRESCALE 3: period 400 clocks
//     test_center         Centre aligned: period 2 x 99, high 2 x duty
//     test_complementary  Complementary outputs with dead time 5 never overlap
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Measure high count of channel ch and period length over one full period
  task automatic measure(input int ch);
    @(posedge pp);
    #1;
    hi_cnt = 0;
    per_cnt = 0;
    do begin
      @(posedge aclk);
      #1;
      per_cnt++;
      hi_cnt += pwm[ch];
    end
    while (!pp);
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "PWMT", $sformatf("ID %h (\"%s\"), expected \"PWMT\"", id, id));
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
    bfm.write(8'h04, 99);                    // period 100 clocks
    bfm.write(8'h14, 25);
    bfm.write(8'h18, 50);
    bfm.write(8'h1C, 75);
    bfm.write(8'h20, 10);
    bfm.write(8'h00, 32'h1);
  endtask

  task automatic test_edge_aligned();
    // ---- Test 1: edge aligned duty ----
    measure(0);
    measure(0);
    check(per_cnt == 100 && hi_cnt == 25, $sformatf("ch0 period %0d duty %0d", per_cnt, hi_cnt));
    measure(1);
    check(hi_cnt == 50, $sformatf("ch1 duty %0d", hi_cnt));
    measure(2);
    check(hi_cnt == 75, $sformatf("ch2 duty %0d", hi_cnt));
    check(pwm_n == ~pwm, "non-complementary mode: pwm_n is inverse");
  endtask

  task automatic test_duty_update();
    // ---- Test 2: duty update takes effect at the period boundary ----
    @(posedge pp);
    repeat (10) @(posedge aclk);
    bfm.write(8'h14, 60);
    measure(0);                               // remainder of the current period
    measure(0);
    check(hi_cnt == 60, $sformatf("updated duty %0d", hi_cnt));
  endtask

  task automatic test_invert();
    // ---- Test 3: inversion ----
    bfm.write(8'h10, 32'h1);
    measure(0);
    measure(0);
    check(hi_cnt == 40, $sformatf("inverted duty %0d", hi_cnt));
    bfm.write(8'h10, 32'h0);
  endtask

  task automatic test_prescale();
    // ---- Test 4: prescaler /4 -> period 400 ----
    bfm.write(8'h08, 3);
    measure(0);
    measure(0);
    check(per_cnt == 400 && hi_cnt == 240, $sformatf("presc period %0d duty %0d", per_cnt, hi_cnt));
    bfm.write(8'h08, 0);
  endtask

  task automatic test_center();
    // ---- Test 5: center aligned: period 2*99, high = 2*duty ----
    bfm.write(8'h00, 32'h3);
    bfm.write(8'h14, 20);
    measure(0);
    measure(0);
    check(per_cnt >= 197 && per_cnt <= 200, $sformatf("center period %0d", per_cnt));
    check(hi_cnt >= 38 && hi_cnt <= 41, $sformatf("center duty %0d", hi_cnt));
  endtask

  task automatic test_complementary();
    // ---- Test 6: complementary with dead time 5 on channel 3 ----
    bfm.write(8'h00, 32'h1 | 32'h4);
    bfm.write(8'h0C, 5);
    bfm.write(8'h04, 99);
    bfm.write(8'h20, 40);
    begin
      int idle_run, max_gap, saw_gap;
      idle_run = 0;
      max_gap = 0;
      saw_gap = 0;
      repeat (3) @(posedge pp);
      repeat (300) begin
        @(posedge aclk);
        if (!pwm[3] && !pwm_n[3]) begin idle_run++; end
        else begin
          if (idle_run > 0) begin
            saw_gap++;
            if (idle_run > max_gap) max_gap = idle_run;
          end
          idle_run = 0;
        end
      end
      check(both_high == 0, "complementary outputs overlapped");
      check(saw_gap >= 4 && max_gap >= 5 && max_gap <= 7, $sformatf("dead gap %0d (%0d gaps)", max_gap, saw_gap));
    end
  endtask
