// ***************
// Filename: i2c_master.sv
// Author: FPGA Cores 4 U
// Description: I2C master logic. The registers (cfg_* / sts_* ports) start
//   and describe a transaction; write data is taken from an AXI-Stream slave
//   port and read data is returned on an AXI-Stream master port (tlast marks
//   the last byte). Open-drain pins use i/o/t style signals. i2c_top.sv is
//   the block with its AXI4-Lite register map (src/include/i2c_master_regs.sv:
//   ID "I2CM" / VERSION / DATE at 0x00-0x08, CTRL 0x10 [0] en [1] start
//   (command, reads 0) [2] read [3] no_stop (clear EN to abort a
//   transaction waiting on its streams: STOP, NACK reported); ADDR 0x14 [6:0]; LEN 0x18; DIV 0x1C (phase
//   clocks - 1, f_scl = f_clk / (4 * (DIV + 1))); STATUS 0x20 [0] busy
//   [1] done [2] nack [3] arb_lost, [3:1] write 1 to clear, [31:16] receive
//   FIFO level). Clock - single clock aclk. Reset - synchronous active low
//   aresetn. Timing - registered outputs, no combinational path from the
//   bus to the pins. Errors - illegal parameter values stop elaboration
//   with an $error.
// Date: 2026-10-16
module i2c_master #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCL_HZ     = 100_000,      // default bus frequency
  parameter int FIFO_DEPTH = 512
) (
  input  logic        aclk,
  input  logic        aresetn,
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.master m_axis,
  // i2c: i2c_if.master (ip/shared/src/interfaces/i2c_if.sv) {scl_i=scl_i scl_o=scl_o scl_t=scl_t sda_i=sda_i sda_o=sda_o sda_t=sda_t}
  i2c_if.master i2c,
  // register ports
  // regs: i2c_master_regs_if.core (src/include/i2c_master_regs_if.sv)
  i2c_master_regs_if.core regs
);
  assign m_axis.tkeep = '1;      // not used by this block
  assign m_axis.tuser = '0;      // not used by this block
  if (CLK_HZ < 1 || SCL_HZ < 1 || SCL_HZ * 8 > CLK_HZ) begin : g_chk_rate $error("%m: need SCL_HZ*8 <= CLK_HZ"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end
  localparam int LW = $clog2(FIFO_DEPTH) + 2;

  // CTRL (a CMD register): EN, READ and NO_STOP are stored here, START is a one-clock command and
  // reads 0, so a read-modify-write of CTRL never starts a transaction again
  logic start_p;
  logic [3:0] ctrl_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      start_p <= 1'b0;
      ctrl_q <= '0;
    end else begin
      start_p <= regs.cfg_ctrl_wr & regs.cfg_ctrl[1];
      if (regs.cfg_ctrl_wr) ctrl_q <= {regs.cfg_ctrl[3:2], 1'b0, regs.cfg_ctrl[0]};
    end
  end
  assign regs.sts_ctrl = ctrl_q;

  // Write data FIFO
  axis_if #(.DATA_W(8), .USER_W(1)) txf ();
  logic [LW-1:0] txf_lvl, rxf_lvl;
  ip_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(s_axis),
    .m(txf),
    .level_o(txf_lvl)
  );

  // Read data FIFO
  axis_if #(.DATA_W(8)) rx ();
  logic rxf_user;
  axis_if #(.DATA_W(8)) u_rxf_m ();
  assign m_axis.tdata = u_rxf_m.tdata;
  assign m_axis.tlast = u_rxf_m.tlast;
  assign rxf_user = u_rxf_m.tuser;
  assign m_axis.tvalid = u_rxf_m.tvalid;
  assign u_rxf_m.tready = m_axis.tready;
  ip_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(rx),
    .m(u_rxf_m),
    .level_o(rxf_lvl)
  );

  // Sequencer and bit engine
  logic        bc_valid, bc_din, bc_abort, bc_done, bc_dout, bc_arb, bc_busy;
  logic [1:0]  bc_cmd;
  logic        busy, done_p, nack_p, arb_p, scl_low, sda_low;

  i2c_master_fsm u_fsm (
    .clk(aclk),
    .rst_n(aresetn),
    .enable_i(ctrl_q[0]),
    .start_i(start_p),
    .rw_i(ctrl_q[2]),
    .nostop_i(ctrl_q[3]),
    .addr_i(regs.cfg_addr),
    .len_i(regs.cfg_len),
    .s(txf),
    .m(rx),
    .bc_valid,
    .bc_cmd,
    .bc_din,
    .bc_abort,
    .bc_done,
    .bc_dout,
    .bc_arb,
    .busy_o(busy),
    .done_o(done_p),
    .nack_o(nack_p),
    .arb_o(arb_p)
  );

  i2c_bit_ctrl u_bit (
    .clk(aclk),
    .rst_n(aresetn),
    .div_i(regs.cfg_div),
    .cmd_valid(bc_valid),
    .cmd(bc_cmd),
    .din(bc_din),
    .abort_i(bc_abort),
    .done_o(bc_done),
    .dout_o(bc_dout),
    .arb_lost_o(bc_arb),
    .busy_o(bc_busy),
    .scl_i(i2c.scl_i),
    .sda_i(i2c.sda_i),
    .scl_low_o(scl_low),
    .sda_low_o(sda_low)
  );

  assign i2c.scl_o = 1'b0;
  assign i2c.sda_o = 1'b0;
  assign i2c.scl_t = ~scl_low;
  assign i2c.sda_t = ~sda_low;

  // Sticky status flags (write 1 to clear)
  logic f_done, f_nack, f_arb;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      f_done <= 1'b0;
      f_nack <= 1'b0;
      f_arb <= 1'b0;
    end else begin
      if (start_p && !busy && ctrl_q[0]) f_done <= 1'b0;   // an accepted start clears done
      if (regs.cfg_status_wr) begin                 // W1C first: a set in the same clock wins
        if (regs.cfg_status[1]) f_done <= 1'b0;
        if (regs.cfg_status[2]) f_nack <= 1'b0;
        if (regs.cfg_status[3]) f_arb  <= 1'b0;
      end
      if (done_p) f_done <= 1'b1;
      if (nack_p) f_nack <= 1'b1;
      if (arb_p)  f_arb  <= 1'b1;
    end
  end

  assign regs.sts_status = {16'(rxf_lvl), 12'd0, f_arb, f_nack, f_done, busy};
endmodule
