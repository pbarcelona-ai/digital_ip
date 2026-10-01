// ***************
// Filename: pwm_top.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel PWM IP. Programmable prescaler and period,
//   edge or center aligned counting, per-channel double-buffered duty
//   (updated at the period boundary), optional complementary outputs with
//   programmable dead time and per-channel output inversion. Map - 0x00
//   CTRL [0]en [1]center [2]complementary, 0x04 PERIOD (counter top), 0x08
//   PRESCALE (clk divide-1), 0x0C DEADTIME clocks, 0x10 INVERT mask,
//   0x14+4*n DUTY[n]. Output pipeline is registered for timing. Version
//   1.0.0. Clock - single clock aclk, every input is synchronous to it
//   unless a two-flop synchronizer is mentioned. Reset - synchronous
//   active low aresetn, registers take the documented reset values.
//   Latency - AXI-Lite write response and read data follow the request by
//   about 2 to 3 clocks (ip_axil_regs, registered read path). Timing -
//   registered outputs, no combinational path from the bus to the pins.
//   Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29
module pwm_top #(
  parameter int CHANNELS = 4
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
  output logic [CHANNELS-1:0] pwm_o,     // main outputs
  output logic [CHANNELS-1:0] pwm_n_o,   // complementary outputs
  output logic                period_pulse_o   // one clock per period start
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (CHANNELS < 1 || CHANNELS > 8) begin : g_chk_ch $error("%m: CHANNELS must be 1..8"); end

`ifndef SYNTHESIS
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
    end else begin ip_chk_b_q <= 1'b0; ip_chk_r_q <= 1'b0; end
  end
`endif

  localparam int NREG = 5 + CHANNELS;
  localparam logic [NREG*32-1:0] RSTV = {{CHANNELS{32'd0}}, 32'd0, 32'd0, 32'd0, 32'd99, 32'd0};
  logic [NREG*32-1:0] regs;
  logic [NREG-1:0]    wr_pulse;
  logic [31:0]        wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(NREG), .RESET_VALS(RSTV)) u_regs (
.aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(regs));

  wire        en     = regs[0];
  wire        center = regs[1];
  wire        comp   = regs[2];
  wire [15:0] period = regs[32 +: 16];
  wire [15:0] presc  = regs[64 +: 16];
  wire [15:0] dtime  = regs[96 +: 16];

  // Prescaler tick
  logic [15:0] pcnt; logic tick;
  always_ff @(posedge aclk) begin
    if (!aresetn || !en) begin pcnt <= '0; tick <= 1'b0; end
    else if (pcnt >= presc) begin pcnt <= '0; tick <= 1'b1; end
    else begin pcnt <= pcnt + 16'd1; tick <= 1'b0; end
  end

  // Period counter: up (edge aligned) or up/down (center aligned)
  logic [15:0] cnt; logic dir_dn, boundary;
  always_ff @(posedge aclk) begin
    if (!aresetn || !en) begin cnt <= '0; dir_dn <= 1'b0; boundary <= 1'b0; end
    else begin
      boundary <= 1'b0;
      if (tick) begin
        if (!center) begin
          if (cnt >= period) begin cnt <= '0; boundary <= 1'b1; end
          else cnt <= cnt + 16'd1;
        end else if (!dir_dn) begin
          if (cnt >= period) begin dir_dn <= 1'b1; cnt <= cnt - 16'd1; end
          else cnt <= cnt + 16'd1;
        end else begin
          if (cnt <= 16'd1) begin dir_dn <= 1'b0; cnt <= '0; boundary <= 1'b1; end
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
          duty_act <= regs[(5+c)*32 +: 16]; raw <= 1'b0; raw_d <= 1'b0;
          dt_cnt <= '0; hi <= 1'b0; lo <= 1'b0;
        end else begin
          if (boundary) duty_act <= regs[(5+c)*32 +: 16];
          raw   <= (cnt < duty_act);
          raw_d <= raw;
          if (raw != raw_d) dt_cnt <= dtime;              // edge: start dead time
          else if (dt_cnt != 16'd0) dt_cnt <= dt_cnt - 16'd1;
          if (comp) begin
            hi <= raw & (dt_cnt == 16'd0) & (raw == raw_d);
            lo <= ~raw & (dt_cnt == 16'd0) & (raw == raw_d);
          end else begin
            hi <= raw; lo <= ~raw;
          end
        end
      end
      assign pwm_o[c]   = hi ^ regs[4*32 + c];
      assign pwm_n_o[c] = lo ^ regs[4*32 + c];
    end
  endgenerate
endmodule
