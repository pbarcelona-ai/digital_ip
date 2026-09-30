// ***************
// Filename: i2c_master_fsm.sv
// Author: Paul Barcelona
// Description: I2C master transaction sequencer. One transaction is START,
//   7-bit address plus R/W, ACK check, then LEN data bytes (fetched from or
//   delivered to AXI-Stream) and an optional STOP (no-stop keeps the bus for
//   a repeated START). NACK and arbitration loss end the transaction.
//   Received bytes carry tlast on the final byte of the transaction. Version
//   1.0.0. Helper block of its IP; see the top level description for clock,
//   reset, latency and error behavior. Clock - the clock of the parent block,
//   all signals are synchronous to it. Reset - synchronous, driven by the
//   parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
//   all signals are synchronous to it. Reset - synchronous, driven by the
//   parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module i2c_master_fsm (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable_i,
  input  logic        start_i,       // one clock pulse launches a transaction
  input  logic        rw_i,          // 1 = read
  input  logic        nostop_i,      // 1 = no STOP at end (repeated START)
  input  logic [6:0]  addr_i,
  input  logic [15:0] len_i,         // data bytes (0 = address probe)
  // Bytes to write
  input  logic [7:0]  s_tdata,
  input  logic        s_tvalid,
  output logic        s_tready,
  // Bytes read
  output logic [7:0]  m_tdata,
  output logic        m_tvalid,
  output logic        m_tlast,
  input  logic        m_tready,
  // Bit engine interface
  output logic        bc_valid,
  output logic [1:0]  bc_cmd,
  output logic        bc_din,
  output logic        bc_abort,
  input  logic        bc_done,
  input  logic        bc_dout,
  input  logic        bc_arb,
  // Status
  output logic        busy_o,
  output logic        done_o,        // one clock
  output logic        nack_o,        // one clock with done
  output logic        arb_o          // one clock with done
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  localparam logic [1:0] C_START = 2'd0, C_STOP = 2'd1, C_WR = 2'd2, C_RD = 2'd3;
  typedef enum logic [4:0] {
    ST_IDLE, ST_START_I, ST_START_W, ST_TXB_I, ST_TXB_W, ST_ACK_I, ST_ACK_W,
    ST_WFETCH, ST_RBIT_I, ST_RBIT_W, ST_RPUSH, ST_RACK_I, ST_RACK_W,
    ST_END, ST_STOP_I, ST_STOP_W, ST_DONE
  } state_t;
  state_t state;

  logic [7:0]  sh;
  logic [3:0]  nbit;
  logic [15:0] left;
  logic        is_addr, rw_q, nostop_q, nack_f, arb_f;

  assign busy_o   = (state != ST_IDLE);
  assign s_tready = (state == ST_WFETCH);
  assign m_tvalid = (state == ST_RPUSH);
  assign m_tdata  = sh;
  assign m_tlast  = (left == 16'd1);

  // Command issue is combinational from the state (engine is idle here)
  always_comb begin
    bc_valid = 1'b0; bc_cmd = C_START; bc_din = 1'b0;
    case (state)
      ST_START_I: begin bc_valid = 1'b1; bc_cmd = C_START; end
      ST_TXB_I  : begin bc_valid = 1'b1; bc_cmd = C_WR; bc_din = sh[7]; end
      ST_ACK_I  : begin bc_valid = 1'b1; bc_cmd = C_RD; end
      ST_RBIT_I : begin bc_valid = 1'b1; bc_cmd = C_RD; end
      ST_RACK_I : begin bc_valid = 1'b1; bc_cmd = C_WR; bc_din = (left == 16'd1); end
      ST_STOP_I : begin bc_valid = 1'b1; bc_cmd = C_STOP; end
      default   : ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= ST_IDLE; sh <= '0; nbit <= '0; left <= '0;
      is_addr <= 1'b0; rw_q <= 1'b0; nostop_q <= 1'b0; nack_f <= 1'b0; arb_f <= 1'b0;
      done_o <= 1'b0; nack_o <= 1'b0; arb_o <= 1'b0; bc_abort <= 1'b0;
    end else begin
      done_o <= 1'b0; nack_o <= 1'b0; arb_o <= 1'b0; bc_abort <= 1'b0;
      if (bc_arb && state != ST_IDLE) begin      // lost arbitration: give up
        arb_f <= 1'b1; bc_abort <= 1'b1; state <= ST_DONE;
      end else begin
        case (state)
          ST_IDLE: if (start_i & enable_i) begin
            sh <= {addr_i, rw_i}; left <= len_i; rw_q <= rw_i; nostop_q <= nostop_i;
            is_addr <= 1'b1; nbit <= '0; nack_f <= 1'b0; arb_f <= 1'b0;
            state <= ST_START_I;
          end
          ST_START_I: state <= ST_START_W;
          ST_START_W: if (bc_done) state <= ST_TXB_I;
          // ---- transmit one byte (address or data), MSB first ----
          ST_TXB_I: state <= ST_TXB_W;
          ST_TXB_W: if (bc_done) begin
            sh <= {sh[6:0], 1'b0}; nbit <= nbit + 4'd1;
            state <= (nbit == 4'd7) ? ST_ACK_I : ST_TXB_I;
          end
          ST_ACK_I: state <= ST_ACK_W;
          ST_ACK_W: if (bc_done) begin
            if (bc_dout) begin                       // NACK from the slave
              nack_f <= 1'b1; state <= ST_STOP_I;
            end else if (is_addr) begin
              is_addr <= 1'b0; nbit <= '0;
              if (left == 16'd0)  state <= ST_END;
              else if (rw_q)      state <= ST_RBIT_I;
              else                state <= ST_WFETCH;
            end else begin                           // data byte acknowledged
              left <= left - 16'd1;
              state <= (left == 16'd1) ? ST_END : ST_WFETCH;
            end
          end
          ST_WFETCH: if (s_tvalid) begin
            sh <= s_tdata; nbit <= '0; state <= ST_TXB_I;
          end
          // ---- receive one byte, then ACK (or NACK if last) ----
          ST_RBIT_I: state <= ST_RBIT_W;
          ST_RBIT_W: if (bc_done) begin
            sh <= {sh[6:0], bc_dout}; nbit <= nbit + 4'd1;
            state <= (nbit == 4'd7) ? ST_RPUSH : ST_RBIT_I;
          end
          ST_RPUSH: if (m_tready) state <= ST_RACK_I;
          ST_RACK_I: state <= ST_RACK_W;
          ST_RACK_W: if (bc_done) begin
            left <= left - 16'd1; nbit <= '0;
            state <= (left == 16'd1) ? ST_END : ST_RBIT_I;
          end
          // ---- finish ----
          ST_END: state <= nostop_q ? ST_DONE : ST_STOP_I;
          ST_STOP_I: state <= ST_STOP_W;
          ST_STOP_W: if (bc_done) state <= ST_DONE;
          ST_DONE: begin
            done_o <= 1'b1; nack_o <= nack_f; arb_o <= arb_f;
            state <= ST_IDLE;
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
  end
endmodule
