// ***************
// Filename: axi4_lite_slave_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axi4_lite_slave. A behavioral
//   register array sits behind the user interface. Tests write/read with
//   byte strobes, address-before-data and data-before-address ordering,
//   user SLVERR on write and read, DECERR for an unmapped address,
//   READ_WAIT mode with a delayed read data valid, and back-to-back random
//   accesses checked against a model. Prints TEST PASSED on success.
//   The test tasks are in tests/axi4_lite_slave_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_lite_slave_tb;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  logic [7:0] s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic wr_en, rd_en, wr_err = 0, rd_err = 0, rd_valid = 0;
  logic [7:0] wa, ra;
  logic [31:0] wd, rdd;
  logic [3:0] ws;
  axi4_lite_slave #(
    .ADDR_W(8),
    .READ_WAIT(1),
    .MAP_WORDS(16)
  ) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .wr_en_o(wr_en),
    .wr_addr_o(wa),
    .wr_data_o(wd),
    .wr_strb_o(ws),
    .wr_err_i(wr_err),
    .rd_en_o(rd_en),
    .rd_addr_o(ra),
    .rd_data_i(rdd),
    .rd_valid_i(rd_valid),
    .rd_err_i(rd_err)
  );
  logic [31:0] regs [0:15];
  int errors = 0;
  int rd_delay = 2;
  int pend = 0;
  always @(posedge aclk) begin
    if (wr_en) for (int b = 0; b < 4; b++) if (ws[b]) regs[wa[5:2]][b*8 +: 8] <= wd[b*8 +: 8];
    wr_err <= wr_en && (wa == 8'h3C);                    // last register write returns an error
    rd_valid <= 0;
    if (pend != 0) begin
      pend <= pend - 1;
      if (pend == 1) rd_valid <= 1;
    end
    if (rd_en) begin
      rdd <= regs[ra[5:2]];
      rd_err <= (ra == 8'h3C);
      pend <= rd_delay;
    end
  end
  // test tasks: tests/axi4_lite_slave_tests.sv
  `include "axi4_lite_slave_tests.sv"
  logic [31:0] rd;
  logic [31:0] model [0:15];
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi4_lite_slave_tb.vcd");
      $dumpvars(0, axi4_lite_slave_tb);
    end
    for (int i = 0; i < 16; i++) begin
      regs[i] = 0;
      model[i] = 0;
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    for (int i = 0; i < 15; i++) begin
      bfm.write(i*4, 32'h1000_0000 * (i % 4) + i * 37);
      model[i] = 32'h1000_0000 * (i % 4) + i * 37;
      check(bfm.last_resp == 0, "write resp");
    end
    for (int i = 0; i < 15; i++) begin
      bfm.read(i*4, rd);
      check(rd == model[i] && bfm.last_resp == 0, $sformatf("reg %0d got %h", i, rd));
    end
    bfm.write_strb(8'h08, 32'hFFFFFFFF, 4'b0011);
    model[2][15:0] = 16'hFFFF;
    bfm.read(8'h08, rd);
    check(rd == model[2], "strobes");
    // user error responses
    bfm.write(8'h3C, 32'h1);
    check(bfm.last_resp == 2'b10, $sformatf("write SLVERR got %b", bfm.last_resp));
    bfm.read(8'h3C, rd);
    check(bfm.last_resp == 2'b10, "read SLVERR");
    // decode errors
    bfm.write(8'h40, 32'h1);
    check(bfm.last_resp == 2'b11, "write DECERR");
    bfm.read(8'h44, rd);
    check(bfm.last_resp == 2'b11, "read DECERR");
    // slow read data
    rd_delay = 9;
    bfm.read(8'h04, rd);
    check(rd == model[1] && bfm.last_resp == 0, "slow read");
    rd_delay = 1;
    // data before address
    bfm.write_skew(8'h10, 32'hCAFE0001, 6, 0);
    bfm.read(8'h10, rd);
    check(rd == 32'hCAFE0001, "data-before-address write");
    bfm.write_skew(8'h14, 32'hCAFE0002, 0, 6);
    bfm.read(8'h14, rd);
    check(rd == 32'hCAFE0002, "address-before-data write");
    model[4] = 32'hCAFE0001;
    model[5] = 32'hCAFE0002;
    // random soak
    for (int n = 0; n < 300; n++) begin
      int r;
      r = $urandom_range(0, 14);
      if ($urandom_range(0, 1)) begin
        model[r] = $urandom;
        bfm.write(r * 4, model[r]);
      end
      else begin
        bfm.read(r * 4, rd);
        check(rd == model[r], $sformatf("soak reg %0d", r));
      end
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
