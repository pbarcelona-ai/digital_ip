// ***************
// Filename: py_boot.sv
// Author: FPGA Cores 4 U
// Description: Flash boot loader for py_soc. After reset it is the bus
//   master: it programs spi_flash_ctrl through its registers (FLASH_REGS)
//   and reads the bytes back through the flash data port (FLASH_PORT,
//   py_stream_port RXDATA), copying a pyc.py image from serial NOR flash
//   into code and constant memory. Image at BOOT_ADDR, little endian -
//     0..3   magic "PYC1"
//     4..5   code length in bytes (1..2**CODE_AW)
//     6..7   constant count (0..2**CONST_AW)
//     8..11  32-bit sum of every payload byte
//     12..   code bytes, then each constant as 5 bytes ([33:0] used)
//   Two flash READ (03h) commands are issued: the 12-byte header, then the
//   payload. done_o rises once the checksum matches; err_o and err_code_o
//   report a bad image and the core is not started. Errors - 1 bad magic,
//   2 sizes out of range, 3 checksum, 4 bus error, 5 no flash data (no
//   byte for 65536 consecutive polls). Clock - clk only. Reset -
//   synchronous rst_n (active low); the copy starts on its release.
// Date: 2026-10-01
module py_boot #(
  parameter int          CODE_AW      = 13,
  parameter int          CONST_AW     = 8,
  parameter logic [31:0] FLASH_REGS   = 32'h0000_C000,
  parameter logic [31:0] FLASH_PORT   = 32'h0000_C100,
  parameter logic [23:0] BOOT_ADDR    = 24'h00_0000,
  parameter int          FLASH_CLKDIV = 4            // sclk half period in clocks (>= 3)
) (
  input  logic                clk,
  input  logic                rst_n,
  output logic                busy_o,
  output logic                done_o,
  output logic                err_o,
  output logic [2:0]          err_code_o,
  // Memory write ports
  output logic                code_we_o,
  output logic [CODE_AW-1:0]  code_waddr_o,
  output logic [7:0]          code_wdata_o,
  output logic                const_we_o,
  output logic [CONST_AW-1:0] const_waddr_o,
  output logic [33:0]         const_wdata_o,
  // AXI4-Lite master
  output logic [31:0]         m_axil_awaddr,
  output logic                m_axil_awvalid,
  input  logic                m_axil_awready,
  output logic [31:0]         m_axil_wdata,
  output logic [3:0]          m_axil_wstrb,
  output logic                m_axil_wvalid,
  input  logic                m_axil_wready,
  input  logic [1:0]          m_axil_bresp,
  input  logic                m_axil_bvalid,
  output logic                m_axil_bready,
  output logic [31:0]         m_axil_araddr,
  output logic                m_axil_arvalid,
  input  logic                m_axil_arready,
  input  logic [31:0]         m_axil_rdata,
  input  logic [1:0]          m_axil_rresp,
  input  logic                m_axil_rvalid,
  output logic                m_axil_rready
);
  localparam logic [31:0] MAGIC    = 32'h3143_5950;               // "PYC1"
  localparam logic [31:0] CMD_READ = 32'h0001_0103;               // 03h, address, read data
  localparam int HDR_BYTES = 12;
  localparam logic [31:0] F_CMD = FLASH_REGS + 32'h00, F_ADDR = FLASH_REGS + 32'h04,
                          F_LEN = FLASH_REGS + 32'h08, F_DIV  = FLASH_REGS + 32'h0C,
                          P_RX  = FLASH_PORT + 32'h04;

  typedef enum logic [3:0] {S_DIV, S_ADDR, S_LEN, S_CMD, S_HDR, S_CHECK, S_ADDR2, S_LEN2, S_CMD2, S_DATA,
                            S_SUM, S_DONE, S_ERR} state_e;
  state_e st;

  // ---------------- one bus operation at a time ----------------
  typedef enum logic [1:0] {B_IDLE, B_WR, B_RD} bus_e;
  bus_e bst;
  logic op_done, op_err, aw_ok, w_ok;
  logic [31:0] op_rdata;
  assign m_axil_wstrb = 4'hF;

  logic [95:0]  hdr;                     // header bytes, byte 0 in [7:0]
  logic [3:0]   hcnt;
  logic [15:0]  idx, payload;
  logic [31:0]  sum;
  logic [31:0]  cbuf;                    // first 4 bytes of a constant
  logic [2:0]   cbyte;
  logic [CONST_AW:0] cidx;
  logic [15:0]  idle_polls;
  wire  [15:0]  code_len  = hdr[47:32];
  wire  [15:0]  const_cnt = hdr[63:48];
  wire  [7:0]   rx_byte   = op_rdata[7:0];
  wire          rx_valid  = op_rdata[31];

  assign busy_o = (st != S_DONE) && (st != S_ERR);
  assign done_o = (st == S_DONE);
  assign err_o  = (st == S_ERR);

  always_ff @(posedge clk) begin : p_seq
    logic do_wr, do_rd; // bus request from the sequencer, this clock
    logic [31:0] do_a, do_d;
    do_wr = 1'b0;
    do_rd = 1'b0;
    do_a = '0;
    do_d = '0;
    if (!rst_n) begin
      st <= S_DIV;
      bst <= B_IDLE;
      op_done <= 1'b0;
      op_err <= 1'b0;
      op_rdata <= '0;
      aw_ok <= 1'b0;
      w_ok <= 1'b0;
      m_axil_awaddr <= '0;
      m_axil_wdata <= '0;
      m_axil_araddr <= '0;
      m_axil_awvalid <= 1'b0;
      m_axil_wvalid <= 1'b0;
      m_axil_bready <= 1'b0;
      m_axil_arvalid <= 1'b0;
      m_axil_rready <= 1'b0;
      hdr <= '0;
      hcnt <= '0;
      idx <= '0;
      payload <= '0;
      sum <= '0;
      cbuf <= '0;
      cbyte <= '0;
      cidx <= '0;
      idle_polls <= '0;
      err_code_o <= '0;
      code_we_o <= 1'b0;
      const_we_o <= 1'b0;
      code_waddr_o <= '0;
      code_wdata_o <= '0;
      const_waddr_o <= '0;
      const_wdata_o <= '0;
    end else begin
      code_we_o <= 1'b0;
      const_we_o <= 1'b0;
      op_done <= 1'b0;

      // Bus engine: op_done pulses for one clock with op_err / op_rdata
      case (bst)
        B_WR: begin
          if (m_axil_awvalid && m_axil_awready) begin
            m_axil_awvalid <= 1'b0;
            aw_ok <= 1'b1;
          end
          if (m_axil_wvalid  && m_axil_wready)  begin
            m_axil_wvalid  <= 1'b0;
            w_ok  <= 1'b1;
          end
          if ((aw_ok || (m_axil_awvalid && m_axil_awready)) && (w_ok || (m_axil_wvalid && m_axil_wready))) m_axil_bready <= 1'b1;
          if (m_axil_bready && m_axil_bvalid) begin
            m_axil_bready <= 1'b0;
            op_done <= 1'b1;
            op_err <= (m_axil_bresp != 2'b00);
            bst <= B_IDLE;
          end
        end
        B_RD: begin
          if (m_axil_arvalid && m_axil_arready) begin
            m_axil_arvalid <= 1'b0;
            m_axil_rready <= 1'b1;
          end
          if (m_axil_rready && m_axil_rvalid) begin
            m_axil_rready <= 1'b0;
            op_done <= 1'b1;
            op_err <= (m_axil_rresp != 2'b00);
            op_rdata <= m_axil_rdata;
            bst <= B_IDLE;
          end
        end
        default: ;
      endcase

      // Sequencer: runs when the bus engine is idle. In a write state op_done
      // means that state's write finished; otherwise the write is issued.
      if (op_done && op_err && st != S_DONE && st != S_ERR) begin
        err_code_o <= 3'd4;
        st <= S_ERR;
      end else if (bst == B_IDLE) case (st)
        S_DIV:
          if (op_done) st <= S_ADDR;
          else begin
            do_wr = 1'b1;
            do_a = F_DIV;
            do_d = 32'(FLASH_CLKDIV);
          end
        S_ADDR:
          if (op_done) st <= S_LEN;
          else begin
            do_wr = 1'b1;
            do_a = F_ADDR;
            do_d = {8'd0, BOOT_ADDR};
          end
        S_LEN:
          if (op_done) st <= S_CMD;
          else begin
            do_wr = 1'b1;
            do_a = F_LEN;
            do_d = HDR_BYTES;
          end
        S_CMD:
          if (op_done) st <= S_HDR;
          else begin
            do_wr = 1'b1;
            do_a = F_CMD;
            do_d = CMD_READ;
          end
        S_HDR: begin
          if (op_done) begin
            if (rx_valid) begin
              hdr <= {rx_byte, hdr[95:8]};
              hcnt <= hcnt + 1'b1;
              idle_polls <= '0;
              if (hcnt == HDR_BYTES - 1) st <= S_CHECK;
            end else if (idle_polls == 16'hFFFF) begin
              err_code_o <= 3'd5;
              st <= S_ERR;
            end
            else idle_polls <= idle_polls + 1'b1;
          end
          if (!(op_done && rx_valid && hcnt == HDR_BYTES - 1)) begin
            do_rd = 1'b1;
            do_a = P_RX;
          end
        end
        S_CHECK: begin
          if (hdr[31:0] != MAGIC) begin
            err_code_o <= 3'd1;
            st <= S_ERR;
          end
          else if (code_len == 0 || code_len > 2**CODE_AW || const_cnt > 2**CONST_AW) begin
            err_code_o <= 3'd2;
            st <= S_ERR;
          end
          else begin
            payload <= code_len + 16'(const_cnt * 5);
            st <= S_ADDR2;
          end
        end
        S_ADDR2:
          if (op_done) st <= S_LEN2;
          else begin
            do_wr = 1'b1;
            do_a = F_ADDR;
            do_d = {8'd0, BOOT_ADDR + 24'(HDR_BYTES)};
          end
        S_LEN2:
          if (op_done) st <= S_CMD2;
          else begin
            do_wr = 1'b1;
            do_a = F_LEN;
            do_d = {16'd0, payload};
          end
        S_CMD2:
          if (op_done) st <= S_DATA;
          else begin
            do_wr = 1'b1;
            do_a = F_CMD;
            do_d = CMD_READ;
          end
        S_DATA: begin
          if (op_done) begin
            if (rx_valid) begin
              sum <= sum + {24'd0, rx_byte};
              idx <= idx + 1'b1;
              idle_polls <= '0;
              if (idx < code_len) begin
                code_we_o <= 1'b1;
                code_waddr_o <= idx[CODE_AW-1:0];
                code_wdata_o <= rx_byte;
              end else if (cbyte == 3'd4) begin
                const_we_o <= 1'b1;
                const_waddr_o <= cidx[CONST_AW-1:0];
                const_wdata_o <= {rx_byte[1:0], cbuf};
                cidx <= cidx + 1'b1;
                cbyte <= '0;
              end else begin
                cbuf <= {rx_byte, cbuf[31:8]};
                cbyte <= cbyte + 1'b1;
              end
              if (idx == payload - 1'b1) st <= S_SUM;
            end else if (idle_polls == 16'hFFFF) begin
              err_code_o <= 3'd5;
              st <= S_ERR;
            end
            else idle_polls <= idle_polls + 1'b1;
          end
          if (!(op_done && rx_valid && idx == payload - 1'b1)) begin
            do_rd = 1'b1;
            do_a = P_RX;
          end
        end
        S_SUM:
          if (sum == hdr[95:64]) st <= S_DONE;
          else begin
            err_code_o <= 3'd3;
            st <= S_ERR;
          end
        default: ;                                        // S_DONE / S_ERR: bus released
      endcase

      if (do_wr) begin
        m_axil_awaddr <= do_a;
        m_axil_wdata <= do_d;
        m_axil_awvalid <= 1'b1;
        m_axil_wvalid <= 1'b1;
        aw_ok <= 1'b0;
        w_ok <= 1'b0;
        bst <= B_WR;
      end else if (do_rd) begin
        m_axil_araddr <= do_a;
        m_axil_arvalid <= 1'b1;
        bst <= B_RD;
      end
    end
  end
endmodule
