// ***************
// Filename: gpio.sv
// Author: FPGA Cores 4 U
// Description: General purpose I/O logic with WIDTH pins: per-pin direction,
//   output register with atomic SET / CLEAR / TOGGLE, two-flop input
//   synchronizers, per-pin rising / falling edge detection into the
//   write-1-to-clear INT_STATUS, and a registered interrupt output
//   irq_o = |(INT_STATUS & INT_EN). Tri-state style pins (gpio_t = 1 means
//   input). Its registers come and go on the cfg_* / sts_* ports;
//   gpio_top.sv is the block with its AXI4-Lite register map
//   (src/include/gpio_regs.sv: ID "GPIO" / VERSION / DATE at 0x00-0x08,
//   OUT 0x10, DIR 0x14, IN 0x18, SET 0x1C, CLEAR 0x20, TOGGLE 0x24, INT_EN
//   0x28, RISE_EN 0x2C, FALL_EN 0x30, INT_STATUS 0x34).
//   Clock - single clock aclk; gpio_i is synchronised by two flops.
//   Reset - synchronous active low aresetn. Timing - registered outputs, no
//   combinational path from the bus to the pins.
// Date: 2026-10-12
module gpio #(
  parameter int WIDTH = 16               // number of pins (1..32)
) (
  input  logic             aclk,
  input  logic             aresetn,
  input  logic [WIDTH-1:0] gpio_i,       // pad input
  output logic [WIDTH-1:0] gpio_o,       // pad output value
  output logic [WIDTH-1:0] gpio_t,       // pad tri-state (1 = high-Z input)
  output logic             irq_o,
  // register ports
  // regs: gpio_regs_if.core (src/include/gpio_regs_if.sv)
  gpio_regs_if.core regs
);
  if (WIDTH < 1 || WIDTH > 32) begin : g_chk_w $error("%m: WIDTH must be 1..32"); end

  // Output register: direct write, atomic set / clear / toggle
  logic [WIDTH-1:0] out_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) out_q <= '0;
    else begin
      if (regs.cfg_out_wr) out_q <= regs.cfg_out;
      if (regs.cfg_set_wr) out_q <= out_q | regs.cfg_set;
      if (regs.cfg_clear_wr) out_q <= out_q & ~regs.cfg_clear;
      if (regs.cfg_toggle_wr) out_q <= out_q ^ regs.cfg_toggle;
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
  assign regs.sts_int_status_set = (sync2 & ~prev & regs.cfg_rise_en) | (~sync2 & prev & regs.cfg_fall_en);
  always_ff @(posedge aclk) begin
    if (!aresetn) irq_o <= 1'b0;
    else irq_o <= |(regs.cfg_int_status & regs.cfg_int_en);
  end

  assign gpio_o = out_q;
  assign gpio_t = ~regs.cfg_dir;
  assign regs.sts_out = out_q;
  assign regs.sts_in = sync2;
endmodule
