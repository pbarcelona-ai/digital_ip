// ***************
// Filename: ip_reset_sync_top.sv
// Author: FPGA Cores 4 U
// Description: Top level of the reset synchronizer IP. Synchronizes an
//   asynchronous external reset for the AXI-Lite bus and for NUM_OUT
//   replicated user resets (fan-out control). A software reset bit, hold-
//   time register, reset event counter and status are exposed through an
//   AXI-Lite register file. Register map - 0x00 CTRL[0]=soft reset (self
//   clearing), 0x04 HOLD cycles, 0x08 STATUS[0]=active [1]=event seen
//   (W1C), 0x0C event count. Version 1.0.0. Clock - aclk, the external
//   reset arst_i is asynchronous and is synchronized with STAGES flops.
//   Reset - the reset asserts asynchronously and releases synchronously;
//   outputs are held for HOLD_DEFAULT clocks or the programmed hold.
//   Latency - release is STAGES+1 clocks after arst_i deasserts plus the
//   hold. Errors - illegal parameters stop elaboration; out of range AXI-
//   Lite accesses return SLVERR.
// Date: 2026-09-29
module ip_reset_sync_top #(
  parameter int STAGES        = 3,
  parameter int NUM_OUT       = 4,     // replicated reset outputs
  parameter bit ACTIVE_LOW_IN = 1,
  parameter bit ACTIVE_LOW_OUT= 1,
  parameter int HOLD_DEFAULT  = 16     // default stretch in clocks
) (
  input  logic        aclk,
  input  logic        arst_i,           // external asynchronous reset
  // AXI4-Lite slave
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
  // Reset outputs
  output logic [NUM_OUT-1:0] rst_o,
  output logic        bus_rst_n_o       // synchronized reset for AXI logic
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_chk_stg $error("%m: STAGES must be >= 2"); end
  if (NUM_OUT < 1) begin : g_chk_nout $error("%m: NUM_OUT must be >= 1"); end
  if (HOLD_DEFAULT < 1) begin : g_chk_hold $error("%m: HOLD_DEFAULT must be >= 1"); end

  localparam logic [4*32-1:0] RSTV = {32'd0, 32'd0, 32'(HOLD_DEFAULT), 32'd0};

  // Bus reset: never affected by the soft reset so registers survive it
  logic bus_active;
  rst_sync #(.STAGES(STAGES), .ACTIVE_LOW_IN(ACTIVE_LOW_IN),
             .ACTIVE_LOW_OUT(1'b1), .ASYNC_ASSERT(1'b1)) u_bus_sync (
    .clk(aclk), .rst_i(arst_i), .hold_i(16'd4),
    .rst_o(bus_rst_n_o), .active_o(bus_active));

  // Register file
  logic [4*32-1:0] regs, rd;
  logic [3:0]      wr_pulse;
  logic [31:0]     wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(4), .RESET_VALS(RSTV)) u_regs (
    .aclk(aclk), .aresetn(bus_rst_n_o),
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));

  // Soft reset request: written bit 0 of CTRL, stretched by one pulse
  logic soft_req;
  always_ff @(posedge aclk) begin
    if (!bus_rst_n_o) soft_req <= 1'b0;
    else              soft_req <= wr_pulse[0] & wr_data[0];
  end

  // Combined request: external reset OR software reset, then synchronized
  // per output copy. The external part is asynchronous.
  wire ext_req = ACTIVE_LOW_IN ? ~arst_i : arst_i;
  wire comb_req = ext_req | soft_req;
  logic [NUM_OUT-1:0] act;
  logic               main_active;

  genvar i;
  generate
    for (i = 0; i < NUM_OUT; i++) begin : g_out
      (* keep = "true" *) rst_sync #(.STAGES(STAGES), .ACTIVE_LOW_IN(1'b0),
                 .ACTIVE_LOW_OUT(ACTIVE_LOW_OUT), .ASYNC_ASSERT(1'b1)) u_s (
        .clk(aclk), .rst_i(comb_req), .hold_i(regs[47:32]),
        .rst_o(rst_o[i]), .active_o(act[i]));
    end
  endgenerate
  assign main_active = act[0];

  // Event counter and sticky flag (rising edge of the active flag)
  logic act_d, seen;
  logic [31:0] evt_cnt;
  always_ff @(posedge aclk) begin
    if (!bus_rst_n_o) begin
      act_d <= 1'b0; seen <= 1'b0; evt_cnt <= '0;
    end else begin
      act_d <= main_active;
      if (main_active & ~act_d) begin
        seen    <= 1'b1;
        evt_cnt <= evt_cnt + 32'd1;
      end
      if (wr_pulse[2] & wr_data[1]) seen <= 1'b0;   // W1C
    end
  end

  assign rd = {evt_cnt, {30'd0, seen, main_active}, regs[63:32], 32'd0};
endmodule
