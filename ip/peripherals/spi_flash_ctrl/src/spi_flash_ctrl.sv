// ***************
// Filename: spi_flash_ctrl.sv
// Author: FPGA Cores 4 U
// Description: SPI NOR flash controller (single-bit SPI mode 0, 3-byte
//   addressing, e.g. W25Qxx / S25FL / MX25). The
//   registers (cfg_* / sts_* ports; spi_flash_ctrl_top.sv is the block with
//   its AXI4-Lite register map, src/include/spi_flash_ctrl_regs.sv, ID "SPFL"
//   / VERSION / DATE at 0x00-0x08) issue generic commands - write CMD (0x10)
//   with opcode[7:0], addr_en[8], dummy bytes[15:12], read_data[16],
//   write_data[17] after setting ADDR (0x14, 24 bit) and LEN (0x18, data
//   bytes 0..65535); the
//   controller then drives cs_n, sends opcode, address and dummy bytes and
//   moves LEN data bytes: bytes read from the flash leave on the AXI-Stream
//   master port (m_axis) and bytes to write are taken from the AXI-Stream
//   slave port (s_axis), each waiting for the stream handshake with sclk
//   stopped between bytes (so the flash never sees a gap it cannot handle,
//   and no byte is lost). Any flash command is expressible: 9F read ID, 03/0B
//   read, 06 write enable, 02 page program, 20/D8/C7 erase, 05 read status
//   (poll STATUS-of-flash yourself by issuing 05 with LEN=1). Registers -
//   0x10 CMD (write starts, reads back last), 0x14 ADDR, 0x18 LEN, 0x1C
//   CLKDIV (sclk half period in clocks, min 3, reset 4, so 12.5 MHz at 100
//   MHz; change it only between commands: the half period is compared
//   live, and lowering it below the running count stalls the command until
//   the 16-bit count wraps), 0x20 STATUS (bit0 busy, bit1 done sticky, bit2 cmd_err sticky;
//   write 1 to clear bits 1 and 2), 0x24 IRQ_EN (bit0). A
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
// Date: 2026-10-20
module spi_flash_ctrl (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI-Stream: bytes to write to the flash
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.slave s_axis,
  // AXI-Stream: bytes read from the flash
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.master m_axis,
  // SPI pins
  // spi: spi_if.master (ip/shared/src/interfaces/spi_if.sv), NUM_CS = 1 {sclk_o=sclk mosi_o=mosi miso_i=miso cs_n_o=cs_n}
  spi_if.master spi,
  output logic        irq_o,
  // register ports
  // regs: spi_flash_ctrl_regs_if.core (src/include/spi_flash_ctrl_regs_if.sv)
  spi_flash_ctrl_regs_if.core regs
);
  assign m_axis.tkeep = '1;      // not used by this block
  assign m_axis.tuser = '0;      // not used by this block
  typedef enum logic [3:0] {S_IDLE, S_CSLOW, S_LOAD, S_WTX, S_SHIFT, S_WRX, S_CSHOLD, S_CSGAP} st_t;
  st_t st;
  logic [15:0] hc;
  logic [7:0] tx_sr, rx_sr;
  logic [2:0] bit_i;
  logic sclk_hi, is_rx, done_f, err_f, sent_op;
  (* async_reg = "true" *) logic miso_s1, miso_s;      // MISO synchroniser
  logic [1:0] addr_left;
  logic [3:0] dummy_left;
  logic [15:0] data_left;
  logic rd_en, wr_en, last_rx;
  logic [7:0] opcode;
  logic [23:0] addr;
  logic [15:0] cs_wait;
  wire [15:0] half = (regs.cfg_clkdiv < 16'd3) ? 16'd3 : regs.cfg_clkdiv;
  wire hc_done = (hc == half - 1'b1);
  wire [4:0] addr_sh = {addr_left - 2'd1, 3'b000};     // the address byte addr_left - 1 (MSB first)
  wire start = regs.cfg_cmd_wr && (st == S_IDLE);
  assign spi.cs_n = (st == S_IDLE) | (st == S_CSGAP);
  assign spi.mosi = tx_sr[7];
  assign spi.sclk = sclk_hi;
  assign s_axis.tready = (st == S_WTX);
  assign irq_o = done_f & regs.cfg_irq_en;
  // MISO synchroniser: no reset (it only carries the line; its value is used in shift clocks, long after reset)
  always_ff @(posedge aclk) begin
    miso_s1 <= spi.miso;
    miso_s <= miso_s1;
  end
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      st <= S_IDLE;
      hc <= '0;
      tx_sr <= '0;
      rx_sr <= '0;
      bit_i <= '0;
      sclk_hi <= 1'b0;
      is_rx <= 1'b0;
      done_f <= 1'b0;
      err_f <= 1'b0;
      sent_op <= 1'b0;
      addr_left <= '0;
      dummy_left <= '0;
      data_left <= '0;
      rd_en <= 1'b0;
      wr_en <= 1'b0;
      opcode <= '0;
      addr <= '0;
      cs_wait <= '0;
      m_axis.tdata <= '0;
      m_axis.tvalid <= 1'b0;
      m_axis.tlast <= 1'b0;
      last_rx <= 1'b0;
    end else begin
      if (regs.cfg_status_wr) begin
        if (regs.cfg_status[1]) done_f <= 1'b0;
        if (regs.cfg_status[2]) err_f <= 1'b0;
      end
      if (regs.cfg_cmd_wr && st != S_IDLE) err_f <= 1'b1;
      if (m_axis.tvalid && m_axis.tready) begin
        m_axis.tvalid <= 1'b0;
        m_axis.tlast <= 1'b0;
      end
      case (st)
        S_IDLE: begin
          sclk_hi <= 1'b0;
          hc <= '0;
          if (start) begin
            opcode <= regs.cfg_cmd[7:0];
            rd_en <= regs.cfg_cmd[16];
            wr_en <= regs.cfg_cmd[17];
            dummy_left <= regs.cfg_cmd[15:12];
            addr_left <= regs.cfg_cmd[8] ? 2'd3 : 2'd0;
            addr <= regs.cfg_addr;
            data_left <= regs.cfg_len;
            sent_op <= 1'b0;
            done_f <= 1'b0;
            st <= S_CSLOW;
          end
        end
        S_CSLOW: begin
          if (hc_done) begin
            hc <= '0;
            st <= S_LOAD;
          end else hc <= hc + 1'b1;
        end
        S_LOAD: begin
          is_rx <= 1'b0;
          bit_i <= '0;
          hc <= '0;
          if (!sent_op) begin
            tx_sr <= opcode;
            sent_op <= 1'b1;
            st <= S_SHIFT;
          end
          else if (addr_left != 0) begin
            tx_sr <= addr[addr_sh +: 8];
            addr_left <= addr_left - 1'b1;
            st <= S_SHIFT;
          end
          else if (dummy_left != 0) begin
            tx_sr <= 8'h00;
            dummy_left <= dummy_left - 1'b1;
            st <= S_SHIFT;
          end
          else if (data_left != 0) begin
            data_left <= data_left - 1'b1;
            is_rx <= rd_en;
            last_rx <= (data_left == 16'd1);
            if (wr_en) st <= S_WTX;
            else begin
              tx_sr <= 8'h00;
              st <= S_SHIFT;
            end
          end else begin
            st <= S_CSHOLD;
            hc <= '0;
          end
        end
        S_WTX: if (s_axis.tvalid) begin
          tx_sr <= s_axis.tdata;
          st <= S_SHIFT;
        end
        S_SHIFT: begin
          if (hc_done) begin
            hc <= '0;
            if (!sclk_hi) begin // rising edge: sample
              sclk_hi <= 1'b1;
              rx_sr <= {rx_sr[6:0], miso_s};
            end
            else begin
              sclk_hi <= 1'b0; // falling edge: shift
              tx_sr <= {tx_sr[6:0], 1'b0};
              bit_i <= bit_i + 1'b1;
              if (bit_i == 3'd7) st <= st_t'(is_rx ? S_WRX : S_LOAD);
            end
          end else hc <= hc + 1'b1;
        end
        S_WRX: if (!m_axis.tvalid) begin
          m_axis.tdata <= rx_sr;
          m_axis.tvalid <= 1'b1;
          m_axis.tlast <= last_rx;
          st <= S_LOAD;
        end
        S_CSHOLD: begin
          if (hc_done) begin
            hc <= '0;
            cs_wait <= '0;
            st <= S_CSGAP;
          end else hc <= hc + 1'b1;
        end
        S_CSGAP: begin
          if (hc_done) begin
            hc <= '0;
            cs_wait <= cs_wait + 1'b1;
          end else hc <= hc + 1'b1;
          if (hc_done && cs_wait == 16'd1) begin
            st <= S_IDLE;
            done_f <= 1'b1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
  assign regs.sts_status = {err_f, done_f, (st != S_IDLE)};

  // not used: CMD bits outside opcode / address / dummy / read / write, write pulses of registers acting by
  // value, STATUS bit 0 (not a flag)
  wire unused_ok = &{1'b0, regs.cfg_cmd[31:18], regs.cfg_cmd[11:9], regs.cfg_addr_wr, regs.cfg_len_wr,
                     regs.cfg_clkdiv_wr, regs.cfg_status[0], regs.cfg_irq_en_wr};
endmodule
