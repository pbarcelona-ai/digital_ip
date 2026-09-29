// ***************
// Filename: tb_frame_buffer.sv
// Author: Paul Barcelona
// Description: Self-checking standalone testbench for frame_buffer.
// Verifies write-then-readback, four-way port replication
// consistency, one-cycle read latency, and concurrent
// write(A)/read(B) independence.
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_frame_buffer.sv
//
// Self-checking testbench for frame_buffer.sv (reusable IP). Depends only
// on barrel_pkg.sv for its default PIX_W/DEPTH/ADDR_W parameter values
// (all overridable -- this instance uses a small DEPTH override so the
// test runs quickly rather than allocating the full MAX_W*MAX_H banks).
//
// Checks:
//   1. Write-then-read-back: every address in a small range gets a
//      unique pixel value written, then all four read ports are checked
//      against an independent shadow model for every address.
//   2. All four read ports return the SAME data for the SAME address in
//      the same cycle (proves the four-way replication -- the whole
//      point of this module -- actually works, not just that one port
//      does).
//   3. Read latency is exactly 1 cycle (rd_en asserted with an address,
//      data appears the following cycle, not the same cycle).
//   4. Simultaneous write (address A) and read (of a DIFFERENT address B)
//      in the same cycle: the read must return B's *old* value, not be
//      disturbed by the concurrent write to A.
//
// A note on testbench authoring (not an RTL bug -- frame_buffer.sv itself
// was correct throughout): the first version of this testbench drove
// wr_en/wr_addr/wr_data with BLOCKING assignment immediately after
// @(posedge clk), which races against frame_buffer's own always_ff
// (triggered by the same edge) -- Icarus resolved that race by losing
// every other write. Switching to non-blocking (<=) for every DUT input,
// matching the convention the rest of this project already uses, fixed
// it. That surfaced a second, subtler issue: reading a DUT output
// (rd_data*) in the "active" region immediately after waking from
// @(posedge clk) sees the PRE-edge value, because the DUT's own NBA
// update for that same edge hasn't committed yet -- a small `#1;` settle
// delay before each check resolves it (the same pattern the read-latency
// check below already relied on).
// =============================================================================
`timescale 1ns/1ps
import barrel_pkg::*;

module tb_frame_buffer;
  localparam int PIX_W  = 24;
  localparam int DEPTH  = 256;
  localparam int ADDR_W = $clog2(DEPTH);

  logic clk = 0;
  logic wr_en;
  logic [ADDR_W-1:0] wr_addr;
  logic [PIX_W-1:0]  wr_data;
  logic rd_en;
  logic [ADDR_W-1:0] rd_addr0, rd_addr1, rd_addr2, rd_addr3;
  logic [PIX_W-1:0]  rd_data0, rd_data1, rd_data2, rd_data3;

  frame_buffer #(.PIX_W(PIX_W), .DEPTH(DEPTH), .ADDR_W(ADDR_W)) dut (
    .clk, .wr_en, .wr_addr, .wr_data,
    .rd_en, .rd_addr0, .rd_addr1, .rd_addr2, .rd_addr3,
    .rd_data0, .rd_data1, .rd_data2, .rd_data3
  );

  always #5 clk = ~clk;

  logic [PIX_W-1:0] shadow [0:DEPTH-1];
  int checks, fails;

  initial begin
    checks = 0; fails = 0;
    wr_en <= 0; rd_en <= 0; wr_addr <= '0; wr_data <= '0;
    rd_addr0 <= '0; rd_addr1 <= '0; rd_addr2 <= '0; rd_addr3 <= '0;

    // ---- 1. write a unique pattern to every address ---------------------
    for (int a = 0; a < DEPTH; a++) begin
      logic [PIX_W-1:0] val;
      val = (a * 24'h010203 + 24'h00A5A5) & 24'hFFFFFF;
      @(posedge clk);
      wr_en <= 1;
      wr_addr <= a[ADDR_W-1:0];
      wr_data <= val;
      shadow[a] = val;
    end
    @(posedge clk);
    wr_en <= 0;

    // ---- 2. read back every address on all 4 ports simultaneously,
    //         each port given a DIFFERENT address per cycle to also prove
    //         genuine per-port independence, not just "port 0 works" ----
    for (int a = 0; a < DEPTH - 3; a++) begin
      @(posedge clk);
      rd_en <= 1;
      rd_addr0 <= a[ADDR_W-1:0];
      rd_addr1 <= ADDR_W'(a+1);
      rd_addr2 <= ADDR_W'(a+2);
      rd_addr3 <= ADDR_W'(a+3);
      @(posedge clk);   // 1-cycle read latency
      #1;               // let rd_data*'s own NBA update (from THIS edge) settle
                         // before we read it, or we'd see the PRE-edge (stale)
                         // value -- same subtlety the read-latency check below
                         // already relies on.
      rd_en <= 0;
      checks = checks + 4;
      if (rd_data0 !== shadow[a]) begin
        $display("FAIL port0: addr=%0d got=0x%06h expected=0x%06h", a, rd_data0, shadow[a]);
        fails = fails + 1;
      end
      if (rd_data1 !== shadow[a+1]) begin
        $display("FAIL port1: addr=%0d got=0x%06h expected=0x%06h", a+1, rd_data1, shadow[a+1]);
        fails = fails + 1;
      end
      if (rd_data2 !== shadow[a+2]) begin
        $display("FAIL port2: addr=%0d got=0x%06h expected=0x%06h", a+2, rd_data2, shadow[a+2]);
        fails = fails + 1;
      end
      if (rd_data3 !== shadow[a+3]) begin
        $display("FAIL port3: addr=%0d got=0x%06h expected=0x%06h", a+3, rd_data3, shadow[a+3]);
        fails = fails + 1;
      end
    end
    $display("[write-then-readback, 4 independent ports] %0d checks, %0d fails so far", checks, fails);

    // ---- 3. all 4 ports return IDENTICAL data for the SAME address ------
    @(posedge clk);
    rd_en <= 1;
    rd_addr0 <= 10; rd_addr1 <= 10; rd_addr2 <= 10; rd_addr3 <= 10;
    @(posedge clk);
    rd_en <= 0;
    #1;
    checks = checks + 1;
    if (!(rd_data0 === rd_data1 && rd_data1 === rd_data2 && rd_data2 === rd_data3
          && rd_data0 === shadow[10])) begin
      $display("FAIL same-address-4-ports: %0h %0h %0h %0h (expected all = 0x%06h)",
                 rd_data0, rd_data1, rd_data2, rd_data3, shadow[10]);
      fails = fails + 1;
    end else begin
      $display("[same-address-4-ports] PASS: all four ports = 0x%06h", rd_data0);
    end

    // ---- 4. read latency is exactly 1 cycle (not 0, not 2) --------------
    @(posedge clk);
    rd_en <= 1; rd_addr0 <= 20;
    // Same-cycle check: data should NOT have updated yet (still holds
    // whatever was there before this read was issued).
    #1;
    checks = checks + 1;
    if (rd_data0 === shadow[20]) begin
      $display("FAIL latency: rd_data0 updated in the SAME cycle the read was issued (expected 1-cycle registered latency)");
      fails = fails + 1;
    end else begin
      $display("[read-latency same-cycle-still-stale] PASS");
    end
    @(posedge clk);
    rd_en <= 0;
    #1;
    checks = checks + 1;
    if (rd_data0 !== shadow[20]) begin
      $display("FAIL latency: rd_data0 did not update by the cycle AFTER the read (got 0x%06h, expected 0x%06h)",
                 rd_data0, shadow[20]);
      fails = fails + 1;
    end else begin
      $display("[read-latency next-cycle-correct] PASS");
    end

    // ---- 5. simultaneous write(A) + read(B != A): read(B) unaffected ----
    shadow[30] = 24'hABCDEF;
    @(posedge clk);
    wr_en <= 1; wr_addr <= 30; wr_data <= 24'hABCDEF;
    rd_en <= 1; rd_addr0 <= 31;   // different address, pre-existing value from step 1
    @(posedge clk);
    wr_en <= 0; rd_en <= 0;
    #1;
    checks = checks + 1;
    if (rd_data0 !== shadow[31]) begin
      $display("FAIL concurrent write(30)/read(31): rd_data0=0x%06h expected=0x%06h (read of a different address got disturbed by the concurrent write)", rd_data0, shadow[31]);
      fails = fails + 1;
    end else begin
      $display("[concurrent write(A)/read(B!=A) independence] PASS");
    end
    // and confirm the write to 30 actually landed
    @(posedge clk);
    rd_en <= 1; rd_addr0 <= 30;
    @(posedge clk);
    rd_en <= 0;
    #1;
    checks = checks + 1;
    if (rd_data0 !== 24'hABCDEF) begin
      $display("FAIL: write to addr 30 did not land (got 0x%06h)", rd_data0);
      fails = fails + 1;
    end else begin
      $display("[concurrent write actually landed] PASS");
    end

    $display("=== frame_buffer self-check: %0d/%0d checks passed ===", checks - fails, checks);
    if (fails == 0) $display(">>> PASS <<<");
    else             $display(">>> FAIL (%0d mismatches) <<<", fails);
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_frame_buffer);
  end
`endif
endmodule
