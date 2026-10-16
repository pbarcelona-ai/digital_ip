// ***************
// Filename: axil_regbus.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite slave to register bus bridge.
//   Converts AXI4-Lite transactions into a simple one-cycle register bus.
//   Write: reg_wr pulses for one clock with reg_waddr/reg_wdata/reg_wstrb
//   once both the AW and W beats have arrived (in either order). The
//   register block answers reg_wr_err on the following cycle (1 = the word
//   is read-only or unmapped); the B response (SLVERR on an error, else
//   OKAY) is raised then.
//   Read: reg_rd pulses for one clock with reg_raddr. The register block
//   must return reg_rdata and reg_rd_err on the following cycle (registered
//   read); they are then captured and presented on the R channel (SLVERR
//   on an error, else OKAY). Tie both error inputs to 0 to always answer
//   OKAY.
//   One outstanding write and one outstanding read are supported. R and B
//   data stay stable while the master stalls ready.
// Date: 2026-10-16

module axil_regbus #(
  // ADDR_W : AXI address width in bits
  // DATA_W : AXI data width in bits (register width)
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32
)(
  input  logic                clk,            // clock
  input  logic                rst_n,          // synchronous reset, active low
  // AXI4-Lite slave: AW/W/B write channels, AR/R read channels
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.slave s_axil,
  // Simple register bus towards the register block
  // bus: regbus_if.host (ip/shared/src/interfaces/regbus_if.sv), ADDR_W = ADDR_W, DATA_W = DATA_W {reg_wr=wr reg_waddr=waddr reg_wdata=wdata reg_wstrb=wstrb reg_wr_err=wr_err reg_rd=rd reg_raddr=raddr reg_rdata=rdata reg_rd_err=rd_err}
  regbus_if.host bus
);

  // ---------------- write path ----------------
  // The AW and W beats are captured independently into holding
  // registers. Once both are held (and no write is in progress) the write
  // is issued on the register bus; the B response follows one cycle later
  // with the register block's error answer.
  logic                aw_held, w_held;   // beat captured, awaiting pair
  logic                wr_busy;           // write issued, B response not yet accepted
  logic                wr_d;              // reg_wr delayed one cycle: reg_wr_err is valid now
  logic [ADDR_W-1:0]   awaddr_q;          // captured write address
  logic [DATA_W-1:0]   wdata_q;           // captured write data
  logic [DATA_W/8-1:0] wstrb_q;           // captured byte strobes

  // Each channel is ready while its holding register is empty
  assign s_axil.awready = !aw_held;
  assign s_axil.wready  = !w_held;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_held       <= 1'b0;
      w_held        <= 1'b0;
      awaddr_q      <= '0;
      wdata_q       <= '0;
      wstrb_q       <= '0;
      s_axil.bvalid <= 1'b0;
      s_axil.bresp  <= 2'b00;
      wr_busy       <= 1'b0;
      wr_d          <= 1'b0;
      bus.wr        <= 1'b0;
      bus.waddr     <= '0;
      bus.wdata     <= '0;
      bus.wstrb     <= '0;
    end else begin
      bus.wr <= 1'b0;                     // single-cycle pulse by default
      wr_d   <= bus.wr;
      // capture the write address beat
      if (s_axil.awvalid && s_axil.awready) begin
        aw_held  <= 1'b1;
        awaddr_q <= s_axil.awaddr;
      end
      // capture the write data beat
      if (s_axil.wvalid && s_axil.wready) begin
        w_held  <= 1'b1;
        wdata_q <= s_axil.wdata;
        wstrb_q <= s_axil.wstrb;
      end
      // both halves present: perform the register write and free the
      // holding registers
      if (aw_held && w_held && !wr_busy) begin
        bus.wr    <= 1'b1;
        bus.waddr <= awaddr_q;
        bus.wdata <= wdata_q;
        bus.wstrb <= wstrb_q;
        aw_held   <= 1'b0;
        w_held    <= 1'b0;
        wr_busy   <= 1'b1;
      end
      // the register block's answer arrives one cycle after reg_wr
      if (wr_d) begin
        s_axil.bvalid <= 1'b1;
        s_axil.bresp  <= bus.wr_err ? 2'b10 : 2'b00;   // SLVERR / OKAY
      end else if (s_axil.bvalid && s_axil.bready) begin
        s_axil.bvalid <= 1'b0;             // response accepted
        wr_busy       <= 1'b0;
      end
    end
  end

  // ---------------- read path ----------------
  // AR accepted -> reg_rd pulse (cycle 1) -> register block returns
  // reg_rdata (cycle 2) -> captured into the R channel. Only one read
  // is in flight at a time.
  logic rd_pend;   // a read has been accepted and is not yet returned
  logic rd_d;      // reg_rd delayed one cycle: reg_rdata is valid now

  assign s_axil.arready = !rd_pend && !s_axil.rvalid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_pend       <= 1'b0;
      rd_d          <= 1'b0;
      bus.rd        <= 1'b0;
      bus.raddr     <= '0;
      s_axil.rvalid <= 1'b0;
      s_axil.rdata  <= '0;
      s_axil.rresp  <= 2'b00;
    end else begin
      bus.rd <= 1'b0;                     // single-cycle pulse by default
      rd_d   <= bus.rd;
      // accept the read address and request the register
      if (s_axil.arvalid && s_axil.arready) begin
        bus.rd    <= 1'b1;
        bus.raddr <= s_axil.araddr;
        rd_pend   <= 1'b1;
      end
      // register data arrives one cycle after reg_rd: present it on R
      if (rd_d) begin
        s_axil.rdata  <= bus.rdata;
        s_axil.rresp  <= bus.rd_err ? 2'b10 : 2'b00;   // SLVERR / OKAY
        s_axil.rvalid <= 1'b1;
        rd_pend       <= 1'b0;
      end else if (s_axil.rvalid && s_axil.rready) begin
        s_axil.rvalid <= 1'b0;             // data accepted by master
      end
    end
  end

endmodule
