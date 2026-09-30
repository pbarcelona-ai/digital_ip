// ***************
// Filename: axil_regbus.sv
// Author: Paul Barcelona
// Description: AXI4-Lite slave to register bus bridge.
//   Converts AXI4-Lite transactions into a simple one-cycle register bus.
//   Write: reg_wr pulses for one clock with reg_waddr/reg_wdata/reg_wstrb
//   once both the AW and W beats have arrived (in either order); the B
//   response (always OKAY) is raised in the same cycle.
//   Read: reg_rd pulses for one clock with reg_raddr. The register block
//   must return reg_rdata on the following cycle (registered read); the
//   data is then captured and presented on the R channel (always OKAY).
//   One outstanding write and one outstanding read are supported. R and B
//   data stay stable while the master stalls ready.
// Date: 2026-09-26

module axil_regbus #(
  // ADDR_W : AXI address width in bits
  // DATA_W : AXI data width in bits (register width)
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32
)(
  input  logic                clk,            // clock
  input  logic                rst_n,          // async reset, active low
  // AXI4-Lite slave: AW/W/B write channels, AR/R read channels
  input  logic [ADDR_W-1:0]   s_axil_awaddr,
  input  logic                s_axil_awvalid,
  output logic                s_axil_awready,
  input  logic [DATA_W-1:0]   s_axil_wdata,
  input  logic [DATA_W/8-1:0] s_axil_wstrb,
  input  logic                s_axil_wvalid,
  output logic                s_axil_wready,
  output logic [1:0]          s_axil_bresp,
  output logic                s_axil_bvalid,
  input  logic                s_axil_bready,
  input  logic [ADDR_W-1:0]   s_axil_araddr,
  input  logic                s_axil_arvalid,
  output logic                s_axil_arready,
  output logic [DATA_W-1:0]   s_axil_rdata,
  output logic [1:0]          s_axil_rresp,
  output logic                s_axil_rvalid,
  input  logic                s_axil_rready,
  // Simple register bus towards the register block
  output logic                reg_wr,
  output logic [ADDR_W-1:0]   reg_waddr,
  output logic [DATA_W-1:0]   reg_wdata,
  output logic [DATA_W/8-1:0] reg_wstrb,
  output logic                reg_rd,
  output logic [ADDR_W-1:0]   reg_raddr,
  input  logic [DATA_W-1:0]   reg_rdata       // valid 1 cycle after reg_rd
);

  // ---------------- write path ----------------
  // The AW and W beats are captured independently into holding
  // registers. Once both are held (and no B response is pending) the
  // write is issued on the register bus and the B response is raised.
  logic                aw_held, w_held;   // beat captured, awaiting pair
  logic [ADDR_W-1:0]   awaddr_q;          // captured write address
  logic [DATA_W-1:0]   wdata_q;           // captured write data
  logic [DATA_W/8-1:0] wstrb_q;           // captured byte strobes

  // Each channel is ready while its holding register is empty
  assign s_axil_awready = !aw_held;
  assign s_axil_wready  = !w_held;
  assign s_axil_bresp   = 2'b00;          // always OKAY

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_held       <= 1'b0;
      w_held        <= 1'b0;
      awaddr_q      <= '0;
      wdata_q       <= '0;
      wstrb_q       <= '0;
      s_axil_bvalid <= 1'b0;
      reg_wr        <= 1'b0;
      reg_waddr     <= '0;
      reg_wdata     <= '0;
      reg_wstrb     <= '0;
    end else begin
      reg_wr <= 1'b0;                     // single-cycle pulse by default
      // capture the write address beat
      if (s_axil_awvalid && s_axil_awready) begin
        aw_held  <= 1'b1;
        awaddr_q <= s_axil_awaddr;
      end
      // capture the write data beat
      if (s_axil_wvalid && s_axil_wready) begin
        w_held  <= 1'b1;
        wdata_q <= s_axil_wdata;
        wstrb_q <= s_axil_wstrb;
      end
      // both halves present: perform the register write, free the
      // holding registers and signal the write response
      if (aw_held && w_held && !s_axil_bvalid) begin
        reg_wr        <= 1'b1;
        reg_waddr     <= awaddr_q;
        reg_wdata     <= wdata_q;
        reg_wstrb     <= wstrb_q;
        aw_held       <= 1'b0;
        w_held        <= 1'b0;
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;             // response accepted
      end
    end
  end

  // ---------------- read path ----------------
  // AR accepted -> reg_rd pulse (cycle 1) -> register block returns
  // reg_rdata (cycle 2) -> captured into the R channel. Only one read
  // is in flight at a time.
  logic rd_pend;   // a read has been accepted and is not yet returned
  logic rd_d;      // reg_rd delayed one cycle: reg_rdata is valid now

  assign s_axil_arready = !rd_pend && !s_axil_rvalid;
  assign s_axil_rresp   = 2'b00;          // always OKAY

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_pend       <= 1'b0;
      rd_d          <= 1'b0;
      reg_rd        <= 1'b0;
      reg_raddr     <= '0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
    end else begin
      reg_rd <= 1'b0;                     // single-cycle pulse by default
      rd_d   <= reg_rd;
      // accept the read address and request the register
      if (s_axil_arvalid && s_axil_arready) begin
        reg_rd    <= 1'b1;
        reg_raddr <= s_axil_araddr;
        rd_pend   <= 1'b1;
      end
      // register data arrives one cycle after reg_rd: present it on R
      if (rd_d) begin
        s_axil_rdata  <= reg_rdata;
        s_axil_rvalid <= 1'b1;
        rd_pend       <= 1'b0;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;             // data accepted by master
      end
    end
  end

endmodule
