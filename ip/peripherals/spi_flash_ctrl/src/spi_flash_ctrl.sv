// ***************
// Filename: spi_flash_ctrl.sv
// Author: FPGA Cores 4 U
// Description: SPI NOR flash controller (single-bit SPI mode 0, 3-byte
//   addressing, e.g. W25Qxx / S25FL / MX25). Version 1.0.0. AXI4-Lite
//   registers issue generic commands - write CMD (0x00) with opcode[7:0],
//   addr_en[8], dummy bytes[15:12], read_data[16], write_data[17] after
//   setting ADDR (0x04, 24 bit) and LEN (0x08, data bytes 0..65535); the
//   controller then drives cs_n, sends opcode, address and dummy bytes and
//   moves LEN data bytes: bytes read from the flash leave on the AXI-Stream
//   master port (m_axis) and bytes to write are taken from the AXI-Stream
//   slave port (s_axis), each waiting for the stream handshake with sclk
//   stopped between bytes (so the flash never sees a gap it cannot handle,
//   and no byte is lost). Any flash command is expressible: 9F read ID, 03/0B
//   read, 06 write enable, 02 page program, 20/D8/C7 erase, 05 read status
//   (poll STATUS-of-flash yourself by issuing 05 with LEN=1). Registers -
//   0x00 CMD (write starts, reads back last), 0x04 ADDR, 0x08 LEN, 0x0C
//   CLKDIV (sclk half period in clocks, min 3, reset 4, so 12.5 MHz at 100
//   MHz), 0x10 STATUS (bit0 busy, bit1 done sticky, bit2 cmd_err sticky;
//   write 1 to clear bits 1 and 2), 0x14 IRQ_EN (bit0), 0x18 IP_VERSION. A
//   CMD written while busy is ignored and sets cmd_err. irq_o = done &
//   IRQ_EN. Clock - aclk; miso is asynchronous and double-registered, which
//   is why the half period is at least 3 clocks. Reset - synchronous aresetn,
//   cs_n high, sclk low. Timing - cs_n is asserted one half period before the
//   first sclk edge, held one half period after the last, and kept high for
//   two half periods between commands. Latency - command starts 2 clocks
//   after the CMD write; data throughput is 8 bit times per byte plus stream
//   wait. The flash write-in-progress state is the flash's own business: poll
//   it with command 05. Errors - cmd_err (command while busy); a stalled
//   stream simply pauses the transfer.
// Date: 2026-09-29
module spi_flash_ctrl (
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
  // AXI-Stream: bytes to write to the flash
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  // AXI-Stream: bytes read from the flash
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // SPI pins
  output logic        sclk_o,
  output logic        cs_n_o,
  output logic        mosi_o,
  input  logic        miso_i,
  output logic        irq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  logic [8*32-1:0] regs, rd; logic [7:0] wr_pulse; logic [31:0] wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(8), .RESET_VALS({32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'd4, 32'h0, 32'h0})) u_regs (
    .aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));
  wire [31:0] r_cmd = regs[0*32 +: 32], r_addr = regs[1*32 +: 32], r_len = regs[2*32 +: 32], r_div = regs[3*32 +: 32], r_irqen = regs[5*32 +: 32];

  typedef enum logic [3:0] {S_IDLE, S_CSLOW, S_LOAD, S_WTX, S_SHIFT, S_WRX, S_CSHOLD, S_CSGAP} st_t; st_t st;
  logic [15:0] hc; logic [7:0] tx_sr, rx_sr; logic [2:0] bit_i; logic sclk_hi, is_rx, done_f, err_f, sent_op, miso_s1, miso_s;
  logic [1:0] addr_left; logic [3:0] dummy_left; logic [15:0] data_left; logic rd_en, wr_en, last_rx;
  logic [7:0] opcode; logic [23:0] addr; logic [15:0] cs_wait;
  wire [15:0] half = (r_div[15:0] < 16'd3) ? 16'd3 : r_div[15:0];
  wire hc_done = (hc == half - 1'b1);
  wire start = wr_pulse[0] && (st == S_IDLE);
  assign cs_n_o = (st == S_IDLE) | (st == S_CSGAP);
  assign mosi_o = tx_sr[7];
  assign sclk_o = sclk_hi;
  assign s_axis_tready = (st == S_WTX);
  assign irq_o = done_f & r_irqen[0];
  always_ff @(posedge aclk) begin miso_s1 <= miso_i; miso_s <= miso_s1; end
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      st <= S_IDLE; hc <= '0; tx_sr <= '0; rx_sr <= '0; bit_i <= '0; sclk_hi <= 1'b0; is_rx <= 1'b0; done_f <= 1'b0; err_f <= 1'b0; sent_op <= 1'b0;
      addr_left <= '0; dummy_left <= '0; data_left <= '0; rd_en <= 1'b0; wr_en <= 1'b0; opcode <= '0; addr <= '0; cs_wait <= '0;
      m_axis_tdata <= '0; m_axis_tvalid <= 1'b0; m_axis_tlast <= 1'b0; last_rx <= 1'b0;
    end else begin
      if (wr_pulse[4]) begin if (wr_data[1]) done_f <= 1'b0; if (wr_data[2]) err_f <= 1'b0; end
      if (wr_pulse[0] && st != S_IDLE) err_f <= 1'b1;
      if (m_axis_tvalid && m_axis_tready) begin m_axis_tvalid <= 1'b0; m_axis_tlast <= 1'b0; end
      case (st)
        S_IDLE: begin
          sclk_hi <= 1'b0; hc <= '0;
          if (start) begin
            opcode <= wr_data[7:0]; rd_en <= wr_data[16]; wr_en <= wr_data[17];
            dummy_left <= wr_data[15:12]; addr_left <= wr_data[8] ? 2'd3 : 2'd0;
            addr <= r_addr[23:0]; data_left <= r_len[15:0]; sent_op <= 1'b0; done_f <= 1'b0; st <= S_CSLOW;
          end
        end
        S_CSLOW: begin if (hc_done) begin hc <= '0; st <= S_LOAD; end else hc <= hc + 1'b1; end
        S_LOAD: begin
          is_rx <= 1'b0; bit_i <= '0; hc <= '0;
          if (!sent_op) begin tx_sr <= opcode; sent_op <= 1'b1; st <= S_SHIFT; end
          else if (addr_left != 0) begin tx_sr <= addr[8*(addr_left-1) +: 8]; addr_left <= addr_left - 1'b1; st <= S_SHIFT; end
          else if (dummy_left != 0) begin tx_sr <= 8'h00; dummy_left <= dummy_left - 1'b1; st <= S_SHIFT; end
          else if (data_left != 0) begin
            data_left <= data_left - 1'b1; is_rx <= rd_en; last_rx <= (data_left == 16'd1);
            if (wr_en) st <= S_WTX; else begin tx_sr <= 8'h00; st <= S_SHIFT; end
          end else begin st <= S_CSHOLD; hc <= '0; end
        end
        S_WTX: if (s_axis_tvalid) begin tx_sr <= s_axis_tdata; st <= S_SHIFT; end
        S_SHIFT: begin
          if (hc_done) begin
            hc <= '0;
            if (!sclk_hi) begin sclk_hi <= 1'b1; rx_sr <= {rx_sr[6:0], miso_s}; end                     // rising edge: sample
            else begin
              sclk_hi <= 1'b0; tx_sr <= {tx_sr[6:0], 1'b0}; bit_i <= bit_i + 1'b1;                     // falling edge: shift
              if (bit_i == 3'd7) st <= st_t'(is_rx ? S_WRX : S_LOAD);
            end
          end else hc <= hc + 1'b1;
        end
        S_WRX: if (!m_axis_tvalid) begin m_axis_tdata <= rx_sr; m_axis_tvalid <= 1'b1; m_axis_tlast <= last_rx; st <= S_LOAD; end
        S_CSHOLD: begin if (hc_done) begin hc <= '0; cs_wait <= '0; st <= S_CSGAP; end else hc <= hc + 1'b1; end
        S_CSGAP: begin
          if (hc_done) begin hc <= '0; cs_wait <= cs_wait + 1'b1; end else hc <= hc + 1'b1;
          if (hc_done && cs_wait == 16'd1) begin st <= S_IDLE; done_f <= 1'b1; end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
  always_comb begin
    rd = regs;
    rd[4*32 +: 32] = {29'd0, err_f, done_f, (st != S_IDLE)};
    rd[6*32 +: 32] = IP_VERSION;
    rd[7*32 +: 32] = 32'h0;
  end
endmodule
