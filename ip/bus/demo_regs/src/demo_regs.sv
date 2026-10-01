// ***************
// Filename: demo_regs.sv
// Author: FPGA Cores 4 U
// Description: Generated AXI4-Lite register block 'demo_regs' with 6
//   registers (regmap_gen.py, do not edit by hand; regenerate from the JSON
//   description). Version 1.0.0. Built on axi4_lite_regs, so the timing is
//   the same. Clock - aclk. Reset - synchronous aresetn, registers take their
//   documented reset values. Latency - write 4 clocks, read 4 clocks. Errors
//   - writes to RO registers answer SLVERR, addresses beyond the last
//   register answer DECERR. Access types - RW read/write with byte strobes,
//   RO read only, W1C hardware sets and software clears by writing 1, W1S
//   software sets and hardware clears.
// Date: 2026-09-29
module demo_regs (
  input  logic        aclk,
  input  logic        aresetn,
  input  logic [4:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [4:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  input  logic [31:0] id_i,   // ID (RO): value read by software
  output logic        id_wr_o,   // ID: pulse on every software write
  output logic [31:0] ctrl_o,   // CTRL (RW): register value
  output logic        ctrl_wr_o,   // CTRL: pulse on every software write
  output logic [31:0] status_o,   // STATUS (W1C): register value
  input  logic [31:0] status_set_i,   // STATUS: hardware sets bits (1 clock pulses)
  output logic        status_wr_o,   // STATUS: pulse on every software write
  output logic [31:0] thresh_o,   // THRESH (RW): register value
  output logic        thresh_wr_o,   // THRESH: pulse on every software write
  input  logic [31:0] count_i,   // COUNT (RO): value read by software
  output logic        count_wr_o,   // COUNT: pulse on every software write
  output logic [31:0] trig_o,   // TRIG (W1S): register value
  input  logic [31:0] trig_clr_i,   // TRIG: hardware clears bits (1 clock pulses)
  output logic        trig_wr_o   // TRIG: pulse on every software write
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int NREG = 6;
  localparam logic [2*NREG-1:0]  ACCESS     = 12'hD21;
  localparam logic [32*NREG-1:0] RESET_VALS = 192'h100000000000000001000000000;
  logic [32*NREG-1:0] hw, hwset, regv; logic [NREG-1:0] wrp;
  always_comb begin
    hw = '0; hwset = '0;
    hw[0*32 +: 32] = id_i;
    hwset[2*32 +: 32] = status_set_i;
    hw[4*32 +: 32] = count_i;
    hwset[5*32 +: 32] = trig_clr_i;
  end
  axi4_lite_regs #(.ADDR_W(5), .NREG(NREG), .ACCESS(ACCESS), .RESET_VALS(RESET_VALS)) u_regs (
    .aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp,
    .s_axil_rvalid, .s_axil_rready, .hw_i(hw), .hw_set_i(hwset), .reg_o(regv), .wr_pulse_o(wrp));
  assign id_wr_o = wrp[0];
  assign ctrl_o = regv[1*32 +: 32];
  assign ctrl_wr_o = wrp[1];
  assign status_o = regv[2*32 +: 32];
  assign status_wr_o = wrp[2];
  assign thresh_o = regv[3*32 +: 32];
  assign thresh_wr_o = wrp[3];
  assign count_wr_o = wrp[4];
  assign trig_o = regv[5*32 +: 32];
  assign trig_wr_o = wrp[5];
endmodule
