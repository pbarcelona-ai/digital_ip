// ***************
// Filename: axil_bfm.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite bus functional model (master) for testbenches.
//   Port names match the s_axil_* ports of every IP so it connects with a
//   .* port list. Provides blocking write() and read() tasks that are
//   called hierarchically, plus an error counter for non-OKAY responses.
//   Address width is a parameter.
// Date: 2026-09-29
`timescale 1ns/1ps
module axil_bfm #(
  parameter int ADDR_W = 8
) (
  input  logic              aclk,
  output logic [ADDR_W-1:0] s_axil_awaddr,
  output logic              s_axil_awvalid,
  input  logic              s_axil_awready,
  output logic [31:0]       s_axil_wdata,
  output logic [3:0]        s_axil_wstrb,
  output logic              s_axil_wvalid,
  input  logic              s_axil_wready,
  input  logic [1:0]        s_axil_bresp,
  input  logic              s_axil_bvalid,
  output logic              s_axil_bready,
  output logic [ADDR_W-1:0] s_axil_araddr,
  output logic              s_axil_arvalid,
  input  logic              s_axil_arready,
  input  logic [31:0]       s_axil_rdata,
  input  logic [1:0]        s_axil_rresp,
  input  logic              s_axil_rvalid,
  output logic              s_axil_rready
);
  int  resp_errors = 0;          // count of non-OKAY responses
  logic [1:0] last_resp;         // response of the last transaction
  int  bready_delay = 0;         // clocks BREADY stays low after BVALID (backpressure tests; 0 = ready at once)
  int  rready_delay = 0;         // clocks RREADY stays low after RVALID

  initial begin
    s_axil_awaddr = '0;
    s_axil_awvalid = 0;
    s_axil_wdata = '0;
    s_axil_wstrb = 4'hF;
    s_axil_wvalid = 0;
    s_axil_bready = 0;
    s_axil_araddr = '0;
    s_axil_arvalid = 0;
    s_axil_rready = 0;
  end

  // Blocking register write with byte strobes
  task automatic write_strb(input [ADDR_W-1:0] a, input [31:0] d, input [3:0] s);
    @(posedge aclk);
    #1;
    s_axil_awaddr = a;
    s_axil_awvalid = 1;
    s_axil_wdata = d;
    s_axil_wstrb = s;
    s_axil_wvalid = 1;
    s_axil_bready = (bready_delay == 0);
    fork
      begin
        wait (s_axil_awready);
        @(posedge aclk);
        #1 s_axil_awvalid = 0;
      end
      begin
        wait (s_axil_wready);
        @(posedge aclk);
        #1 s_axil_wvalid = 0;
      end
    join
    wait (s_axil_bvalid);
    if (bready_delay > 0) begin
      repeat (bready_delay) @(posedge aclk);
      #1 s_axil_bready = 1;
    end
    last_resp = s_axil_bresp;
    if (s_axil_bresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil_bready = 0;
  endtask
  task automatic write(input [ADDR_W-1:0] a, input [31:0] d);
    write_strb(a, d, 4'hF);
  endtask

  // Write with independent delays (clocks) before presenting AW and W, to test channel ordering
  task automatic write_skew(input [ADDR_W-1:0] a, input [31:0] d, input int aw_delay, input int w_delay);
    @(posedge aclk);
    #1;
    s_axil_bready = (bready_delay == 0);
    s_axil_wstrb = 4'hF;
    fork
      begin
        repeat (aw_delay) @(posedge aclk);
        #1 s_axil_awaddr = a;
        s_axil_awvalid = 1;
        wait (s_axil_awready);
        @(posedge aclk);
        #1 s_axil_awvalid = 0;
      end
      begin
        repeat (w_delay) @(posedge aclk);
        #1 s_axil_wdata = d;
        s_axil_wvalid = 1;
        wait (s_axil_wready);
        @(posedge aclk);
        #1 s_axil_wvalid = 0;
      end
    join
    wait (s_axil_bvalid);
    if (bready_delay > 0) begin
      repeat (bready_delay) @(posedge aclk);
      #1 s_axil_bready = 1;
    end
    last_resp = s_axil_bresp;
    if (s_axil_bresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil_bready = 0;
  endtask

  // Blocking register read
  task automatic read(input [ADDR_W-1:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    s_axil_araddr = a;
    s_axil_arvalid = 1;
    s_axil_rready = (rready_delay == 0);
    wait (s_axil_arready);
    @(posedge aclk);
    #1 s_axil_arvalid = 0;
    wait (s_axil_rvalid);
    if (rready_delay > 0) begin
      repeat (rready_delay) @(posedge aclk);
      #1 s_axil_rready = 1;
    end
    d = s_axil_rdata;
    last_resp = s_axil_rresp;
    if (s_axil_rresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil_rready = 0;
  endtask
endmodule
