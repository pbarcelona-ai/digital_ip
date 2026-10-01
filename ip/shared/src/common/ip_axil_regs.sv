// ***************
// Filename: ip_axil_regs.sv
// Author: FPGA Cores 4 U
// Description: Generic AXI4-Lite slave register file. Provides NREG 32-bit
//   read/write registers with byte strobes, one-cycle write pulses, the
//   last written word, and a registered read-data path for timing closure.
//   Read data is supplied by the parent so status and control registers
//   can share one address map. Out of range accesses return SLVERR. Single
//   clock, active-low synchronous reset. Version 1.0.0. Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29
module ip_axil_regs #(
  parameter int ADDR_W = 8,                       // AXI-Lite address bits
  parameter int NREG   = 8,                       // number of 32-bit regs
  parameter logic [NREG*32-1:0] RESET_VALS = '0   // power-up register values
) (
  input  logic                 aclk,
  input  logic                 aresetn,
  // Write address channel
  input  logic [ADDR_W-1:0]    s_axil_awaddr,
  input  logic                 s_axil_awvalid,
  output logic                 s_axil_awready,
  // Write data channel
  input  logic [31:0]          s_axil_wdata,
  input  logic [3:0]           s_axil_wstrb,
  input  logic                 s_axil_wvalid,
  output logic                 s_axil_wready,
  // Write response channel
  output logic [1:0]           s_axil_bresp,
  output logic                 s_axil_bvalid,
  input  logic                 s_axil_bready,
  // Read address channel
  input  logic [ADDR_W-1:0]    s_axil_araddr,
  input  logic                 s_axil_arvalid,
  output logic                 s_axil_arready,
  // Read data channel
  output logic [31:0]          s_axil_rdata,
  output logic [1:0]           s_axil_rresp,
  output logic                 s_axil_rvalid,
  input  logic                 s_axil_rready,
  // Register interface to the IP core
  output logic [NREG*32-1:0]   reg_o,       // stored register values
  output logic [NREG-1:0]      wr_pulse_o,  // one-cycle pulse per write
  output logic [31:0]          wr_data_o,   // raw data of the last write
  input  logic [NREG*32-1:0]   rd_i         // value returned on reads
);

  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (NREG < 1 || NREG > (1 << (ADDR_W - 2))) begin : g_chk_nreg $error("%m: NREG must fit the address space"); end
  if (ADDR_W < 3) begin : g_chk_aw $error("%m: ADDR_W must be >= 3"); end

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

  logic                aw_seen, w_seen;   // channel captured flags
  logic [ADDR_W-1:0]   awaddr_q;
  logic [31:0]         wdata_q;
  logic [3:0]          wstrb_q;

  // Word index of the captured write address
  wire [ADDR_W-3:0] widx  = awaddr_q[ADDR_W-1:2];
  wire              wrng  = (32'(widx) < NREG);
  wire              do_wr = aw_seen & w_seen & ~s_axil_bvalid;

  // Accept each write channel independently, one outstanding write
  assign s_axil_awready = ~aw_seen & ~s_axil_bvalid;
  assign s_axil_wready  = ~w_seen  & ~s_axil_bvalid;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      aw_seen       <= 1'b0;
      w_seen        <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp  <= 2'b00;
      reg_o         <= RESET_VALS;
      wr_pulse_o    <= '0;
      wr_data_o     <= '0;
      awaddr_q      <= '0;
      wdata_q       <= '0;
      wstrb_q       <= '0;
    end else begin
      wr_pulse_o <= '0;                       // default: no write pulse
      if (s_axil_awvalid & s_axil_awready) begin
        aw_seen  <= 1'b1;
        awaddr_q <= s_axil_awaddr;
      end
      if (s_axil_wvalid & s_axil_wready) begin
        w_seen  <= 1'b1;
        wdata_q <= s_axil_wdata;
        wstrb_q <= s_axil_wstrb;
      end
      if (do_wr) begin                        // both channels present
        aw_seen       <= 1'b0;
        w_seen        <= 1'b0;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= wrng ? 2'b00 : 2'b10;
        wr_data_o     <= wdata_q;
        // Constant-index loop keeps the decode shallow (no barrel shifter)
        for (int r = 0; r < NREG; r++) begin
          if (widx == (ADDR_W-2)'(r)) begin
            wr_pulse_o[r] <= 1'b1;
            for (int b = 0; b < 4; b++)
              if (wstrb_q[b]) reg_o[r*32 + b*8 +: 8] <= wdata_q[b*8 +: 8];
          end
        end
      end
      if (s_axil_bvalid & s_axil_bready) s_axil_bvalid <= 1'b0;
    end
  end

  // Read channel: register the selected word (one cycle of pipeline)
  wire [ADDR_W-3:0] ridx = s_axil_araddr[ADDR_W-1:2];
  wire              rrng = (32'(ridx) < NREG);
  assign s_axil_arready = ~s_axil_rvalid;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
      s_axil_rresp  <= 2'b00;
    end else begin
      if (s_axil_arvalid & s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rdata  <= 32'hDEAD_BEEF;       // default: out of range
        s_axil_rresp  <= 2'b10;
        for (int r = 0; r < NREG; r++) begin
          if (ridx == (ADDR_W-2)'(r)) begin
            s_axil_rdata <= rd_i[r*32 +: 32];
            s_axil_rresp <= 2'b00;
          end
        end
      end else if (s_axil_rvalid & s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end
endmodule
