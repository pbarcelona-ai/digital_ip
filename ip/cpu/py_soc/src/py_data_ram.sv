// ***************
// Filename: py_data_ram.sv
// Author: FPGA Cores 4 U
// Description: py_soc data RAM: BYTES bytes of 32-bit words on an AXI4-Lite
//   slave (py_core mem32 loads and stores: the firmware's arrays). One
//   transaction per direction at a time. Write - AWREADY and WREADY are high
//   together in the clock both AWVALID and WVALID are (and no response is
//   pending); the word is written in that clock (WSTRB byte enables) and
//   BVALID (OKAY) rises the clock after. Read - ARREADY is high while no read
//   response is pending and no write is accepted in the same clock (the RAM
//   has one port; a write wins); RVALID (OKAY) rises the clock after with the
//   word. Address bits [AW+1:2] select the word (the window decode is the
//   crossbar's); the low two bits are ignored. Memory - single_port_ram
//   (block RAM, NO_CHANGE mode, no initialisation: a word is undefined until
//   written; the content is kept over a system reset). Clock - aclk only. Reset - synchronous aresetn (active
//   low) clears the handshake state. Latency - write response 1 clock, read
//   data 1 clock after the address handshake. Errors - BYTES must be a power
//   of two >= 8 (elaboration).
// Date: 2026-10-20
module py_data_ram #(
  parameter int BYTES = 65536
) (
  input  logic aclk,
  input  logic aresetn,
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W >= clog2(BYTES)
  axil_if.slave s_axil
);
  /* verilator lint_off UNUSEDPARAM */             // version identification (library convention), not logic
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  /* verilator lint_on UNUSEDPARAM */
  localparam int AW = $clog2(BYTES) - 2;               // word address bits
  if (BYTES < 8 || (1 << $clog2(BYTES)) != BYTES) begin : g_bad
    $error("py_data_ram: BYTES must be a power of two >= 8");
  end

  logic bvalid, rvalid;
  wire  wr = s_axil.awvalid && s_axil.wvalid && !bvalid;
  wire  rd = s_axil.arvalid && !rvalid && !wr;

  logic [AW-1:0] addr;
  logic [31:0]   rdata;
  assign addr = wr ? s_axil.awaddr[AW+1:2] : s_axil.araddr[AW+1:2];
  single_port_ram #(
    .WIDTH(32),
    .DEPTH(1 << AW),
    .MODE(2),                                        // no change: a write keeps a pending read's data
    .BYTE_EN(1'b1),
    .INIT_ZERO(1'b0)
  ) u_mem (
    .clk(aclk),
    .rst_n(aresetn),
    .en_i(wr || rd),
    .we_i(wr),
    .be_i(s_axil.wstrb),
    .addr_i(addr),
    .wdata_i(s_axil.wdata),
    .rdata_o(rdata)
  );

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      bvalid <= 1'b0;
      rvalid <= 1'b0;
    end else begin
      if (wr) bvalid <= 1'b1;
      else if (s_axil.bready) bvalid <= 1'b0;
      if (rd) rvalid <= 1'b1;
      else if (s_axil.rready) rvalid <= 1'b0;
    end
  end

  assign s_axil.awready = wr;
  assign s_axil.wready  = wr;
  assign s_axil.bvalid  = bvalid;
  assign s_axil.bresp   = 2'b00;
  assign s_axil.arready = rd;
  assign s_axil.rvalid  = rvalid;
  assign s_axil.rdata   = rdata;                       // held by the RAM's output register until the next access
  assign s_axil.rresp   = 2'b00;

  // the window's upper address bits are the crossbar's decode
  wire unused_ok = &{1'b0, s_axil.awaddr, s_axil.araddr, 1'b0};
endmodule
