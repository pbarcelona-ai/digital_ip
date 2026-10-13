// ***************
// Filename: quadrature_decoder_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the quadrature_decoder_tb testbench
//   (quadrature_decoder_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     step   Encoder step
//     test_id_block  ID "QDEC", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                    0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                    offsets from bfm.base = 0x10, the map after the ID block)
//     test_setup     Enabled, filter 3 clocks, velocity window 400 clocks
//     test_forward   40 forward steps count up, direction 1
//     test_reverse   15 reverse steps count down, direction 0
//     test_glitch    A 1-clock glitch on A is filtered
//     test_illegal   A double transition sets ERROR and ERR_COUNT
//     test_index     Index edge latches INDEX_POS and (CTRL[2]) clears the position
//     test_load      A POSITION write loads the position
//     test_velocity  1 count per 20 clocks: about 20 counts per 400-clock window
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Encoder step (quad_bfm): forward 00 -> 10 -> 11 -> 01 -> 00 (A leads)
  task automatic step(input bit fwd, input int hold);
    enc.step(fwd, hold);
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "QDEC", $sformatf("ID %h (\"%s\"), expected \"QDEC\"", id, id));
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
    bfm.write(8'h00, 32'h0301);                    // en, filter = 3 clocks
    bfm.write(8'h0C, 32'd400);                     // velocity window 400 clocks
  endtask

  task automatic test_forward();
    // ---- Test 1: 40 forward steps ----
    repeat (40) step(1, 12);
    repeat (8) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 40, $sformatf("position %0d exp 40", $signed(rd)));
    bfm.read(8'h10, rd);
    check(rd[0] == 1, "direction forward");
  endtask

  task automatic test_reverse();
    // ---- Test 2: 15 reverse steps ----
    repeat (15) step(0, 12);
    repeat (8) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 25, $sformatf("position %0d exp 25", $signed(rd)));
    bfm.read(8'h10, rd);
    check(rd[0] == 0, "direction reverse");
  endtask

  task automatic test_glitch();
    // ---- Test 3: short glitch on A (1 clock) must be filtered ----
    enc.glitch_a(1);
    repeat (10) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 25, "glitch changed position");
  endtask

  task automatic test_illegal();
    // ---- Test 4: illegal jump (both bits change) ----
    enc.jump(2'b11, 10);
    bfm.read(8'h14, rd);
    check(rd == 0, $sformatf("unexpected errors %0d", rd));
    // 01 -> 10 double transition: 00 first
    step(1, 12); // st 3, 0  (00)
    step(1, 12);
    enc.jump(2'b11, 10);
    bfm.read(8'h14, rd);
    check(rd == 1, $sformatf("error count %0d exp 1", rd));
    bfm.read(8'h10, rd);
    check(rd[1] == 1, "error flag");
    bfm.write(8'h10, 32'h2);
    bfm.read(8'h10, rd);
    check(rd[1] == 0, "error W1C");
  endtask

  task automatic test_index();
    // ---- Test 5: index latch and clear ----
    bfm.read(8'h04, rd);
    begin
      logic [31:0] p0;
      p0 = rd;
      enc.index(10);
      bfm.read(8'h18, rd);
      check(rd == p0, $sformatf("index pos %0d vs %0d", $signed(rd), $signed(p0)));
    end
    bfm.read(8'h10, rd);
    check(rd[2] == 1, "index flag");
    bfm.write(8'h00, 32'h0305);                        // index clears position
    enc.index(10);
    repeat (5) @(posedge aclk);
    bfm.read(8'h04, rd);
    check(rd == 0, "position not cleared by index");
  endtask

  task automatic test_load();
    // ---- Test 6: position load ----
    bfm.write(8'h04, 32'd1000);
    repeat (2) @(posedge aclk);
    bfm.read(8'h04, rd);
    check(rd == 1000, "position load");
  endtask

  task automatic test_velocity();
    // ---- Test 7: velocity samples: 1 count per 20 clocks -> ~20 counts / 400 ----
    vel_samples.delete();
    repeat (100) step(1, 20);
    check(vel_samples.size() >= 4, "no velocity samples");
    begin
      int mx;
      mx = 0;
      foreach (vel_samples[i]) if (vel_samples[i] > mx) mx = vel_samples[i];
      check(mx >= 19 && mx <= 21, $sformatf("velocity max %0d exp ~20", mx));
    end
  endtask
