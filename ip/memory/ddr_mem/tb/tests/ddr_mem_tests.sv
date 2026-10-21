// ***************
// Filename: ddr_mem_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the ddr_mem_tb testbench (ddr_mem_tb.sv),
//   `included into that module, so they use its signals and parameters
//   directly. Tasks, in file order:
//     check                  Counts an error and prints the message when the
//                            condition is false
//     reset                  Resets the memory state (the contents stay)
//     issue                  Presents one command for one clock
//     idle                   Presents NOP for n clocks
//     read_check             RD, then checks the word T_CL clocks later
//     test_write_read        Writes and reads back over two banks and rows,
//                            partial strobes, unwritten words read 0
//     test_timing_checks     Each of tRCD, tRP, tRAS, tWR, tRFC and a closed
//                            bank sets err_o with its code
//     test_refresh_deadline  No REF for REF_MAX clocks sets code 11
// Date: 2026-10-21
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic reset();
    @(negedge clk);
    rst_n = 0;
    cmd = 0;
    @(negedge clk);
    rst_n = 1;
  endtask

  task automatic issue(input logic [2:0] c, input int b = 0, input int r = 0, input int cl = 0,
                       input logic [DW-1:0] d = '0, input logic [3:0] s = 4'hF);
    @(negedge clk);
    cmd = c;
    bank = BW'(b);
    row = RW'(r);
    col = CW'(cl);
    wrdata = d;
    wrstrb = s;
    @(negedge clk);
    cmd = 0;
  endtask

  task automatic idle(input int n);
    repeat (n) @(negedge clk);
  endtask

  task automatic read_check(input int b, input int cl, input logic [DW-1:0] exp, input string m);
    @(negedge clk);
    cmd = 3'd2;
    bank = BW'(b);
    col = CW'(cl);
    @(negedge clk);
    cmd = 0;
    repeat (T_CL - 1) @(negedge clk);           // the word is valid in clock RD + T_CL
    check(rv === 1'b1 && rd === exp, $sformatf("%s: read %h valid %b, expected %h", m, rd, rv, exp));
  endtask

  task automatic test_write_read();
    reset();
    issue(3'd1, 1, 5);                          // ACT bank 1 row 5
    idle(T_RCD);
    issue(3'd3, 1, 0, 2, 32'hDEADBEEF);         // WR col 2
    issue(3'd3, 1, 0, 3, 32'h11223344);
    issue(3'd3, 1, 0, 3, 32'hAABBCCDD, 4'b0101);   // partial: bytes 0 and 2
    idle(2);
    read_check(1, 2, 32'hDEADBEEF, "full word");
    read_check(1, 3, 32'h11BB33DD, "partial strobes");
    read_check(1, 4, 32'h0, "unwritten word");
    idle(T_RAS + T_WR);
    issue(3'd4, 1);                             // PRE bank 1
    idle(T_RP);
    issue(3'd1, 1, 6);                          // another row: its words are separate
    idle(T_RCD);
    read_check(1, 2, 32'h0, "other row");
    issue(3'd1, 2, 5);                          // bank 2, same row number: separate words
    idle(T_RCD);
    read_check(2, 2, 32'h0, "other bank");
    check(!err, $sformatf("no violation expected, err_code %0d", code));
  endtask

  task automatic expect_code(input int c, input string m);
    @(negedge clk);
    check(err === 1'b1 && code === 4'(c), $sformatf("%s: err %b code %0d, expected %0d", m, err, code, c));
    reset();
  endtask

  task automatic test_timing_checks();
    reset();
    issue(3'd2, 0, 0, 0);                       // RD to a closed bank
    expect_code(2, "closed bank");
    issue(3'd1, 0, 1);
    issue(3'd2, 0, 0, 0);                       // RD the clock after ACT
    expect_code(3, "tRCD");
    issue(3'd1, 0, 1);
    idle(T_RAS);
    issue(3'd4, 0);
    issue(3'd1, 0, 1);                          // ACT the clock after PRE
    expect_code(4, "tRP");
    issue(3'd1, 0, 1);
    issue(3'd4, 0);                             // PRE the clock after ACT
    expect_code(5, "tRAS");
    issue(3'd1, 0, 1);
    idle(T_RAS);
    issue(3'd3, 0, 0, 0, 32'h1);
    issue(3'd4, 0);                             // PRE the clock after WR
    expect_code(6, "tWR");
    issue(3'd6);
    issue(3'd1, 0, 1);                          // ACT the clock after REF
    expect_code(10, "tRFC");
    issue(3'd1, 0, 1);
    idle(T_RAS);
    issue(3'd6);                                // REF with a bank open
    expect_code(9, "REF with an open bank");
    issue(3'd7);
    expect_code(13, "illegal command");
  endtask

  task automatic test_refresh_deadline();
    reset();
    idle(REF_MAX - 5);
    check(!err, "deadline flagged early");
    issue(3'd6);                                // a REF in time
    idle(REF_MAX - 5);
    check(!err, "deadline not restarted by REF");
    idle(10);
    check(err === 1'b1 && code === 4'd11, $sformatf("deadline: err %b code %0d", err, code));
  endtask
