// ***************
// Filename: py_core_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of py_core (tb/python/py_core_tb.py compares it
//   with the golden model ip/cpu/py_core/model/py_core_model.py). Holds the
//   core's code memory (bytes) and constant pool (34-bit words), both read
//   synchronously and reloaded from the hex files named by the plusargs
//   +CODE=<file> and +CONST=<file> on each rising edge of load_i (the
//   testbench writes them full length), and an AXI4-Lite slave: a 4096-word RAM (address bits [13:2],
//   cleared by reset) with SLVERR at BAD_ADDR. With rand_ready_i low the slave has a fixed
//   timing (ready always high, BVALID / RVALID one clock after the address
//   and data handshakes: a mem32 instruction takes 3 + 2 clocks); with it
//   high, ready and response delays come from an LFSR.
//   Clock - clk. Reset - synchronous rst_n (active low).
// Date: 2026-10-20
// ***************
module py_core_cocotb_top #(
  parameter int CODE_AW     = 13,
  parameter int CONST_AW    = 8,
  parameter int STACK_DEPTH = 32,
  parameter int N_LOCALS    = 16,
  parameter int N_FRAMES    = 16,
  parameter int N_GLOBALS   = 32
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                start_i,
  input  logic                resume_i,
  input  logic [CODE_AW-1:0]  resume_pc_i,
  input  logic                irq_i,
  input  logic                load_i,         // rising edge: reload code and constants from the files
  input  logic                rand_ready_i,   // AXI slave: random delays instead of the fixed timing
  output logic                busy_o,
  output logic                done_o,
  output logic [33:0]         result_o,
  output logic                trap_o,
  output logic [3:0]          trap_cause_o,
  output logic [CODE_AW-1:0]  trap_pc_o,
  output logic [7:0]          trap_op_o,
  output logic                in_irq_o,
  // completed bus transactions (OKAY responses), for the testbench's monitor
  output logic                wr_fire_o,      // B handshake: wr_addr_o / wr_data_o written
  output logic [31:0]         wr_addr_o,
  output logic [31:0]         wr_data_o,
  output logic                rd_fire_o,      // R handshake: rd_data_o read from rd_addr_o
  output logic [31:0]         rd_addr_o,
  output logic [31:0]         rd_data_o
);
  localparam logic [31:0] BAD_ADDR = 32'h0000_BAD0;

  axil_if #(.ADDR_W(32), .DATA_W(32)) m_axil ();
  py_core_pkg::trap_e cause;
  logic [CODE_AW-1:0]  code_addr;
  logic [7:0]          code_q;
  logic [CONST_AW-1:0] const_addr;
  logic [33:0]         const_q;

  py_core #(
    .CODE_AW(CODE_AW),
    .CONST_AW(CONST_AW),
    .STACK_DEPTH(STACK_DEPTH),
    .N_LOCALS(N_LOCALS),
    .N_FRAMES(N_FRAMES),
    .N_GLOBALS(N_GLOBALS)
  ) u_core (
    .clk,
    .rst_n,
    .start_i,
    .resume_i,
    .resume_pc_i,
    .busy_o,
    .done_o,
    .result_o,
    .trap_o,
    .trap_cause_o(cause),
    .trap_pc_o,
    .trap_op_o,
    .irq_i,
    .in_irq_o,
    .code_addr_o(code_addr),
    .code_data_i(code_q),
    .const_addr_o(const_addr),
    .const_data_i(const_q),
    .m_axil(m_axil)
  );
  assign trap_cause_o = cause;

  // ---------------- code / constant memories ----------------
  logic [7:0]  code_mem  [2**CODE_AW];
  logic [33:0] const_mem [2**CONST_AW];
  string code_file, const_file;
  initial begin
    if (!$value$plusargs("CODE=%s", code_file)) code_file = "code.hex";
    if (!$value$plusargs("CONST=%s", const_file)) const_file = "const.hex";
  end
  always @(posedge load_i) begin
    $readmemh(code_file, code_mem);
    $readmemh(const_file, const_mem);
  end
  always_ff @(posedge clk) begin
    code_q <= code_mem[code_addr];
    const_q <= const_mem[const_addr];
  end

  // ---------------- AXI4-Lite slave ----------------
  logic [31:0] ram [4096];
  logic [15:0] lfsr;
  logic        aw_seen, w_seen;
  logic [31:0] aw_q, w_q, ar_q;
  logic [1:0]  bdly, rdly;
  wire         rnd = lfsr[0] ^ lfsr[3];
  wire [31:0]  wa = aw_seen ? aw_q : m_axil.awaddr;          // the write's address and data (this clock's
  wire [31:0]  wd = w_seen ? w_q : m_axil.wdata;             // handshake, or the one seen before)

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 4096; i++) ram[i] <= 32'h0;                 // each test program starts on a clear RAM
      lfsr <= 16'hACE1;
      m_axil.awready <= 1'b0;
      m_axil.wready <= 1'b0;
      m_axil.bvalid <= 1'b0;
      m_axil.bresp <= 2'b00;
      m_axil.arready <= 1'b0;
      m_axil.rvalid <= 1'b0;
      m_axil.rresp <= 2'b00;
      m_axil.rdata <= '0;
      aw_seen <= 1'b0;
      w_seen <= 1'b0;
      aw_q <= '0;
      w_q <= '0;
      ar_q <= '0;
      bdly <= '0;
      rdly <= '0;
    end else begin
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      // write channel: AW and W accepted independently, B after both
      m_axil.awready <= !aw_seen && !(m_axil.awvalid && m_axil.awready) && (!rand_ready_i || rnd);
      m_axil.wready <= !w_seen && !(m_axil.wvalid && m_axil.wready) && (!rand_ready_i || lfsr[5]);
      if (m_axil.awvalid && m_axil.awready) begin
        aw_seen <= 1'b1;
        aw_q <= m_axil.awaddr;
      end
      if (m_axil.wvalid && m_axil.wready) begin
        w_seen <= 1'b1;
        w_q <= m_axil.wdata;
      end
      if ((aw_seen || (m_axil.awvalid && m_axil.awready)) && (w_seen || (m_axil.wvalid && m_axil.wready))
          && !m_axil.bvalid) begin
        if (bdly == '0) begin
          m_axil.bvalid <= 1'b1;
          m_axil.bresp <= (wa == BAD_ADDR) ? 2'b10 : 2'b00;
          if (wa != BAD_ADDR)
            for (int b = 0; b < 4; b++) if (m_axil.wstrb[b]) ram[wa[13:2]][8*b +: 8] <= wd[8*b +: 8];
          bdly <= rand_ready_i ? lfsr[7:6] : 2'd0;
        end else bdly <= bdly - 1'b1;
      end
      if (m_axil.bvalid && m_axil.bready) begin
        m_axil.bvalid <= 1'b0;
        aw_seen <= 1'b0;
        w_seen <= 1'b0;
      end
      // read channel
      m_axil.arready <= !m_axil.rvalid && !(m_axil.arvalid && m_axil.arready) && (!rand_ready_i || lfsr[9]);
      if (m_axil.arvalid && m_axil.arready) begin
        ar_q <= m_axil.araddr;
        rdly <= rand_ready_i ? lfsr[11:10] : 2'd0;
        m_axil.rvalid <= !rand_ready_i;
        m_axil.rresp <= (m_axil.araddr == BAD_ADDR) ? 2'b10 : 2'b00;
        m_axil.rdata <= ram[m_axil.araddr[13:2]];
      end else if (rand_ready_i && !m_axil.rvalid && m_axil.rready) begin
        if (rdly == '0) m_axil.rvalid <= 1'b1;
        else rdly <= rdly - 1'b1;
      end
      if (m_axil.rvalid && m_axil.rready) m_axil.rvalid <= 1'b0;
    end
  end
  assign wr_fire_o = m_axil.bvalid && m_axil.bready && m_axil.bresp == 2'b00;
  assign wr_addr_o = aw_q;
  assign wr_data_o = w_q;
  assign rd_fire_o = m_axil.rvalid && m_axil.rready && m_axil.rresp == 2'b00;
  assign rd_addr_o = ar_q;
  assign rd_data_o = m_axil.rdata;
endmodule
