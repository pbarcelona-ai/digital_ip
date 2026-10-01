// ***************
// Filename: memory_arbiter.sv
// Author: FPGA Cores 4 U
// Description: Arbiter between CLIENTS memory clients and one memory port.
//   Version 1.0.0. Each client presents req/we/addr/wdata with a ready
//   handshake (a request is accepted when c_req and c_ready are both
//   high). PRIORITY 0 is round-robin (fair, last granted client has lowest
//   priority next), 1 is fixed priority with client 0 highest. Read
//   responses come back in order from the memory (m_rvalid_i/m_rdata_i,
//   any fixed or variable latency) and are routed to the client that
//   issued the read using an internal order FIFO of MAX_OUT entries; new
//   reads are stalled when it is full. Writes need no response. Clock -
//   clk. Reset - synchronous active low. Latency - grant is combinational
//   (0 clocks from request to m_req when m_ready_i); read data is passed
//   through with 0 added latency. Timing - address and data muxes are
//   CLIENTS wide, register client outputs for large CLIENTS at 100 MHz.
//   Errors - a memory response with no outstanding read raises err_o
//   (sticky, cleared by clr_err_i).
// Date: 2026-09-29
module memory_arbiter #(
  parameter int CLIENTS  = 4,
  parameter int ADDR_W   = 16,
  parameter int DATA_W   = 32,
  parameter int PRIORITY = 0,            // 0 round-robin, 1 fixed
  parameter int MAX_OUT  = 4             // outstanding reads (power of two)
) (
  input  logic                       clk,
  input  logic                       rst_n,
  // Client side (packed vectors)
  input  logic [CLIENTS-1:0]         c_req_i,
  input  logic [CLIENTS-1:0]         c_we_i,
  input  logic [CLIENTS*ADDR_W-1:0]  c_addr_i,
  input  logic [CLIENTS*DATA_W-1:0]  c_wdata_i,
  output logic [CLIENTS-1:0]         c_ready_o,
  output logic [CLIENTS-1:0]         c_rvalid_o,
  output logic [DATA_W-1:0]          c_rdata_o,       // shared read data bus
  // Memory side
  output logic                       m_req_o,
  output logic                       m_we_o,
  output logic [ADDR_W-1:0]          m_addr_o,
  output logic [DATA_W-1:0]          m_wdata_o,
  input  logic                       m_ready_i,
  input  logic                       m_rvalid_i,
  input  logic [DATA_W-1:0]          m_rdata_i,
  input  logic                       clr_err_i,
  output logic                       err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int IW = (CLIENTS > 1) ? $clog2(CLIENTS) : 1;
  localparam int OW = $clog2(MAX_OUT);
  if (CLIENTS < 1) begin : g_bc $error("memory_arbiter: CLIENTS must be >= 1"); end
  if (PRIORITY < 0 || PRIORITY > 1) begin : g_bp $error("memory_arbiter: PRIORITY must be 0 or 1"); end
  if (MAX_OUT < 2 || (MAX_OUT & (MAX_OUT - 1)) != 0) begin : g_bo $error("memory_arbiter: MAX_OUT must be a power of two >= 2"); end

  int arb_idx;
  logic [IW-1:0] last;                   // last granted client
  logic [IW-1:0] sel; logic sel_v;
  // Outstanding read order FIFO
  logic [IW-1:0] ord [0:MAX_OUT-1];
  logic [OW:0]   o_wr, o_rd;
  wire  ord_full = ((o_wr - o_rd) == MAX_OUT);
  wire  ord_empty = (o_wr == o_rd);

  // Pick a client (requests that are reads are blocked when the order FIFO is full)
  logic [CLIENTS-1:0] elig;
  always_comb begin
    for (int i = 0; i < CLIENTS; i++) elig[i] = c_req_i[i] & ~(~c_we_i[i] & ord_full);
    sel = '0; sel_v = 1'b0;
    if (PRIORITY == 1) begin
      for (int i = CLIENTS-1; i >= 0; i--) if (elig[i]) begin sel = IW'(i); sel_v = 1'b1; end
    end else begin
      // first eligible client after 'last', wrapping around
      for (int k = CLIENTS; k >= 1; k--) begin
        arb_idx = (32'(last) + k) % CLIENTS;
        if (elig[arb_idx]) begin sel = IW'(arb_idx); sel_v = 1'b1; end
      end
    end
  end

  assign m_req_o   = sel_v;
  assign m_we_o    = c_we_i[sel];
  assign m_addr_o  = c_addr_i[sel*ADDR_W +: ADDR_W];
  assign m_wdata_o = c_wdata_i[sel*DATA_W +: DATA_W];
  wire   accept    = sel_v & m_ready_i;
  always_comb begin
    c_ready_o = '0;
    if (accept) c_ready_o[sel] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin last <= '0; o_wr <= '0; o_rd <= '0; err_o <= 1'b0; end
    else begin
      if (accept) begin
        last <= sel;
        if (!m_we_o) begin ord[o_wr[OW-1:0]] <= sel; o_wr <= o_wr + 1'b1; end
      end
      if (m_rvalid_i) begin
        if (ord_empty) err_o <= 1'b1; else o_rd <= o_rd + 1'b1;
      end
      if (clr_err_i) err_o <= 1'b0;
    end
  end
  always_comb begin
    c_rvalid_o = '0;
    if (m_rvalid_i && !ord_empty) c_rvalid_o[ord[o_rd[OW-1:0]]] = 1'b1;
  end
  assign c_rdata_o = m_rdata_i;
endmodule
