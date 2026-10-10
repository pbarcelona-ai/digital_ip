// ***************
// Filename: gpio_top.sv
// Author: FPGA Cores 4 U
// Description: General purpose I/O IP with WIDTH pins. Per-pin direction,
//   output register with atomic SET/CLEAR/TOGGLE registers, two flop input
//   synchronizers, per-pin rising/falling edge interrupts with enable masks
//   and write-1-to-clear status, and an interrupt output. Tri-state style
//   pins (gpio_t=1 means input). Map - 0x00 OUT, 0x04 DIR(1=output), 0x08 IN
//   (read only), 0x0C SET, 0x10 CLEAR, 0x14 TOGGLE, 0x18 INT_EN, 0x1C
//   RISE_EN, 0x20 FALL_EN, 0x24 INT_STATUS (W1C). Version 1.0.0. Clock -
//   single clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29
module gpio_top #(
  parameter int WIDTH = 16               // number of pins (<= 32)
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  input  logic [WIDTH-1:0] gpio_i,       // pad input
  output logic [WIDTH-1:0] gpio_o,       // pad output value
  output logic [WIDTH-1:0] gpio_t,       // pad tri-state (1 = high-Z input)
  output logic             irq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1 || WIDTH > 32) begin : g_chk_w $error("%m: WIDTH must be 1..32"); end

`ifndef SYNTHESIS
  // verification-only checks: excluded from code coverage
  // verilator coverage_off
  // ---- immediate assertions (simulation only; skipped by synthesis) ----
  logic ip_chk_b_q, ip_chk_r_q;
  always @(posedge aclk) begin
    if (aresetn) begin
      ip_chk_b_q <= s_axil_bvalid & ~s_axil_bready;
      ip_chk_r_q <= s_axil_rvalid & ~s_axil_rready;
      assert (s_axil_bresp == 2'b00 || s_axil_bresp == 2'b10) else $error("%m: reserved BRESP value");
      assert (s_axil_rresp == 2'b00 || s_axil_rresp == 2'b10) else $error("%m: reserved RRESP value");
      if (ip_chk_b_q) assert (s_axil_bvalid) else $error("%m: BVALID dropped before BREADY");
      if (ip_chk_r_q) assert (s_axil_rvalid) else $error("%m: RVALID dropped before RREADY");
    end else begin
      ip_chk_b_q <= 1'b0;
      ip_chk_r_q <= 1'b0;
    end
  end
  // verilator coverage_on
`endif

  logic [10*32-1:0] regs, rd;
  logic [9:0]       wr_pulse;
  logic [31:0]      wr_data;
  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(10)
  ) u_regs (
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
    .reg_o(regs),
    .wr_pulse_o(wr_pulse),
    .wr_data_o(wr_data),
    .rd_i(rd)
  );

  wire [WIDTH-1:0] wd = wr_data[WIDTH-1:0];

  // Output register: direct write, atomic set / clear / toggle
  logic [WIDTH-1:0] out_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) out_q <= '0;
    else begin
      if (wr_pulse[0]) out_q <= wd;
      if (wr_pulse[3]) out_q <= out_q | wd;
      if (wr_pulse[4]) out_q <= out_q & ~wd;
      if (wr_pulse[5]) out_q <= out_q ^ wd;
    end
  end

  // Input synchronizer plus previous value for edge detection
  (* async_reg = "true" *) logic [WIDTH-1:0] sync1, sync2;
  logic [WIDTH-1:0] prev;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      sync1 <= '0;
      sync2 <= '0;
      prev <= '0;
    end
    else begin
      sync1 <= gpio_i;
      sync2 <= sync1;
      prev <= sync2;
    end
  end

  // Edge interrupts
  wire [WIDTH-1:0] rise = sync2 & ~prev & regs[7*32 +: WIDTH];
  wire [WIDTH-1:0] fall = ~sync2 & prev & regs[8*32 +: WIDTH];
  logic [WIDTH-1:0] status;
  always_ff @(posedge aclk) begin
    if (!aresetn) status <= '0;
    else status <= (status & ~(wr_pulse[9] ? wd : '0)) | rise | fall;
  end
  always_ff @(posedge aclk) begin
    if (!aresetn) irq_o <= 1'b0;
    else irq_o <= |(status & regs[6*32 +: WIDTH]);
  end

  assign gpio_o = out_q;
  assign gpio_t = ~regs[32 +: WIDTH];
  assign rd = {status, regs[8*32 +: 32], regs[7*32 +: 32], regs[6*32 +: 32],
               32'd0, 32'd0, 32'd0, 32'(sync2), regs[32 +: 32], 32'(out_q)};
endmodule
