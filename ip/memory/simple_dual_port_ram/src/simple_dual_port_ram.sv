// ***************
// Filename: simple_dual_port_ram.sv
// Author: FPGA Cores 4 U
// Description: Simple dual-port RAM with an independent write port and read
//   port. Version 1.0.0. CLOCKING 0 uses wclk for both ports; a separate rclk
//   is used when ASYNC=1 (unrelated clocks, read-during-write of the same
//   address returns old or new data, undefined which). Optional byte enables.
//   Inferred as block RAM. Reset - the read output register resets
//   synchronously (active low, rclk domain). Latency - read data one rclk
//   after raddr with re_i. Errors - DEPTH<2, WIDTH<1 or BYTE_EN with WIDTH
//   not multiple of 8 rejected at elaboration.
// Date: 2026-09-29
module simple_dual_port_ram #(
  parameter int WIDTH   = 32,
  parameter int DEPTH   = 1024,
  parameter bit BYTE_EN = 1'b0,
  parameter bit ASYNC   = 1'b0
) (
  input  logic                     wclk,
  input  logic                     we_i,
  input  logic [WIDTH/8-1:0]       be_i,
  input  logic [$clog2(DEPTH)-1:0] waddr_i,
  input  logic [WIDTH-1:0]         wdata_i,
  input  logic                     rclk,       // ignored (wclk used) when ASYNC=0
  input  logic                     rst_n,      // rclk domain
  input  logic                     re_i,
  input  logic [$clog2(DEPTH)-1:0] raddr_i,
  output logic [WIDTH-1:0]         rdata_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 2 || WIDTH < 1) begin : g_bad $error("simple_dual_port_ram: bad DEPTH/WIDTH"); end
  if (BYTE_EN && (WIDTH % 8) != 0) begin : g_badb $error("simple_dual_port_ram: BYTE_EN needs WIDTH % 8 == 0"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  wire rc = ASYNC ? rclk : wclk;
  always_ff @(posedge wclk) if (we_i) begin
    if (BYTE_EN) begin for (int b = 0; b < WIDTH/8; b++) if (be_i[b]) mem[waddr_i][b*8 +: 8] <= wdata_i[b*8 +: 8]; end
    else mem[waddr_i] <= wdata_i;
  end
  always_ff @(posedge rc) begin
    if (!rst_n) rdata_o <= '0;
    else if (re_i) rdata_o <= mem[raddr_i];
  end
endmodule
