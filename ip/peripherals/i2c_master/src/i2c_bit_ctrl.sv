// ***************
// Filename: i2c_bit_ctrl.sv
// Author: Paul Barcelona
// Description: I2C bit level engine. Executes one command at a time - START
//   (also repeated START), STOP, write bit, read bit - split into four phases
//   of div_i+1 clocks each, so SCL period is 4*(div_i+1) clocks at any clock
//   frequency. Open-drain outputs (drive low only), input synchronizers,
//   clock stretching (waits for SCL to actually rise) and arbitration loss
//   detection on written ones. Version 1.0.0. Helper block of its IP; see the
//   top level description for clock, reset, latency and error behavior. Clock
//   - the clock of the parent block, all signals are synchronous to it. Reset
//   - synchronous, driven by the parent block. Latency - as documented in the
//   parent block, fixed and independent of data. Errors - none reported here,
//   out-of-range parameters stop elaboration or are handled by the parent
//   block.
//   - synchronous, driven by the parent block. Latency - as documented in the
//   parent block, fixed and independent of data. Errors - none reported here,
//   out-of-range parameters stop elaboration or are handled by the parent
//   block.
// Date: 2026-09-29
module i2c_bit_ctrl (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] div_i,        // phase length in clocks minus one
  input  logic        cmd_valid,    // accepted only while idle
  input  logic [1:0]  cmd,          // 0 START, 1 STOP, 2 WRITE, 3 READ
  input  logic        din,          // bit to write
  input  logic        abort_i,      // release the bus immediately
  output logic        done_o,       // one clock, command finished
  output logic        dout_o,       // sampled SDA of a READ
  output logic        arb_lost_o,   // one clock, SDA low while writing 1
  output logic        busy_o,
  input  logic        scl_i,
  input  logic        sda_i,
  output logic        scl_low_o,    // 1 = pull SCL low
  output logic        sda_low_o     // 1 = pull SDA low
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  localparam logic [1:0] C_START = 2'd0, C_STOP = 2'd1, C_WR = 2'd2, C_RD = 2'd3;
  localparam logic [2:0] S_IDLE = 3'd0, S_P0 = 3'd1, S_P1 = 3'd2,
                         S_P2 = 3'd3, S_P3 = 3'd4;

  (* async_reg = "true" *) logic [1:0] scl_sq, sda_sq;   // 2FF synchronizers
  wire scl_s = scl_sq[1];
  wire sda_s = sda_sq[1];

  logic [2:0]  state;
  logic [15:0] tmr;
  logic [1:0]  cmd_q;
  logic        din_q;
  wire         tmr_zero = (tmr == 16'd0);

  assign busy_o = (state != S_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scl_sq <= 2'b11; sda_sq <= 2'b11;
    end else begin
      scl_sq <= {scl_sq[0], scl_i};
      sda_sq <= {sda_sq[0], sda_i};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; tmr <= '0; cmd_q <= '0; din_q <= 1'b0;
      scl_low_o <= 1'b0; sda_low_o <= 1'b0;
      done_o <= 1'b0; dout_o <= 1'b0; arb_lost_o <= 1'b0;
    end else begin
      done_o     <= 1'b0;
      arb_lost_o <= 1'b0;
      if (abort_i) begin                         // release everything
        state <= S_IDLE; scl_low_o <= 1'b0; sda_low_o <= 1'b0;
      end else begin
        case (state)
          S_IDLE: if (cmd_valid) begin
            cmd_q <= cmd; din_q <= din; state <= S_P0; tmr <= div_i;
            // Phase 0 action: set up SDA while SCL is low
            case (cmd)
              C_START: sda_low_o <= 1'b0;        // release SDA (SCL low)
              C_STOP : sda_low_o <= 1'b1;        // SDA low before SCL rises
              C_WR   : sda_low_o <= ~din;        // present the data bit
              default: sda_low_o <= 1'b0;        // READ: release SDA
            endcase
          end
          S_P0: begin
            if (tmr_zero) begin                  // phase 1: release SCL
              state <= S_P1; tmr <= div_i; scl_low_o <= 1'b0;
            end else tmr <= tmr - 16'd1;
          end
          S_P1: begin
            if (!scl_s) tmr <= div_i;            // wait for SCL high (stretch)
            else if (tmr_zero) begin             // phase 2: SCL high
              state <= S_P2; tmr <= div_i;
              if (cmd_q == C_START) sda_low_o <= 1'b1;   // START condition
              if (cmd_q == C_STOP)  sda_low_o <= 1'b0;   // STOP condition
            end else tmr <= tmr - 16'd1;
          end
          S_P2: begin
            if (tmr_zero) begin                  // sample at end of high time
              state <= S_P3; tmr <= div_i;
              dout_o <= sda_s;
              if (cmd_q == C_WR && din_q && !sda_s) arb_lost_o <= 1'b1;
              if (cmd_q != C_STOP) scl_low_o <= 1'b1;    // phase 3: SCL low
            end else tmr <= tmr - 16'd1;
          end
          S_P3: begin
            if (tmr_zero) begin state <= S_IDLE; done_o <= 1'b1; end
            else tmr <= tmr - 16'd1;
          end
          default: state <= S_IDLE;
        endcase
      end
    end
  end
endmodule
