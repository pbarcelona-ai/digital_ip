// ***************
// Filename: axil_split.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite 1-to-2 address decoder (interconnect).
//   Routes each transaction from one master port to one of two slave ports
//   by address bit SEL_BIT: bit = 0 -> port m0, bit = 1 -> port m1. The
//   full address is forwarded; each slave uses the low bits it needs.
//   One write and one read can be in flight at a time (independently).
//   AW and W may arrive in any order; they are held until both are present,
//   then issued together to the selected slave. Slave responses (BRESP /
//   RRESP / RDATA) are passed back unchanged.
//   Latency: 1-2 cycles per channel added to each transaction.
//   Dependencies: none
// Date: 2026-09-26

module axil_split #(
  parameter int ADDR_W  = 15,              // master address width
  parameter int SEL_BIT = ADDR_W - 1       // address bit that selects the port
)(
  input  logic              clk,
  input  logic              rst_n,
  // ---------------- slave port (from the master)
  input  logic [ADDR_W-1:0] s_awaddr,
  input  logic              s_awvalid,
  output logic              s_awready,
  input  logic [31:0]       s_wdata,
  input  logic [3:0]        s_wstrb,
  input  logic              s_wvalid,
  output logic              s_wready,
  output logic [1:0]        s_bresp,
  output logic              s_bvalid,
  input  logic              s_bready,
  input  logic [ADDR_W-1:0] s_araddr,
  input  logic              s_arvalid,
  output logic              s_arready,
  output logic [31:0]       s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rvalid,
  input  logic              s_rready,
  // ---------------- master ports (to the two slaves), port i in slice i
  output logic [2*ADDR_W-1:0] m_awaddr,
  output logic [1:0]          m_awvalid,
  input  logic [1:0]          m_awready,
  output logic [63:0]         m_wdata,
  output logic [7:0]          m_wstrb,
  output logic [1:0]          m_wvalid,
  input  logic [1:0]          m_wready,
  input  logic [3:0]          m_bresp,
  input  logic [1:0]          m_bvalid,
  output logic [1:0]          m_bready,
  output logic [2*ADDR_W-1:0] m_araddr,
  output logic [1:0]          m_arvalid,
  input  logic [1:0]          m_arready,
  input  logic [63:0]         m_rdata,
  input  logic [3:0]          m_rresp,
  input  logic [1:0]          m_rvalid,
  output logic [1:0]          m_rready
);

  // ===================================================================== write
  typedef enum logic [1:0] {W_COLLECT, W_ISSUE, W_RESP, W_REPLY} wstate_t;
  wstate_t           wst;
  logic              aw_held, w_held, aw_sent, w_sent, wsel;
  logic [ADDR_W-1:0] awaddr_q;
  logic [31:0]       wdata_q;
  logic [3:0]        wstrb_q;

  assign s_awready = (wst == W_COLLECT) && !aw_held;
  assign s_wready  = (wst == W_COLLECT) && !w_held;

  always_comb begin
    for (int i = 0; i < 2; i++) begin
      m_awaddr[i*ADDR_W +: ADDR_W] = awaddr_q;
      m_wdata[i*32 +: 32]          = wdata_q;
      m_wstrb[i*4 +: 4]            = wstrb_q;
      m_awvalid[i] = (wst == W_ISSUE) && (wsel == 1'(i)) && !aw_sent;
      m_wvalid[i]  = (wst == W_ISSUE) && (wsel == 1'(i)) && !w_sent;
      m_bready[i]  = (wst == W_RESP)  && (wsel == 1'(i));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_COLLECT; aw_held <= 0; w_held <= 0; aw_sent <= 0; w_sent <= 0; wsel <= 0;
      awaddr_q <= '0; wdata_q <= '0; wstrb_q <= '0; s_bvalid <= 0; s_bresp <= '0;
    end else begin
      case (wst)
        W_COLLECT: begin
          if (s_awvalid && s_awready) begin aw_held <= 1; awaddr_q <= s_awaddr; end
          if (s_wvalid && s_wready)   begin w_held <= 1; wdata_q <= s_wdata; wstrb_q <= s_wstrb; end
          if ((aw_held || (s_awvalid && s_awready)) && (w_held || (s_wvalid && s_wready))) begin
            wst     <= W_ISSUE;
            wsel    <= aw_held ? awaddr_q[SEL_BIT] : s_awaddr[SEL_BIT];
            aw_sent <= 0;
            w_sent  <= 0;
          end
        end
        W_ISSUE: begin
          logic aw_ok, w_ok;
          aw_ok = aw_sent || (m_awvalid[wsel] && m_awready[wsel]);
          w_ok  = w_sent  || (m_wvalid[wsel]  && m_wready[wsel]);
          aw_sent <= aw_ok;
          w_sent  <= w_ok;
          if (aw_ok && w_ok) wst <= W_RESP;
        end
        W_RESP: begin
          if (m_bvalid[wsel]) begin
            s_bresp  <= m_bresp[wsel*2 +: 2];
            s_bvalid <= 1;
            wst      <= W_REPLY;
          end
        end
        W_REPLY: begin
          if (s_bready) begin
            s_bvalid <= 0;
            aw_held  <= 0;
            w_held   <= 0;
            wst      <= W_COLLECT;
          end
        end
        default: wst <= W_COLLECT;
      endcase
    end
  end

  // ===================================================================== read
  typedef enum logic [1:0] {R_IDLE, R_ISSUE, R_RESP, R_REPLY} rstate_t;
  rstate_t           rst_q;
  logic              rsel;
  logic [ADDR_W-1:0] araddr_q;

  assign s_arready = (rst_q == R_IDLE);

  always_comb begin
    for (int i = 0; i < 2; i++) begin
      m_araddr[i*ADDR_W +: ADDR_W] = araddr_q;
      m_arvalid[i] = (rst_q == R_ISSUE) && (rsel == 1'(i));
      m_rready[i]  = (rst_q == R_RESP)  && (rsel == 1'(i));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_q <= R_IDLE; rsel <= 0; araddr_q <= '0;
      s_rvalid <= 0; s_rdata <= '0; s_rresp <= '0;
    end else begin
      case (rst_q)
        R_IDLE: if (s_arvalid) begin
          araddr_q <= s_araddr;
          rsel     <= s_araddr[SEL_BIT];
          rst_q    <= R_ISSUE;
        end
        R_ISSUE: if (m_arready[rsel]) rst_q <= R_RESP;
        R_RESP: if (m_rvalid[rsel]) begin
          s_rdata  <= m_rdata[rsel*32 +: 32];
          s_rresp  <= m_rresp[rsel*2 +: 2];
          s_rvalid <= 1;
          rst_q    <= R_REPLY;
        end
        R_REPLY: if (s_rready) begin
          s_rvalid <= 0;
          rst_q    <= R_IDLE;
        end
        default: rst_q <= R_IDLE;
      endcase
    end
  end

endmodule
