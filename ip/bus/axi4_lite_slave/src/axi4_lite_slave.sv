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
// Date: 2026-10-20
module axi4_lite_slave #(
  parameter int ADDR_W     = 8,
  parameter int READ_WAIT  = 0,            // 0: rd_data_i valid the cycle after rd_en_o; 1: wait for rd_valid_i
  parameter int MAP_WORDS  = 0             // 0: full address space valid, else words [0, MAP_WORDS) valid
) (
  input  logic              aclk,
  input  logic              aresetn,
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.slave s_axil,
  // User register interface
  // bus: regbus_if.host (ip/shared/src/interfaces/regbus_if.sv), ADDR_W = ADDR_W {wr_en_o=wr wr_addr_o=waddr wr_data_o=wdata wr_strb_o=wstrb wr_err_i=wr_err rd_en_o=rd rd_addr_o=raddr rd_data_i=rdata rd_valid_i=rd_valid rd_err_i=rd_err}
  regbus_if.host bus
);
  /* verilator lint_off UNUSEDPARAM */             // version identification (library convention), not logic
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  /* verilator lint_on UNUSEDPARAM */
  if (ADDR_W < 2) begin : g_bad $error("axi4_lite_slave: ADDR_W must be >= 2"); end
  // ---------------- write path ----------------
  logic aw_got, w_got;
  logic [ADDR_W-1:0] aw_q;
  logic [31:0] w_q;
  logic [3:0] ws_q;
  typedef enum logic [2:0] {W_IDLE, W_EXEC, W_WAIT, W_RESP} wst_t;
  wst_t wst;
  wire wr_bad = (MAP_WORDS != 0) && (int'(aw_q[ADDR_W-1:2]) >= MAP_WORDS);
  // one write outstanding: no new address/data is accepted while the previous response is still pending
  assign s_axil.awready = (wst == W_IDLE) & ~aw_got & ~s_axil.bvalid;
  assign s_axil.wready  = (wst == W_IDLE) & ~w_got  & ~s_axil.bvalid;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wst <= W_IDLE;
      aw_got <= 1'b0;
      w_got <= 1'b0;
      bus.wr <= 1'b0;
      s_axil.bvalid <= 1'b0;
      s_axil.bresp <= 2'b00;
      aw_q <= '0;
      w_q <= '0;
      ws_q <= '0;
    end else begin
      bus.wr <= 1'b0;
      case (wst)
        W_IDLE: begin
          if (s_axil.awvalid & s_axil.awready) begin
            aw_got <= 1'b1;
            aw_q <= s_axil.awaddr;
          end
          if (s_axil.wvalid & s_axil.wready) begin
            w_got <= 1'b1;
            w_q <= s_axil.wdata;
            ws_q <= s_axil.wstrb;
          end
          if ((aw_got | (s_axil.awvalid & s_axil.awready)) & (w_got | (s_axil.wvalid & s_axil.wready))) wst <= W_EXEC;
        end
        W_EXEC: begin
          bus.wr <= ~wr_bad; // wr_en_o is high during W_WAIT
          wst <= W_WAIT;
        end
        W_WAIT: wst <= W_RESP;                   // user computes wr_err_i for this write
        W_RESP: begin
          s_axil.bvalid <= 1'b1;
          s_axil.bresp <= wr_bad ? 2'b11 : (bus.wr_err ? 2'b10 : 2'b00);
          aw_got <= 1'b0;
          w_got <= 1'b0;
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
      if (s_axil.bvalid & s_axil.bready) s_axil.bvalid <= 1'b0;
    end
  end
  assign bus.waddr = aw_q;
  assign bus.wdata = w_q;
  assign bus.wstrb = ws_q;
  // wr_err_i is sampled while in W_RESP (cycle after wr_en_o); keep bvalid from being set before it
  // ---------------- read path ----------------
  typedef enum logic [2:0] {R_IDLE, R_REQ, R_WAIT, R_DATA, R_RESP} rst_t;
  rst_t rst;
  logic [ADDR_W-1:0] ar_q;
  wire rd_bad = (MAP_WORDS != 0) && (int'(ar_q[ADDR_W-1:2]) >= MAP_WORDS);
  assign s_axil.arready = (rst == R_IDLE);
  assign bus.raddr = ar_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rst <= R_IDLE;
      bus.rd <= 1'b0;
      s_axil.rvalid <= 1'b0;
      s_axil.rdata <= '0;
      s_axil.rresp <= 2'b00;
      ar_q <= '0;
    end else begin
      bus.rd <= 1'b0;
      case (rst)
        R_IDLE: if (s_axil.arvalid) begin
          ar_q <= s_axil.araddr;
          rst <= R_REQ;
        end
        R_REQ: begin
          bus.rd <= ~rd_bad;                     // no read strobe for an unmapped address
          rst <= R_WAIT;
        end
        R_WAIT: begin                            // rd_en_o is high in this state
          if (rd_bad) begin
            s_axil.rvalid <= 1'b1;
            s_axil.rdata <= '0;
            s_axil.rresp <= 2'b11;
            rst <= R_RESP;
          end
          else if (READ_WAIT != 0 && bus.rd_valid) begin
            s_axil.rvalid <= 1'b1;
            s_axil.rdata <= bus.rdata;
            s_axil.rresp <= bus.rd_err ? 2'b10 : 2'b00;
            rst <= R_RESP;
          end else rst <= R_DATA;
        end
        R_DATA: begin                            // data valid one cycle after rd_en_o
          if (READ_WAIT == 0 || bus.rd_valid) begin
            s_axil.rvalid <= 1'b1;
            s_axil.rdata <= bus.rdata;
            s_axil.rresp <= bus.rd_err ? 2'b10 : 2'b00;
            rst <= R_RESP;
          end
        end
        R_RESP: if (s_axil.rready) begin
          s_axil.rvalid <= 1'b0;
          rst <= R_IDLE;
        end
        default: rst <= R_IDLE;
      endcase
    end
  end
endmodule
