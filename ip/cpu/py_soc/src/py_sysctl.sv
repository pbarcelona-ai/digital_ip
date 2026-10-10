// ***************
// Filename: py_sysctl.sv
// Author: FPGA Cores 4 U
// Description: py_soc system control registers. Map -
//   0x00 RESET_CAUSE [0] external reset (rst_n) [1] watchdog; sticky across
//        system resets, write 1 to clear. Reset by por_n only.
//   0x04 BOOT_STATUS [0] boot done [1] boot error [6:4] boot error code
//   0x08 CYCLES      free-running clock counter (wraps at 2**32)
//   0x0C ID          32'h5059_0100 ("PY", version 1.0)
//   0x10 CORE_RESET  [0] 1 = release the reset of the logic outside py_soc
//        (core_rst_n_o high); reset value 0 = held in reset. Cleared by every
//        system reset (external or watchdog), so the firmware releases it
//        again after each boot, once the CPU is initialised.
//   0x14 CLK_EN      [NCLK-1:0] enables of the clock generator outputs
//        (clk_en_o, py_soc clk_o); reset value CLK_EN_RST
//   0x18 CLK_STATUS  [0] clock generator outputs locked (clk_locked_i;
//        1 without a clock generator), [1] clock generator present
//   Clock - aclk only. Reset - aresetn (system reset) for the bus, counter,
//   CORE_RESET and CLK_EN, por_n (external reset) for RESET_CAUSE.
//   Latency - register access through axi4_lite_slave, 2-3 clocks.
//   Errors - accesses beyond 0x18 return DECERR.
// Date: 2026-10-09
module py_sysctl #(
  parameter int            NCLK       = 1,          // clock generator outputs (1..32)
  parameter logic [NCLK-1:0] CLK_EN_RST = '1,       // CLK_EN reset value
  parameter bit            CLKGEN     = 1'b0        // clock generator present (CLK_STATUS[1])
) (
  input  logic        aclk,
  input  logic        aresetn,      // system reset (external or watchdog)
  input  logic        por_n,        // external reset only
  input  logic        wdt_reset_i,  // watchdog reset in progress
  input  logic        boot_done_i,
  input  logic        boot_err_i,
  input  logic [2:0]  boot_err_code_i,
  output logic        core_rst_n_o, // CORE_RESET[0]: reset of the logic outside py_soc (0 = in reset)
  output logic [NCLK-1:0] clk_en_o, // CLK_EN
  input  logic        clk_locked_i, // clock generator outputs locked
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
  input  logic        s_axil_rready
);
  localparam logic [31:0] ID = 32'h5059_0100;

  logic wr_en, rd_en;
  logic [7:0] wr_addr, rd_addr;
  logic [31:0] wr_data, rd_data;
  logic [3:0] wr_strb;
  axi4_lite_slave #(
    .ADDR_W(8),
    .READ_WAIT(0),
    .MAP_WORDS(7)
  ) u_slv (
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
    .wr_addr_o(wr_addr),
    .wr_data_o(wr_data),
    .wr_strb_o(wr_strb),
    .wr_err_i(1'b0),
    .rd_en_o(rd_en),
    .rd_addr_o(rd_addr),
    .rd_data_i(rd_data),
    .rd_valid_i(1'b0),
    .rd_err_i(1'b0)
  );

  // Reset cause survives the system reset it describes
  logic [1:0] cause;
  always_ff @(posedge aclk) begin
    if (!por_n) cause <= 2'b01;
    else begin
      if (wdt_reset_i) cause[1] <= 1'b1;
      else if (aresetn && wr_en && wr_addr[4:2] == 3'd0) cause <= cause & ~wr_data[1:0];
    end
  end

  // Core logic reset release, written by the firmware
  always_ff @(posedge aclk) begin
    if (!aresetn)                              core_rst_n_o <= 1'b0;
    else if (wr_en && wr_addr[4:2] == 3'd4)    core_rst_n_o <= wr_data[0];
  end

  // Clock generator output enables
  always_ff @(posedge aclk) begin
    if (!aresetn)                              clk_en_o <= CLK_EN_RST;
    else if (wr_en && wr_addr[4:2] == 3'd5)    clk_en_o <= wr_data[NCLK-1:0];
  end

  logic [31:0] cycles;
  always_ff @(posedge aclk) begin
    if (!aresetn) cycles <= '0;
    else          cycles <= cycles + 1'b1;
  end

  always_comb begin
    case (rd_addr[4:2])
      3'd0:    rd_data = {30'd0, cause};
      3'd1:    rd_data = {25'd0, boot_err_code_i, 2'd0, boot_err_i, boot_done_i};
      3'd2:    rd_data = cycles;
      3'd3:    rd_data = ID;
      3'd4:    rd_data = {31'd0, core_rst_n_o};
      3'd5:    rd_data = 32'(clk_en_o);
      3'd6:    rd_data = {30'd0, CLKGEN, clk_locked_i};
      default: rd_data = '0;
    endcase
  end
endmodule
