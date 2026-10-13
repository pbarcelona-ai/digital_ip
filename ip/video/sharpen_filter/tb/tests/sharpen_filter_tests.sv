// ***************
// Filename: sharpen_filter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the sharpen_filter_tb testbench
//   (sharpen_filter_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     test_id_block        ID "SHRF", VERSION ("d.dd") and DATE (BCD
//                          mm/dd/yyyy) at the base address, read only
//                          (SLVERR); the rest of the map from 0x10
//     check      Counts an error and prints the message when the condition is
//                false
//     wr         Register write over the bus
//     rd         Register read over the bus
//     run_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic wr(input int a, input int d);
    bfm.write(8'(a), 32'(d));
  endtask

  task automatic rd(input int a, output logic [31:0] d);
    bfm.read(8'(a), d);
  endtask

  task automatic run_frame(input string what);
    int f0, bad;
    f0 = vid.frames;
    vid.ow = W;
    vid.oh = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [23:0] p; // edges to blur / sharpen
      p = ((x / 3 + y / 2) % 2) ? 24'hF0E0D0 : 24'h102030;
      if ($urandom_range(4) == 0) p = $urandom;
      vid.img[y][x] = p;
      mdl.img[y][x] = p;
    end
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    mdl.run(W, H);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask

  // ID block at the base address: ID, VERSION (ASCII "d.dd"), DATE (BCD mm/dd/yyyy), 0x0C reserved;
  // read only (writes ignored); the rest of the map starts at 0x10 (bfm.base)
  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "SHRF", $sformatf("ID %h (\"%s\"), expected \"SHRF\"", id, id));
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
