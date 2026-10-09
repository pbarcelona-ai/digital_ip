// ***************
// Filename: axi4_lite_slave.sv
// Author: FPGA Cores 4 U
// Description: Generic AXI4-Lite slave front end. Version 1.0.0. Converts
//   AXI4-Lite transactions into a simple register-access interface for
//   user logic: a write strobe (wr_en_o with addr, data, byte strobes) and
//   a read request (rd_en_o with addr) completed by the user through
//   rd_valid_i/rd_data_i (or immediately when READ_WAIT=0, data taken
//   combinationally from rd_data_i in the cycle after rd_en_o). Write
//   address and data channels are accepted independently and combined. The
//   user may flag an error on either access (wr_err_i, valid two clocks
//   after wr_en_o starts, i.e. the clock after it ends; rd_err_i with the
//   read data) which returns SLVERR; an access to an address >=
//   ADDR_LIMIT_W-mapped range returns DECERR. Clock - aclk only. Reset -
//   synchronous aresetn (active low), all channels idle. Latency - write:
//   2 clocks from both AW and W accepted to bvalid; read: 2 clocks (+ user
//   latency). One transaction outstanding per direction. Errors -
//   SLVERR/DECERR as above; ADDR_W < 2 rejected at elaboration.
// Date: 2026-09-29
module axi4_lite_slave #(
  parameter int ADDR_W     = 8,
  parameter int READ_WAIT  = 0,            // 0: rd_data_i valid the cycle after rd_en_o; 1: wait for rd_valid_i
  parameter int MAP_WORDS  = 0             // 0: full address space valid, else words [0, MAP_WORDS) valid
) (
  input  logic              aclk,
  input  logic              aresetn,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // User register interface
  output logic              wr_en_o,       // one clock
  output logic [ADDR_W-1:0] wr_addr_o,
  output logic [31:0]       wr_data_o,
  output logic [3:0]        wr_strb_o,
  input  logic              wr_err_i,      // sampled in the cycle after wr_en_o
  output logic              rd_en_o,       // one clock
  output logic [ADDR_W-1:0] rd_addr_o,
  input  logic [31:0]       rd_data_i,
  input  logic              rd_valid_i,    // READ_WAIT=1 only
  input  logic              rd_err_i
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (ADDR_W < 2) begin : g_bad $error("axi4_lite_slave: ADDR_W must be >= 2"); end
  // ---------------- write path ----------------
  logic aw_got, w_got;
  logic [ADDR_W-1:0] aw_q;
  logic [31:0] w_q;
  logic [3:0] ws_q;
  typedef enum logic [2:0] {W_IDLE, W_EXEC, W_WAIT, W_RESP} wst_t;
  wst_t wst;
  wire wr_bad = (MAP_WORDS != 0) && (aw_q[ADDR_W-1:2] >= MAP_WORDS);
  // one write outstanding: no new address/data is accepted while the previous response is still pending
  assign s_axil_awready = (wst == W_IDLE) & ~aw_got & ~s_axil_bvalid;
  assign s_axil_wready  = (wst == W_IDLE) & ~w_got  & ~s_axil_bvalid;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wst <= W_IDLE;
      aw_got <= 1'b0;
      w_got <= 1'b0;
      wr_en_o <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp <= 2'b00;
      aw_q <= '0;
      w_q <= '0;
      ws_q <= '0;
    end else begin
      wr_en_o <= 1'b0;
      case (wst)
        W_IDLE: begin
          if (s_axil_awvalid & s_axil_awready) begin
            aw_got <= 1'b1;
            aw_q <= s_axil_awaddr;
          end
          if (s_axil_wvalid & s_axil_wready) begin
            w_got <= 1'b1;
            w_q <= s_axil_wdata;
            ws_q <= s_axil_wstrb;
          end
          if ((aw_got | (s_axil_awvalid & s_axil_awready)) & (w_got | (s_axil_wvalid & s_axil_wready))) wst <= W_EXEC;
        end
        W_EXEC: begin
          wr_en_o <= ~wr_bad; // wr_en_o is high during W_WAIT
          wst <= W_WAIT;
        end
        W_WAIT: wst <= W_RESP;                   // user computes wr_err_i for this write
        W_RESP: begin
          s_axil_bvalid <= 1'b1;
          s_axil_bresp <= wr_bad ? 2'b11 : (wr_err_i ? 2'b10 : 2'b00);
          aw_got <= 1'b0;
          w_got <= 1'b0;
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
      if (s_axil_bvalid & s_axil_bready) s_axil_bvalid <= 1'b0;
    end
  end
  assign wr_addr_o = aw_q;
  assign wr_data_o = w_q;
  assign wr_strb_o = ws_q;
  // wr_err_i is sampled while in W_RESP (cycle after wr_en_o); keep bvalid from being set before it
  // ---------------- read path ----------------
  typedef enum logic [2:0] {R_IDLE, R_REQ, R_WAIT, R_DATA, R_RESP} rst_t;
  rst_t rst;
  logic [ADDR_W-1:0] ar_q;
  wire rd_bad = (MAP_WORDS != 0) && (ar_q[ADDR_W-1:2] >= MAP_WORDS);
  assign s_axil_arready = (rst == R_IDLE);
  assign rd_addr_o = ar_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rst <= R_IDLE;
      rd_en_o <= 1'b0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata <= '0;
      s_axil_rresp <= 2'b00;
      ar_q <= '0;
    end else begin
      rd_en_o <= 1'b0;
      case (rst)
        R_IDLE: if (s_axil_arvalid) begin
          ar_q <= s_axil_araddr;
          rst <= R_REQ;
        end
        R_REQ: begin
          rd_en_o <= 1'b1;
          rst <= R_WAIT;
        end
        R_WAIT: begin                            // rd_en_o is high in this state
          if (rd_bad) begin
            s_axil_rvalid <= 1'b1;
            s_axil_rdata <= '0;
            s_axil_rresp <= 2'b11;
            rst <= R_RESP;
          end
          else if (READ_WAIT != 0 && rd_valid_i) begin
            s_axil_rvalid <= 1'b1;
            s_axil_rdata <= rd_data_i;
            s_axil_rresp <= rd_err_i ? 2'b10 : 2'b00;
            rst <= R_RESP;
          end else rst <= R_DATA;
        end
        R_DATA: begin                            // data valid one cycle after rd_en_o
          if (READ_WAIT == 0 || rd_valid_i) begin
            s_axil_rvalid <= 1'b1;
            s_axil_rdata <= rd_data_i;
            s_axil_rresp <= rd_err_i ? 2'b10 : 2'b00;
            rst <= R_RESP;
          end
        end
        R_RESP: if (s_axil_rready) begin
          s_axil_rvalid <= 1'b0;
          rst <= R_IDLE;
        end
        default: rst <= R_IDLE;
      endcase
    end
  end
endmodule
