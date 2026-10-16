// ***************
// Filename: py_sysctl.sv
// Author: FPGA Cores 4 U
// Description: py_soc system control logic: the reset cause (sticky across
//   system resets, reset by por_n only), the boot status, a free-running
//   cycle counter, the SoC ID, the core logic reset release and the clock
//   generator output enables. Its registers come and go on the cfg_* / sts_*
//   ports; py_sysctl_top.sv is the block with its AXI4-Lite register map
//   (src/include/py_sysctl_regs.sv: ID "SCTL" / VERSION / DATE at 0x00-0x08,
//   RESET_CAUSE 0x10 [0] external reset (rst_n) [1] watchdog, write 1 to
//   clear; BOOT_STATUS 0x14 [0] boot done [1] boot error [6:4] boot error
//   code; CYCLES 0x18; SOC_ID 0x1C 32'h5059_0100 ("PY", version 1.0);
//   CORE_RESET 0x20 [0] 1 = release the reset of the logic outside py_soc
//   (core_rst_n_o high), cleared by every system reset (external or
//   watchdog), so the firmware releases it again after each boot; CLK_EN
//   0x24 [NCLK-1:0] enables of the clock generator outputs (clk_en_o, py_soc
//   clk_o), reset value CLK_EN_RST; CLK_STATUS 0x28 [0] clock generator
//   outputs locked (clk_locked_i; 1 without a clock generator), [1] clock
//   generator present).
//   Clock - aclk only. Reset - aresetn (system reset) for the counter,
//   CORE_RESET and CLK_EN, por_n (external reset) for RESET_CAUSE.
// Date: 2026-10-12
module py_sysctl #(
  parameter int              NCLK       = 1,        // clock generator outputs (1..32)
  parameter logic [NCLK-1:0] CLK_EN_RST = '1,       // CLK_EN reset value
  parameter bit              CLKGEN     = 1'b0      // clock generator present (CLK_STATUS[1])
) (
  input  logic            aclk,
  input  logic            aresetn,          // system reset (external or watchdog)
  input  logic            por_n,            // external reset only
  input  logic            wdt_reset_i,      // watchdog reset in progress
  input  logic            boot_done_i,
  input  logic            boot_err_i,
  input  logic [2:0]      boot_err_code_i,
  output logic            core_rst_n_o,     // CORE_RESET[0]: reset of the logic outside py_soc (0 = in reset)
  output logic [NCLK-1:0] clk_en_o,         // CLK_EN
  input  logic            clk_locked_i,     // clock generator outputs locked
  // register ports
  // regs: py_sysctl_regs_if.core (src/include/py_sysctl_regs_if.sv)
  py_sysctl_regs_if.core regs
);
  // Reset cause survives the system reset it describes
  logic [1:0] cause;
  always_ff @(posedge aclk) begin
    if (!por_n) cause <= 2'b01;
    else begin
      if (wdt_reset_i) cause[1] <= 1'b1;
      else if (aresetn && regs.cfg_reset_cause_wr) cause <= cause & ~regs.cfg_reset_cause;
    end
  end

  logic [31:0] cycles;
  always_ff @(posedge aclk) begin
    if (!aresetn) cycles <= '0;
    else          cycles <= cycles + 1'b1;
  end

  assign core_rst_n_o = regs.cfg_core_reset;
  assign clk_en_o = regs.cfg_clk_en;
  assign regs.sts_reset_cause = cause;
  assign regs.sts_boot_status = {25'd0, boot_err_code_i, 2'd0, boot_err_i, boot_done_i};
  assign regs.sts_cycles = cycles;
  assign regs.sts_soc_id = 32'h5059_0100;
  assign regs.sts_clk_status = {CLKGEN, clk_locked_i};
endmodule
