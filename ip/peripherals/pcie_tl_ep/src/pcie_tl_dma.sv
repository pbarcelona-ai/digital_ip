// ***************
// Filename: pcie_tl_dma.sv
// Author: FPGA Cores 4 U
// Description: Device to host DMA write engine. When enabled, bus mastering
//   is on and the source FIFO holds at least one burst, it emits a Memory
//   Write TLP (3DW header, or 4DW when the address is above 4 GB) followed by
//   LEN payload DWs pulled from the stream FIFO. The destination address
//   advances by the burst size after every TLP and the tag increments. The
//   caller must keep bursts inside a 4 KB boundary as required by the PCIe
//   specification. Version 1.0.0. Clock - the clock of the parent block, all
//   signals are synchronous to it. Reset - synchronous, driven by the parent
//   block. Latency - as documented in the parent block, fixed and independent
//   of data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
//   signals are synchronous to it. Reset - synchronous, driven by the parent
//   block. Latency - as documented in the parent block, fixed and independent
//   of data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module pcie_tl_dma #(
  parameter int MAX_PAYLOAD_DW = 32       // largest burst (DWs)
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en_i,
  input  logic        bus_master_i,       // command[2] from config space
  input  logic [15:0] req_id_i,           // requester ID = completer ID
  input  logic        addr_load_i,        // pulse: load address registers
  input  logic [63:0] addr_i,
  input  logic [9:0]  len_dw_i,           // burst length in DWs (1..MAX)
  // Source FIFO (32 bit words)
  input  logic [31:0] f_data,
  input  logic        f_valid,
  output logic        f_ready,
  input  logic [15:0] f_level,
  // TLP DW stream out
  output logic [31:0] tx_dw,
  output logic        tx_last,
  output logic        tx_valid,
  input  logic        tx_ready,
  // Status
  output logic        busy_o,
  output logic        tlp_o,              // one clock per TLP sent
  output logic [63:0] cur_addr_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (MAX_PAYLOAD_DW < 1 || MAX_PAYLOAD_DW > 1024) begin : g_chk_mp $error("pcie_tl_dma: MAX_PAYLOAD_DW must be 1..1024"); end
  typedef enum logic [2:0] { D_IDLE, D_H0, D_H1, D_H2, D_H3, D_DATA } dstate_t;
  dstate_t state;

  logic [63:0] cur_addr;
  logic [9:0]  len, cnt;
  logic [7:0]  tag;
  logic        use4;
  wire  [9:0]  len_clip = (len_dw_i > MAX_PAYLOAD_DW[9:0]) ? MAX_PAYLOAD_DW[9:0] : len_dw_i;
  wire         go = en_i & bus_master_i & (len_clip != 10'd0) &
                    (f_level >= {6'd0, len_clip});

  assign busy_o     = (state != D_IDLE);
  assign cur_addr_o = cur_addr;

  // Header / payload multiplexer
  always_comb begin
    tx_dw = 32'd0; tx_valid = 1'b0; tx_last = 1'b0; f_ready = 1'b0;
    case (state)
      D_H0: begin
        tx_dw = {(use4 ? 3'b011 : 3'b010), 5'b00000, 1'b0, 3'b000, 4'b0000,
                 1'b0, 1'b0, 2'b00, 2'b00, len};
        tx_valid = 1'b1;
      end
      D_H1: begin
        tx_dw = {req_id_i, tag, ((len == 10'd1) ? 4'h0 : 4'hF), 4'hF};
        tx_valid = 1'b1;
      end
      D_H2: begin
        tx_dw = use4 ? cur_addr[63:32] : {cur_addr[31:2], 2'b00};
        tx_valid = 1'b1;
      end
      D_H3: begin
        tx_dw = {cur_addr[31:2], 2'b00}; tx_valid = 1'b1;
      end
      D_DATA: begin
        tx_dw = f_data; tx_valid = f_valid; f_ready = tx_ready;
        tx_last = (cnt == len - 10'd1);
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= D_IDLE; cur_addr <= '0; len <= '0; cnt <= '0; tag <= '0;
      use4 <= 1'b0; tlp_o <= 1'b0;
    end else begin
      tlp_o <= 1'b0;
      if (addr_load_i) cur_addr <= addr_i;
      case (state)
        D_IDLE: if (go) begin
          len <= len_clip; cnt <= '0; use4 <= (cur_addr[63:32] != 32'd0);
          state <= D_H0;
        end
        D_H0: if (tx_ready) state <= D_H1;
        D_H1: if (tx_ready) state <= D_H2;
        D_H2: if (tx_ready) state <= use4 ? D_H3 : D_DATA;
        D_H3: if (tx_ready) state <= D_DATA;
        D_DATA: if (tx_valid & tx_ready) begin
          cnt <= cnt + 10'd1;
          if (tx_last) begin
            state    <= D_IDLE;
            cur_addr <= cur_addr + {52'd0, len, 2'b00};    // advance
            tag      <= tag + 8'd1;
            tlp_o    <= 1'b1;
          end
        end
        default: state <= D_IDLE;
      endcase
    end
  end
endmodule
