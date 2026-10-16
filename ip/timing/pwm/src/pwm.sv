// ***************
// Filename: pwm.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel PWM IP. Programmable prescaler and period,
//   edge or center aligned counting, per-channel double-buffered duty
//   (updated at the period boundary), optional complementary outputs with
//   programmable dead time and per-channel output inversion. Registers on the cfg_*
//   ports; pwm_top.sv is the block with its AXI4-Lite register map
//   (src/include/pwm_regs.sv: ID "PWMT" / VERSION / DATE at 0x00-0x08, 0x10
//   CTRL [0]en [1]center [2]complementary, 0x14 PERIOD (counter top), 0x18
//   PRESCALE (clk divide-1), 0x1C DEADTIME clocks, 0x20 INVERT mask,
//   0x24+4*n DUTY[n]). Output pipeline is registered for timing. Version
//   1.0.0. Clock - single clock aclk, every input is synchronous to it
//   unless a two-flop synchronizer is mentioned. Reset - synchronous
//   active low aresetn, registers take the documented reset values.
//   Latency - AXI-Lite write response and read data follow the request by
//   about 2 to 3 clocks (ip_axil_regs, registered read path). Timing -
//   registered outputs, no combinational path from the bus to the pins.
//   Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-10-12
module pwm #(
  parameter int CHANNELS = 4
) (
  input  logic                   aclk,
  input  logic                   aresetn,
  output logic [CHANNELS-1:0]    pwm_o,           // main outputs
  output logic [CHANNELS-1:0]    pwm_n_o,         // complementary outputs
  output logic                   period_pulse_o,  // one clock per period start
  // register ports
  input  logic [2:0]             cfg_ctrl,        // CTRL
  input  logic [15:0]            cfg_period,      // PERIOD
  input  logic [15:0]            cfg_prescale,    // PRESCALE
  input  logic [15:0]            cfg_deadtime,    // DEADTIME
  input  logic [CHANNELS-1:0]    cfg_invert,      // INVERT
  input  logic [CHANNELS*16-1:0] cfg_duty         // DUTY[n]
);
  if (CHANNELS < 1 || CHANNELS > 8) begin : g_chk_ch $error("%m: CHANNELS must be 1..8"); end

  wire        en     = cfg_ctrl[0];
  wire        center = cfg_ctrl[1];
  wire        comp   = cfg_ctrl[2];
  wire [15:0] period = cfg_period;
  wire [15:0] presc  = cfg_prescale;
  wire [15:0] dtime  = cfg_deadtime;

  // Prescaler tick
  logic [15:0] pcnt;
  logic tick;
  always_ff @(posedge aclk) begin
    if (!aresetn || !en) begin
      pcnt <= '0;
      tick <= 1'b0;
    end
    else if (pcnt >= presc) begin
      pcnt <= '0;
      tick <= 1'b1;
    end
    else begin
      pcnt <= pcnt + 16'd1;
      tick <= 1'b0;
    end
  end

  // Period counter: up (edge aligned) or up/down (center aligned)
  logic [15:0] cnt;
  logic dir_dn, boundary;
  always_ff @(posedge aclk) begin
    if (!aresetn || !en) begin
      cnt <= '0;
      dir_dn <= 1'b0;
      boundary <= 1'b0;
    end
    else begin
      boundary <= 1'b0;
      if (tick) begin
        if (!center) begin
          if (cnt >= period) begin
            cnt <= '0;
            boundary <= 1'b1;
          end
          else cnt <= cnt + 16'd1;
        end else if (!dir_dn) begin
          if (cnt >= period) begin
            dir_dn <= 1'b1;
            cnt <= cnt - 16'd1;
          end
          else cnt <= cnt + 16'd1;
        end else begin
          if (cnt <= 16'd1) begin
            dir_dn <= 1'b0;
            cnt <= '0;
            boundary <= 1'b1;
          end
          else cnt <= cnt - 16'd1;
        end
      end
    end
  end
  assign period_pulse_o = boundary;

  // Per-channel compare, dead time and output registers
  genvar c;
  generate
    for (c = 0; c < CHANNELS; c++) begin : g_ch
      logic [15:0] duty_act;      // active duty (loaded at period boundary)
      logic        raw, raw_d;
      logic [15:0] dt_cnt;
      logic        hi, lo;
      always_ff @(posedge aclk) begin
        if (!aresetn || !en) begin
          duty_act <= cfg_duty[c*16 +: 16];
          raw <= 1'b0;
          raw_d <= 1'b0;
          dt_cnt <= '0;
          hi <= 1'b0;
          lo <= 1'b0;
        end else begin
          if (boundary) duty_act <= cfg_duty[c*16 +: 16];
          raw   <= (cnt < duty_act);
          raw_d <= raw;
          if (raw != raw_d) dt_cnt <= dtime;              // edge: start dead time
          else if (dt_cnt != 16'd0) dt_cnt <= dt_cnt - 16'd1;
          if (comp) begin
            hi <= raw & (dt_cnt == 16'd0) & (raw == raw_d);
            lo <= ~raw & (dt_cnt == 16'd0) & (raw == raw_d);
          end else begin
            hi <= raw;
            lo <= ~raw;
          end
        end
      end
      assign pwm_o[c]   = hi ^ cfg_invert[c];
      assign pwm_n_o[c] = lo ^ cfg_invert[c];
    end
  endgenerate
endmodule
