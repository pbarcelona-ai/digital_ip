// ***************
// Filename: pcie_dw_to_axis.sv
// Author: FPGA Cores 4 U
// Description: Packs a 32 bit double-word stream into a 64 bit AXI-Stream TLP
//   interface. Two DWs form a beat (first DW in bits 31:0), a lone final DW
//   produces a beat with tkeep 0x0F. The output is a registered stage so
//   transmit timing is clean. Version 1.0.0. Clock - the clock of the parent
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module pcie_dw_to_axis (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] dw_data,
  input  logic        dw_last,
  input  logic        dw_valid,
  output logic        dw_ready,
  output logic [63:0] m_tdata,
  output logic [7:0]  m_tkeep,
  output logic        m_tlast,
  output logic        m_tvalid,
  input  logic        m_tready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  logic [31:0] lo_q;
  logic        have_lo;
  wire         can_emit = ~m_tvalid | m_tready;   // output register free
  assign dw_ready = can_emit;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      have_lo <= 1'b0;
      lo_q <= '0;
      m_tvalid <= 1'b0;
      m_tdata <= '0;
      m_tkeep <= '0;
      m_tlast <= 1'b0;
    end else begin
      if (m_tvalid & m_tready) m_tvalid <= 1'b0;
      if (dw_valid & can_emit) begin
        if (!have_lo) begin
          if (dw_last) begin                         // single DW packet end
            m_tdata <= {32'd0, dw_data};
            m_tkeep <= 8'h0F;
            m_tlast <= 1'b1;
            m_tvalid <= 1'b1;
          end else begin
            lo_q <= dw_data;
            have_lo <= 1'b1;
          end
        end else begin                               // second DW: emit a beat
          m_tdata <= {dw_data, lo_q};
          m_tkeep <= 8'hFF;
          m_tlast <= dw_last;
          m_tvalid <= 1'b1;
          have_lo <= 1'b0;
        end
      end
    end
  end
endmodule
