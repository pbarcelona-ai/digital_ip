// ***************
// Filename: axil_bfm.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite bus functional model (master) for testbenches.
//   Port names match the s_axil_* ports of every IP so it connects with a
//   .* port list. Provides blocking write() and read() tasks that are
//   called hierarchically, plus an error counter for non-OKAY responses.
//   Address width is a parameter. base (default 0) is added to every
//   address of write / write_strb / write_skew / read, so a testbench can
//   keep its register offsets when the IP's map moves (the library's maps
//   start at 0x10, after the ID / VERSION / DATE block at 0x00-0x0C);
//   read_abs / write_abs use the address as given. Every handshake is
//   sampled at the clock edge (AXI allows READY to depend on VALID, so a
//   READY seen between edges does not count).
// Date: 2026-10-16
`timescale 1ns/1ps
module axil_bfm #(
  parameter int ADDR_W = 8
) (
  input  logic              aclk,
  // s_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.master s_axil
);
  int  resp_errors = 0;          // count of non-OKAY responses
  logic [1:0] last_resp;         // response of the last transaction
  int  bready_delay = 0;         // clocks BREADY stays low after BVALID (backpressure tests; 0 = ready at once)
  int  rready_delay = 0;         // clocks RREADY stays low after RVALID
  int unsigned base = 0;         // added to every address of write / write_strb / write_skew / read

  initial begin
    s_axil.awaddr = '0;
    s_axil.awvalid = 0;
    s_axil.wdata = '0;
    s_axil.wstrb = 4'hF;
    s_axil.wvalid = 0;
    s_axil.bready = 0;
    s_axil.araddr = '0;
    s_axil.arvalid = 0;
    s_axil.rready = 0;
  end

  // Blocking register write with byte strobes
  task automatic write_strb(input [ADDR_W-1:0] a, input [31:0] d, input [3:0] s);
    write_abs_strb(ADDR_W'(a + base), d, s);
  endtask
  task automatic write_abs(input [ADDR_W-1:0] a, input [31:0] d);
    write_abs_strb(a, d, 4'hF);
  endtask
  task automatic write_abs_strb(input [ADDR_W-1:0] a, input [31:0] d, input [3:0] s);
    @(posedge aclk);
    #1;
    s_axil.awaddr = a;
    s_axil.awvalid = 1;
    s_axil.wdata = d;
    s_axil.wstrb = s;
    s_axil.wvalid = 1;
    s_axil.bready = (bready_delay == 0);
    fork
      begin
        do @(posedge aclk); while (!s_axil.awready);   // handshake sampled at the clock edge
        #1 s_axil.awvalid = 0;
      end
      begin
        do @(posedge aclk); while (!s_axil.wready);
        #1 s_axil.wvalid = 0;
      end
    join
    wait (s_axil.bvalid);
    if (bready_delay > 0) begin
      repeat (bready_delay) @(posedge aclk);
      #1 s_axil.bready = 1;
    end
    last_resp = s_axil.bresp;
    if (s_axil.bresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil.bready = 0;
  endtask
  task automatic write(input [ADDR_W-1:0] a, input [31:0] d);
    write_strb(a, d, 4'hF);
  endtask

  // Write with independent delays (clocks) before presenting AW and W, to test channel ordering
  task automatic write_skew(input [ADDR_W-1:0] a, input [31:0] d, input int aw_delay, input int w_delay);
    @(posedge aclk);
    #1;
    s_axil.bready = (bready_delay == 0);
    s_axil.wstrb = 4'hF;
    fork
      begin
        repeat (aw_delay) @(posedge aclk);
        #1 s_axil.awaddr = ADDR_W'(a + base);
        s_axil.awvalid = 1;
        do @(posedge aclk); while (!s_axil.awready);
        #1 s_axil.awvalid = 0;
      end
      begin
        repeat (w_delay) @(posedge aclk);
        #1 s_axil.wdata = d;
        s_axil.wvalid = 1;
        do @(posedge aclk); while (!s_axil.wready);
        #1 s_axil.wvalid = 0;
      end
    join
    wait (s_axil.bvalid);
    if (bready_delay > 0) begin
      repeat (bready_delay) @(posedge aclk);
      #1 s_axil.bready = 1;
    end
    last_resp = s_axil.bresp;
    if (s_axil.bresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil.bready = 0;
  endtask

  // Blocking register read
  task automatic read(input [ADDR_W-1:0] a, output [31:0] d);
    read_abs(ADDR_W'(a + base), d);
  endtask
  task automatic read_abs(input [ADDR_W-1:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    s_axil.araddr = a;
    s_axil.arvalid = 1;
    s_axil.rready = (rready_delay == 0);
    do @(posedge aclk); while (!s_axil.arready);     // handshake sampled at the clock edge
    #1 s_axil.arvalid = 0;
    wait (s_axil.rvalid);
    if (rready_delay > 0) begin
      repeat (rready_delay) @(posedge aclk);
      #1 s_axil.rready = 1;
    end
    d = s_axil.rdata;
    last_resp = s_axil.rresp;
    if (s_axil.rresp != 2'b00) resp_errors++;
    @(posedge aclk);
    #1 s_axil.rready = 0;
  endtask
endmodule
