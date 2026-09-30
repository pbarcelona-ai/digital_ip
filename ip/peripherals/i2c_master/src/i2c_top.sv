// ***************
// Filename: i2c_top.sv
// Author: Paul Barcelona
// Description: I2C master IP top level. AXI-Lite registers start and
//   describe a transaction; write data is taken from an AXI-Stream slave
//   port and read data is returned on an AXI-Stream master port (tlast
//   marks the last byte). Open-drain pins use i/o/t style signals. Map -
//   0x00 CTRL [0]en [1]start(pulse) [2]read [3]no_stop; 0x04 ADDR[6:0];
//   0x08 LEN; 0x0C DIV (phase clocks-1, f_scl = f_clk/(4*(DIV+1))); 0x10
//   STATUS [0]busy [1]done [2]nack [3]arb_lost, [3:1] are write-1-to-
//   clear. Version 1.0.0. Clock - single clock aclk, every input is
//   synchronous to it unless a two-flop synchronizer is mentioned. Reset -
//   synchronous active low aresetn, registers take the documented reset
//   values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29
module i2c_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCL_HZ     = 100_000,      // default bus frequency
  parameter int FIFO_DEPTH = 512
) (
  input  logic        aclk,
  input  logic        aresetn,
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
  // AXI4-Stream slave: bytes to write
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: bytes read
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Open-drain bus (o is always 0, t=1 releases the line)
  input  logic        scl_i,
  output logic        scl_o,
  output logic        scl_t,
  input  logic        sda_i,
  output logic        sda_o,
  output logic        sda_t
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (CLK_HZ < 1 || SCL_HZ < 1 || SCL_HZ * 8 > CLK_HZ) begin : g_chk_rate $error("%m: need SCL_HZ*8 <= CLK_HZ"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end

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

  localparam int DIV_DEF = (CLK_HZ / (4 * SCL_HZ)) - 1;
  localparam logic [5*32-1:0] RSTV =
      {32'd0, 32'(DIV_DEF), 32'd0, 32'd0, 32'd0};
  localparam int LW = $clog2(FIFO_DEPTH) + 2;

  logic [5*32-1:0] regs, rd;   // regs use 5 words
  logic [4:0]      wr_pulse;
  logic [31:0]     wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(5), .RESET_VALS(RSTV)) u_regs (
    .aclk, .aresetn,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));

  // Start pulse: a CTRL write with bit 1 set (uses the freshly written bits)
  logic start_p;
  always_ff @(posedge aclk) begin
    if (!aresetn) start_p <= 1'b0;
    else          start_p <= wr_pulse[0] & wr_data[1];
  end

  // Write data FIFO
  logic [7:0] txf_data; logic txf_valid, txf_ready, txf_last, txf_user;
  logic [LW-1:0] txf_lvl, rxf_lvl;
  ip_axis_fifo #(.DATA_W(8), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(s_axis_tdata), .s_tlast(s_axis_tlast), .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(txf_data), .m_tlast(txf_last), .m_tuser(txf_user),
    .m_tvalid(txf_valid), .m_tready(txf_ready), .level_o(txf_lvl));

  // Read data FIFO
  logic [7:0] rx_data; logic rx_valid, rx_ready, rx_last, rxf_user;
  ip_axis_fifo #(.DATA_W(8), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(rx_data), .s_tlast(rx_last), .s_tuser(1'b0),
    .s_tvalid(rx_valid), .s_tready(rx_ready),
    .m_tdata(m_axis_tdata), .m_tlast(m_axis_tlast), .m_tuser(rxf_user),
    .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready), .level_o(rxf_lvl));

  // Sequencer and bit engine
  logic        bc_valid, bc_din, bc_abort, bc_done, bc_dout, bc_arb, bc_busy;
  logic [1:0]  bc_cmd;
  logic        busy, done_p, nack_p, arb_p, scl_low, sda_low;

  i2c_master_fsm u_fsm (
    .clk(aclk), .rst_n(aresetn), .enable_i(regs[0]), .start_i(start_p),
    .rw_i(regs[2]), .nostop_i(regs[3]), .addr_i(regs[32 +: 7]),
    .len_i(regs[64 +: 16]),
    .s_tdata(txf_data), .s_tvalid(txf_valid), .s_tready(txf_ready),
    .m_tdata(rx_data), .m_tvalid(rx_valid), .m_tlast(rx_last), .m_tready(rx_ready),
    .bc_valid, .bc_cmd, .bc_din, .bc_abort, .bc_done, .bc_dout, .bc_arb,
    .busy_o(busy), .done_o(done_p), .nack_o(nack_p), .arb_o(arb_p));

  i2c_bit_ctrl u_bit (
    .clk(aclk), .rst_n(aresetn), .div_i(regs[96 +: 16]),
    .cmd_valid(bc_valid), .cmd(bc_cmd), .din(bc_din), .abort_i(bc_abort),
    .done_o(bc_done), .dout_o(bc_dout), .arb_lost_o(bc_arb), .busy_o(bc_busy),
    .scl_i, .sda_i, .scl_low_o(scl_low), .sda_low_o(sda_low));

  assign scl_o = 1'b0;
  assign sda_o = 1'b0;
  assign scl_t = ~scl_low;
  assign sda_t = ~sda_low;

  // Sticky status flags (write 1 to clear)
  logic f_done, f_nack, f_arb;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      f_done <= 1'b0; f_nack <= 1'b0; f_arb <= 1'b0;
    end else begin
      if (done_p) f_done <= 1'b1;
      if (nack_p) f_nack <= 1'b1;
      if (arb_p)  f_arb  <= 1'b1;
      if (start_p) f_done <= 1'b0;             // new transaction clears done
      if (wr_pulse[4]) begin
        if (wr_data[1]) f_done <= 1'b0;
        if (wr_data[2]) f_nack <= 1'b0;
        if (wr_data[3]) f_arb  <= 1'b0;
      end
    end
  end

  wire [31:0] status = {16'(rxf_lvl), 12'd0, f_arb, f_nack, f_done, busy};
  assign rd = {status, regs[127:0]};
endmodule
