// ***************
// Filename: watchdog.sv
// Author: FPGA Cores 4 U
// Description: Watchdog timer logic: a prescaler (PRESCALE + 1 clocks per
//   tick), a tick counter restarted by a keyed kick (0x5AFEC0DE), a
//   pre-timeout interrupt, an optional window (kicks before WINDOW_OPEN are
//   early and reset), a lock bit that freezes EN, WINDOW_EN, TIMEOUT,
//   PRESCALE, PRETIMEOUT and WINDOW_OPEN (later writes are ignored), and a
//   stretched
//   system reset output (RESET_CYCLES clocks). Its registers come and go on
//   the cfg_* / sts_* ports; watchdog_top.sv is the block with its
//   AXI4-Lite register map (src/include/watchdog_regs.sv: ID "WDOG" /
//   VERSION / DATE at 0x00-0x08, CTRL 0x10 [0] en [1] window_en [2] lock,
//   TIMEOUT 0x14 ticks, PRESCALE 0x18, PRETIMEOUT 0x1C ticks, WINDOW_OPEN
//   0x20 ticks, KICK 0x24, STATUS 0x28 [0] pretimeout [1] expired [2] early
//   kick [3] bad key (W1C), COUNT 0x2C). Clock - single clock aclk.
//   Reset - synchronous active low aresetn. Errors - illegal parameter
//   values stop elaboration with an $error.
// Date: 2026-10-16
module watchdog #(
  parameter int RESET_CYCLES = 16        // width of the reset pulse in clocks
) (
  input  logic        aclk,
  input  logic        aresetn,
  output logic        irq_o,             // pre-timeout interrupt
  output logic        wdt_reset_o,       // system reset request (active high)
  // register ports
  // regs: watchdog_regs_if.core (src/include/watchdog_regs_if.sv)
  watchdog_regs_if.core regs
);
  if (RESET_CYCLES < 1 || RESET_CYCLES > 256) begin : g_chk_rc $error("%m: RESET_CYCLES must be 1..256"); end

  logic [31:0] cnt;                 // watchdog counter (prescaled ticks)
  logic lock_q, en_q, win_en;
  // LOCK freezes the timing: once locked, the values in effect at the lock are kept
  logic [31:0] timeout_l, presc_l, pretmo_l, win_open_l;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      timeout_l <= '0;
      presc_l <= '0;
      pretmo_l <= '0;
      win_open_l <= '0;
    end else if (!lock_q) begin
      timeout_l <= regs.cfg_timeout;
      presc_l <= regs.cfg_prescale;
      pretmo_l <= regs.cfg_pretimeout;
      win_open_l <= regs.cfg_window_open;
    end
  end
  wire [31:0] timeout = timeout_l, presc = presc_l;
  wire [31:0] pretmo = pretmo_l, win_open = win_open_l;

  // Enable/lock handling: once locked, en stays as it was
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      lock_q <= 1'b0;
      en_q <= 1'b0;
      win_en <= 1'b0;
    end
    else if (regs.cfg_ctrl_wr) begin
      if (!lock_q) begin                       // writes ignored after lock
        win_en <= regs.cfg_ctrl[1];
        en_q <= regs.cfg_ctrl[0];
        lock_q <= regs.cfg_ctrl[2];
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
  wire kick_wr    = regs.cfg_kick_wr;
  wire kick_good  = kick_wr & (regs.cfg_kick == 32'h5AFE_C0DE);
  wire kick_bad   = kick_wr & (regs.cfg_kick != 32'h5AFE_C0DE);
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
      if (regs.cfg_status_wr) begin                 // W1C first: a set in the same clock wins
        if (regs.cfg_status[0]) pre_f   <= 1'b0;
        if (regs.cfg_status[1]) exp_f   <= 1'b0;
        if (regs.cfg_status[2]) early_f <= 1'b0;
        if (regs.cfg_status[3]) key_f   <= 1'b0;
      end
      if (en_q && tick && cnt >= pretmo && pretmo != 32'd0) pre_f <= 1'b1;
      if (expire_now)  exp_f   <= 1'b1;
      if (kick_early)  early_f <= 1'b1;
      if (kick_bad)    key_f   <= 1'b1;
      if (kick_ok) pre_f <= 1'b0;
    end
  end
  assign irq_o = pre_f;
  assign regs.sts_ctrl = {lock_q, win_en, en_q};
  assign regs.sts_status = {key_f, early_f, exp_f, pre_f};
  assign regs.sts_count = cnt;
endmodule
