// ***************
// Filename: watchdog_top.sv
// Author: FPGA Cores 4 U
// Description: Watchdog timer IP. Prescaled up-counter with programmable
//   timeout and pre-timeout interrupt, optional window mode (kicks before
//   WINDOW_OPEN are violations), key-protected kick register, write-once lock
//   bit that prevents disabling, and a stretched system reset output. Map -
//   0x00 CTRL [0]en [1]window_en [2]lock, 0x04 TIMEOUT ticks, 0x08 PRESCALE
//   (clk divide-1), 0x0C PRETIMEOUT ticks, 0x10 WINDOW_OPEN ticks, 0x14 KICK
//   (write 0x5AFEC0DE), 0x18 STATUS [0]pretimeout [1]expired [2]early kick
//   [3]bad key (W1C), 0x1C COUNT. Version 1.0.0. Clock - single clock aclk,
//   every input is synchronous to it unless a two-flop synchronizer is
//   mentioned. Reset - synchronous active low aresetn, registers take the
//   documented reset values. Latency - AXI-Lite write response and read data
//   follow the request by about 2 to 3 clocks (ip_axil_regs, registered read
//   path). Timing - registered outputs, no combinational path from the bus to
//   the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29
module watchdog_top #(
  parameter int RESET_CYCLES = 16        // width of the reset pulse in clocks
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
  output logic irq_o,                    // pre-timeout interrupt
  output logic wdt_reset_o               // system reset request (active high)
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (RESET_CYCLES < 1) begin : g_chk_rc $error("%m: RESET_CYCLES must be >= 1"); end

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

  localparam logic [32*8-1:0] RSTV = {32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd1000, 32'd0};
  logic [8*32-1:0] regs, rd;
  logic [7:0] wr_pulse;
  logic [31:0] wr_data;
  // CTRL bits: lock is write-once, en cannot be cleared once locked
  ip_axil_regs #(.ADDR_W(8), .NREG(8), .RESET_VALS(RSTV)) u_regs (
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

  logic [31:0] cnt;                 // watchdog counter (prescaled ticks)
  logic lock_q, en_q;
  wire  win_en = regs[1];
  wire [31:0] timeout = regs[32 +: 32], presc = regs[64 +: 32];
  wire [31:0] pretmo = regs[96 +: 32], win_open = regs[128 +: 32];

  // Enable/lock handling: once locked, en stays as it was
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      lock_q <= 1'b0;
      en_q <= 1'b0;
    end
    else if (wr_pulse[0]) begin
      if (!lock_q) begin
        en_q <= wr_data[0];
        lock_q <= wr_data[2];
      end
      else en_q <= en_q;                       // writes ignored after lock
    end
  end

  // Prescaler
  logic [31:0] pcnt;
  logic tick;
  always_ff @(posedge aclk) begin
    if (!aresetn || !en_q) begin
      pcnt <= '0;
      tick <= 1'b0;
    end
    else if (pcnt >= presc) begin
      pcnt <= '0;
      tick <= 1'b1;
    end
    else begin
      pcnt <= pcnt + 32'd1;
      tick <= 1'b0;
    end
  end

  // Kick decode
  wire kick_wr    = wr_pulse[5];
  wire kick_good  = kick_wr & (wr_data == 32'h5AFE_C0DE);
  wire kick_bad   = kick_wr & (wr_data != 32'h5AFE_C0DE);
  wire kick_early = kick_good & win_en & (cnt < win_open);
  wire kick_ok    = kick_good & ~kick_early;

  logic pre_f, exp_f, early_f, key_f;
  logic [7:0] rst_cnt;
  logic expire_now;
  assign expire_now = tick & (cnt >= timeout);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      cnt <= '0;
      pre_f <= 1'b0;
      exp_f <= 1'b0;
      early_f <= 1'b0;
      key_f <= 1'b0;
      rst_cnt <= '0;
      wdt_reset_o <= 1'b0;
    end else begin
      if (wdt_reset_o) begin
        if (rst_cnt == 8'd0) wdt_reset_o <= 1'b0;
        else rst_cnt <= rst_cnt - 8'd1;
      end
      if (!en_q) cnt <= '0;
      else if (kick_ok) cnt <= '0;
      else if (kick_early | expire_now) begin
        cnt <= '0;
        wdt_reset_o <= 1'b1;
        rst_cnt <= 8'(RESET_CYCLES - 1);
      end
      else if (tick) cnt <= cnt + 32'd1;
      if (en_q && tick && cnt >= pretmo && pretmo != 32'd0) pre_f <= 1'b1;
      if (expire_now)  exp_f   <= 1'b1;
      if (kick_early)  early_f <= 1'b1;
      if (kick_bad)    key_f   <= 1'b1;
      if (wr_pulse[6]) begin
        if (wr_data[0]) pre_f   <= 1'b0;
        if (wr_data[1]) exp_f   <= 1'b0;
        if (wr_data[2]) early_f <= 1'b0;
        if (wr_data[3]) key_f   <= 1'b0;
      end
      if (kick_ok) pre_f <= 1'b0;
    end
  end
  assign irq_o = pre_f;
  assign rd = {cnt, {28'd0, key_f, early_f, exp_f, pre_f}, 32'd0, regs[4*32 +: 32], regs[3*32 +: 32],
               regs[2*32 +: 32], regs[1*32 +: 32], {29'd0, lock_q, regs[1], en_q}};
endmodule
