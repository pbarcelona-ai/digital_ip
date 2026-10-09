// ***************
// Filename: quad_dec_top.sv
// Author: FPGA Cores 4 U
// Description: Quadrature encoder decoder IP. A/B/index inputs pass two
//   flop synchronizers and a programmable stability filter, then a x4
//   decoder updates a 32 bit signed position counter, direction flag and
//   illegal transition (error) counter. Index pulse latches and optionally
//   clears the position. A window timer measures counts per window
//   (velocity) and emits each sample on an AXI-Stream master. Map - 0x00
//   CTRL [0]en [1]clear pos (pulse) [2]index clears pos [3]swap A/B
//   [15:8]filter clocks, 0x04 POSITION, 0x08 VELOCITY, 0x0C WINDOW clocks,
//   0x10 STATUS [0]dir [1]error [2]index seen (W1C), 0x14 ERR_COUNT, 0x18
//   INDEX_POS. Version 1.0.0. Clock - single clock aclk, every input is
//   synchronous to it unless a two-flop synchronizer is mentioned. Reset -
//   synchronous active low aresetn, registers take the documented reset
//   values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29
module quad_dec_top (
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
  input  logic        enc_a_i,
  input  logic        enc_b_i,
  input  logic        enc_z_i,
  // Velocity samples (signed counts per window)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

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

  localparam logic [7*32-1:0] RSTV = {32'd0, 32'd0, 32'd0, 32'd100000, 32'd0, 32'd0, 32'd1};
  logic [7*32-1:0] regs, rd;
  logic [6:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(7), .RESET_VALS(RSTV)) u_regs (
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

  logic win_load;                // window boundary pulse
  wire en = regs[0];
  wire [7:0] filt = regs[8 +: 8];

  // ---- Synchronize and filter the three inputs ----
  (* async_reg = "true" *) logic [2:0] s1, s2;
  logic [2:0] fil;               // filtered value
  logic [23:0] fcnt;             // 3 x 8 bit stability counters
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s1 <= '0;
      s2 <= '0;
      fil <= '0;
      fcnt <= '0;
    end
    else begin
      s1 <= {enc_z_i, enc_b_i, enc_a_i};
      s2 <= s1;
      for (int i = 0; i < 3; i++) begin
        if (s2[i] == fil[i]) fcnt[i*8 +: 8] <= '0;
        else if (fcnt[i*8 +: 8] >= filt) begin
          fil[i] <= s2[i];
          fcnt[i*8 +: 8] <= '0;
        end
        else fcnt[i*8 +: 8] <= fcnt[i*8 +: 8] + 8'd1;
      end
    end
  end

  wire a = regs[3] ? fil[1] : fil[0];
  wire b = regs[3] ? fil[0] : fil[1];
  logic [1:0] ab_prev;
  logic z_prev;

  // ---- x4 decode: forward sequence 00 -> 10 -> 11 -> 01 -> 00 ----
  logic signed [31:0] pos, idx_pos, win_cnt;
  logic dir, err_f, idx_f;
  logic [31:0] err_cnt;
  logic step_up, step_dn, step_err;
  wire [3:0] tr = {ab_prev, a, b};
  always_comb begin
    step_up = 1'b0;
    step_dn = 1'b0;
    step_err = 1'b0;
    case (tr)
      4'b0010, 4'b1011, 4'b1101, 4'b0100: step_up = 1'b1;
      4'b0001, 4'b0111, 4'b1110, 4'b1000: step_dn = 1'b1;
      4'b0011, 4'b1100, 4'b0110, 4'b1001: step_err = 1'b1;   // two bits changed
      default: ;
    endcase
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      pos <= '0;
      idx_pos <= '0;
      ab_prev <= '0;
      z_prev <= 1'b0;
      dir <= 1'b0;
      err_f <= 1'b0;
      idx_f <= 1'b0;
      err_cnt <= '0;
      win_cnt <= '0;
    end else begin
      ab_prev <= {a, b};
      z_prev <= fil[2];
      if (en) begin
        if (step_up) begin
          pos <= pos + 32'sd1;
          win_cnt <= win_cnt + 32'sd1;
          dir <= 1'b1;
        end
        if (step_dn) begin
          pos <= pos - 32'sd1;
          win_cnt <= win_cnt - 32'sd1;
          dir <= 1'b0;
        end
        if (step_err) begin
          err_f <= 1'b1;
          err_cnt <= err_cnt + 32'd1;
        end
        if (fil[2] & ~z_prev) begin                        // index rising edge
          idx_pos <= pos;
          idx_f <= 1'b1;
          if (regs[2]) pos <= '0;
        end
      end
      if (wr_pulse[0] & wr_data[1]) pos <= '0;
      if (wr_pulse[1]) pos <= $signed(wr_data);              // load position
      if (wr_pulse[4]) begin
        if (wr_data[1]) err_f <= 1'b0;
        if (wr_data[2]) idx_f <= 1'b0;
      end
      if (win_load) win_cnt <= '0;
    end
  end

  // ---- Velocity window ----
  logic [31:0] wtmr;
  logic signed [31:0] vel;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wtmr <= '0;
      win_load <= 1'b0;
      vel <= '0;
      m_axis_tvalid <= 1'b0;
    end
    else begin
      win_load <= 1'b0;
      if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;
      if (en) begin
        if (wtmr >= regs[3*32 +: 32]) begin
          wtmr <= '0;
          win_load <= 1'b1;
          vel <= win_cnt;
          m_axis_tvalid <= 1'b1;                            // drops if not consumed
        end else wtmr <= wtmr + 32'd1;
      end
    end
  end
  assign m_axis_tdata = vel;
  assign m_axis_tlast = 1'b1;

  assign rd = {idx_pos, err_cnt, {29'd0, idx_f, err_f, dir}, regs[3*32 +: 32], vel, pos, regs[31:0]};
endmodule
