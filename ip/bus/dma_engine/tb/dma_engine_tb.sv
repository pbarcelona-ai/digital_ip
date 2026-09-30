// ***************
// Filename: dma_engine_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the memory to memory DMA
//   engine. An AXI4 memory model with random stalls serves as memory.
//   Tests copies that cross 4 KB boundaries and are not multiples of the
//   burst length, non-overlapping integrity of surrounding memory,
//   done/error flags with write-1-to-clear, error on an out-of-range
//   destination and rejection of an invalid length. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module dma_engine_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [31:0] awaddr, wdata, araddr, rdata; logic [7:0] awlen, arlen; logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp; logic awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready; logic [3:0] wstrb; logic irq;
  dma_engine #(.MAX_BURST(16), .FIFO_DEPTH(32)) dut (.aclk, .aresetn,
.s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid), .m_axi_bready(bready), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
    .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
    .m_axi_rready(rready), .irq_o(irq));
  axi4_mem_model #(.WORDS(4096), .STALL(30)) mem (.aclk, .aresetn, .awaddr, .awlen, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready, .bresp, .bvalid, .bready, .araddr, .arlen, .arvalid,
    .arready, .rdata, .rresp, .rlast, .rvalid, .rready);
  int errors = 0; logic [31:0] rd;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  task automatic run_dma(input [31:0] s, input [31:0] d, input [31:0] len);
    bfm.write(8'h04, s); bfm.write(8'h08, d); bfm.write(8'h0C, len);
    bfm.write(8'h10, 32'h300);                       // clear flags
    bfm.write(8'h00, 32'h3);                         // start + irq_en
    do bfm.read(8'h10, rd); while (rd[8] == 0 && rd[9] == 0);
  endtask
  task automatic verify(input [31:0] s, input [31:0] d, input int words, input string tag);
    for (int i = 0; i < words; i++)
      if (mem.mem[d/4 + i] !== mem.mem[s/4 + i]) begin
        errors++; $display("ERROR %s: word %0d dst %h src %h", tag, i, mem.mem[d/4+i], mem.mem[s/4+i]); i = words; end
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("dma_engine_tb.vcd"); $dumpvars(0, dma_engine_tb); end
    repeat (5) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    for (int i = 0; i < 4096; i++) mem.mem[i] = (i < 1024) ? $urandom : 32'hFFFF_FFFF;
    // ---- Test 1: small aligned copy (one burst) ----
    run_dma(32'h0000_0000, 32'h0000_2000, 32'd64);
    check(rd[8] == 1 && rd[9] == 0, $sformatf("test1 status %h", rd)); check(irq == 1, "irq");
    verify(32'h0, 32'h2000, 16, "t1");
    check(mem.mem[32'h2000/4 + 16] === 32'hFFFF_FFFF, "t1 overrun past end");
    // ---- Test 2: both source and destination cross 4 KB, length not a burst multiple ----
    run_dma(32'h0000_0F00, 32'h0000_2F40, 32'd768);
    check(rd[8] == 1 && rd[9] == 0, $sformatf("test2 status %h", rd));
    verify(32'h0F00, 32'h2F40, 192, "t2");
    check(mem.mem[32'h2F40/4 - 1] === 32'hFFFF_FFFF, "t2 underrun before dst");
    check(mem.mem[32'h2F40/4 + 192] === 32'hFFFF_FFFF, "t2 overrun after dst");
    // ---- Test 3: 17 words ----
    run_dma(32'h0000_0210, 32'h0000_2100, 32'd68);
    verify(32'h0210, 32'h2100, 17, "t3");
    check(mem.mem[32'h2100/4 + 17] === 32'hFFFF_FFFF, "t3 overrun");
    check(mem.max_awlen <= 15, $sformatf("burst longer than MAX_BURST (%0d)", mem.max_awlen));
    // ---- Test 4: destination beyond memory -> SLVERR -> error flag ----
    run_dma(32'h0000_0000, 32'h0000_3FF0, 32'd64);
    check(rd[9] == 1, $sformatf("test4 error flag %h", rd));
    // ---- Test 5: invalid length is rejected ----
    bfm.write(8'h10, 32'h300); bfm.write(8'h0C, 32'd6); bfm.write(8'h00, 32'h1);
    repeat (20) @(posedge aclk); bfm.read(8'h10, rd);
    check(rd[9] == 1 && rd[0] == 0 && rd[8] == 0, $sformatf("test5 status %h", rd));
    // flags W1C and irq drop
    bfm.write(8'h10, 32'h300); bfm.read(8'h10, rd); check(rd[9:8] == 0, "W1C");
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
