// ***************
// Filename: axi4_lite_regs.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite register bank with per-register access types.
//   Version 1.0.0. NREG 32-bit registers, each RW (0, software read/write
//   with byte strobes), RO (1, reads hw_i, writes rejected with SLVERR),
//   W1C (2, status register - hardware sets bits through hw_set_i,
//   software clears bits by writing 1) or W1S (3, software sets bits by
//   writing 1, hardware clears through hw_set_i). ACCESS holds 2 bits per
//   register. RESET_VALS holds reset values. reg_o exposes RW/W1C/W1S
//   state, wr_pulse_o pulses for one clock on any write to register n.
//   Built on axi4_lite_slave (same handshake rules and latency). Clock -
//   aclk. Reset - synchronous aresetn, registers take RESET_VALS. Latency
//   - write 4 clocks, read 4 clocks. Errors - SLVERR on write to RO,
//   DECERR beyond NREG words; NREG < 1 rejected at elaboration.
// Date: 2026-09-29
module axi4_lite_regs #(
  parameter int ADDR_W = 8,
  parameter int NREG   = 8,
  parameter logic [2*NREG-1:0]  ACCESS     = '0,     // 2 bits per register
  parameter logic [32*NREG-1:0] RESET_VALS = '0
) (
  input  logic              aclk,
  input  logic              aresetn,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  input  logic [32*NREG-1:0] hw_i,          // RO register values
  input  logic [32*NREG-1:0] hw_set_i,      // W1C: set bits, W1S: clear bits (one clock pulses)
  output logic [32*NREG-1:0] reg_o,
  output logic [NREG-1:0]    wr_pulse_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (NREG < 1) begin : g_bad $error("axi4_lite_regs: NREG must be >= 1"); end
  if ((1 << (ADDR_W - 2)) < NREG) begin : g_bad2 $error("axi4_lite_regs: ADDR_W too small for NREG"); end
  logic wr_en, rd_en, wr_err, rd_err;
  logic [ADDR_W-1:0] wa, ra;
  logic [31:0] wd, rdd;
  logic [3:0] ws;
  axi4_lite_slave #(.ADDR_W(ADDR_W), .READ_WAIT(0), .MAP_WORDS(NREG)) u_slave (
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
    .wr_en_o(wr_en),
    .wr_addr_o(wa),
    .wr_data_o(wd),
    .wr_strb_o(ws),
    .wr_err_i(wr_err),
    .rd_en_o(rd_en),
    .rd_addr_o(ra),
    .rd_data_i(rdd),
    .rd_valid_i(1'b1),
    .rd_err_i(1'b0)
  );

  wire [$clog2(NREG > 1 ? NREG : 2)-1:0] widx = wa[2 +: $clog2(NREG > 1 ? NREG : 2)];
  wire [$clog2(NREG > 1 ? NREG : 2)-1:0] ridx = ra[2 +: $clog2(NREG > 1 ? NREG : 2)];
  logic [31:0] bmask;
  always_comb for (int b = 0; b < 4; b++) bmask[b*8 +: 8] = {8{ws[b]}};

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      reg_o <= RESET_VALS;
      wr_pulse_o <= '0;
      wr_err <= 1'b0;
    end
    else begin
      wr_pulse_o <= '0;
      wr_err <= 1'b0;
      // hardware set/clear first, then software (software W1C/W1S wins on the same bit is avoided by order)
      for (int i = 0; i < NREG; i++) begin
        case (ACCESS[2*i +: 2])
          2'd2: reg_o[32*i +: 32] <= reg_o[32*i +: 32] | hw_set_i[32*i +: 32];
          2'd3: reg_o[32*i +: 32] <= reg_o[32*i +: 32] & ~hw_set_i[32*i +: 32];
          default: ;
        endcase
      end
      if (wr_en) begin
        wr_pulse_o[widx] <= 1'b1;
        case (ACCESS[2*widx +: 2])
          2'd0: reg_o[32*widx +: 32] <= (reg_o[32*widx +: 32] & ~bmask) | (wd & bmask);
          2'd1: wr_err <= 1'b1;
          2'd2: reg_o[32*widx +: 32] <= (reg_o[32*widx +: 32] & ~(wd & bmask)) | hw_set_i[32*widx +: 32];
          2'd3: reg_o[32*widx +: 32] <= (reg_o[32*widx +: 32] | (wd & bmask)) & ~hw_set_i[32*widx +: 32];
        endcase
      end
    end
  end
  always_comb rdd = (ACCESS[2*ridx +: 2] == 2'd1) ? hw_i[32*ridx +: 32] : reg_o[32*ridx +: 32];
  assign rd_err = 1'b0;
endmodule
