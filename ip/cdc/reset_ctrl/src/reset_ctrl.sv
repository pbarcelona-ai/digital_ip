// ***************
// Filename: reset_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Reset synchronizer logic. Synchronizes an asynchronous
//   external reset for the AXI-Lite bus (bus_rst_n_o, never affected by the
//   soft reset, so the registers survive it) and for NUM_OUT replicated user
//   resets (fan-out control), with a software reset, a hold time, a reset
//   event counter and status on the cfg_* / sts_* ports. ip_reset_sync_top.sv
//   is the block with its AXI4-Lite register map (src/include/
//   reset_ctrl_regs.sv: ID "RSTC" / VERSION / DATE at 0x00-0x08, 0x10 CTRL
//   [0]=soft reset (self clearing), 0x14 HOLD cycles, 0x18 STATUS[0]=active
//   [1]=event seen (W1C), 0x1C event count). Clock - aclk, the external
//   reset arst_i is asynchronous and is synchronized with STAGES flops.
//   Reset - the reset asserts asynchronously and releases synchronously;
//   outputs are held for the programmed hold (HOLD_DEFAULT at reset).
//   Latency - release is STAGES+1 clocks after arst_i deasserts plus the
//   hold. Errors - illegal parameters stop elaboration.
// Date: 2026-10-12
module reset_ctrl #(
  parameter int STAGES        = 3,
  parameter int NUM_OUT       = 4,     // replicated reset outputs
  parameter bit ACTIVE_LOW_IN = 1,
  parameter bit ACTIVE_LOW_OUT= 1,
  parameter int HOLD_DEFAULT  = 16     // default stretch in clocks
) (
  input  logic        aclk,
  input  logic        arst_i,           // external asynchronous reset
  // Reset outputs
  output logic [NUM_OUT-1:0] rst_o,
  output logic        bus_rst_n_o,      // synchronized reset for AXI logic
  // register ports (in the bus_rst_n_o domain)
  input  logic        cfg_ctrl,          // CTRL: data written ...
  input  logic        cfg_ctrl_wr,       // ... and its write pulse (soft reset)
  input  logic [15:0] cfg_hold,          // HOLD
  input  logic [1:0]  cfg_status,        // STATUS: data written ...
  input  logic        cfg_status_wr,     // ... and its write pulse
  output logic [1:0]  sts_status,        // STATUS: value read
  output logic [31:0] sts_event_count    // EVENT_COUNT
);
  if (STAGES < 2) begin : g_chk_stg $error("%m: STAGES must be >= 2"); end
  if (NUM_OUT < 1) begin : g_chk_nout $error("%m: NUM_OUT must be >= 1"); end
  if (HOLD_DEFAULT < 1) begin : g_chk_hold $error("%m: HOLD_DEFAULT must be >= 1"); end

  // Bus reset: never affected by the soft reset so registers survive it
  logic bus_active;
  rst_sync #(
    .STAGES(STAGES),
    .ACTIVE_LOW_IN(ACTIVE_LOW_IN),
    .ACTIVE_LOW_OUT(1'b1),
    .ASYNC_ASSERT(1'b1)
  ) u_bus_sync (
    .clk(aclk),
    .rst_i(arst_i),
    .hold_i(16'd4),
    .rst_o(bus_rst_n_o),
    .active_o(bus_active)
  );

  // Soft reset request: written bit 0 of CTRL, stretched by one pulse
  logic soft_req;
  always_ff @(posedge aclk) begin
    if (!bus_rst_n_o) soft_req <= 1'b0;
    else              soft_req <= cfg_ctrl_wr & cfg_ctrl;
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
      (* keep = "true" *) rst_sync #(
        .STAGES(STAGES),
        .ACTIVE_LOW_IN(1'b0),
        .ACTIVE_LOW_OUT(ACTIVE_LOW_OUT),
        .ASYNC_ASSERT(1'b1)
      ) u_s (
        .clk(aclk),
        .rst_i(comb_req),
        .hold_i(cfg_hold),
        .rst_o(rst_o[i]),
        .active_o(act[i])
      );
    end
  endgenerate
  assign main_active = act[0];

  // Event counter and sticky flag (rising edge of the active flag)
  logic act_d, seen;
  logic [31:0] evt_cnt;
  always_ff @(posedge aclk) begin
    if (!bus_rst_n_o) begin
      act_d <= 1'b0;
      seen <= 1'b0;
      evt_cnt <= '0;
    end else begin
      act_d <= main_active;
      if (main_active & ~act_d) begin
        seen    <= 1'b1;
        evt_cnt <= evt_cnt + 32'd1;
      end
      if (cfg_status_wr & cfg_status[1]) seen <= 1'b0;   // W1C
    end
  end

  assign sts_status = {seen, main_active};
  assign sts_event_count = evt_cnt;
endmodule
