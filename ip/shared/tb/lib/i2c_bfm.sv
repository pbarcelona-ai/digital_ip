// ***************
// Filename: i2c_bfm.sv
// Author: FPGA Cores 4 U
// Description: I2C bus functional model: a behavioral I2C target (slave) with a
//   256 byte memory. The first byte written after the address is the memory
//   pointer; reads are sequential from the pointer. Open-drain sda / scl
//   (tri1), optional clock stretching. Used by i2c_master and by the
//   py_soc / video_processor system testbenches (camera CCI, EEPROM).
// Date: 2026-10-09
`timescale 1ns/1ps

// Behavioral I2C slave: 256 byte memory, first written byte is the
// memory pointer, reads are sequential from the pointer.
module i2c_bfm #(parameter logic [6:0] ADDR = 7'h50) (
  inout tri1 sda,
  inout tri1 scl
);
  logic sda_low = 0, scl_low = 0;
  assign sda = sda_low ? 1'b0 : 1'bz;
  assign scl = scl_low ? 1'b0 : 1'bz;

  logic [7:0] mem [0:255];
  logic [7:0] ptr = 0, shreg = 0;
  int  state = 0, bitcnt = 0;
  bit  rw = 0, first = 0, m_nack = 0;
  bit  stretch_en = 0;              // hold SCL low during ack when set
  int  stretch_ns = 2000;

  localparam int IDLE = 0, ADR = 1, ADR_ACK = 2, WDATA = 3, W_ACK = 4,
                 RDATA = 5, R_ACK = 6;

  initial for (int i = 0; i < 256; i++) mem[i] = 8'h00;

  // START: SDA falls while SCL high; STOP: SDA rises while SCL high
  always @(negedge sda) if (scl === 1'b1) begin
    state = ADR;
    bitcnt = 0;
    shreg = 0;
    sda_low = 0;
  end
  always @(posedge sda) if (scl === 1'b1) begin
    state = IDLE;
    sda_low = 0;
  end

  // Sample on rising SCL
  always @(posedge scl) begin
    case (state)
      ADR, WDATA: begin
        shreg = {shreg[6:0], sda};
        bitcnt = bitcnt + 1;
      end
      R_ACK: m_nack = sda;
      default: ;
    endcase
  end

  // Drive on falling SCL
  always @(negedge scl) begin
    case (state)
      ADR: if (bitcnt == 8) begin
        if (shreg[7:1] == ADDR) begin
          rw = shreg[0];
          sda_low = 1;
          state = ADR_ACK;
          if (stretch_en) begin
            scl_low = 1;
            #(stretch_ns);
            scl_low = 0;
          end
        end else state = IDLE;
      end
      ADR_ACK: begin
        sda_low = 0;
        bitcnt = 0;
        if (rw) begin
          shreg = mem[ptr];
          ptr = ptr + 1;
          state = RDATA;
          sda_low = ~shreg[7];
          shreg = {shreg[6:0], 1'b0};
          bitcnt = 1;
        end else begin
          state = WDATA;
          first = 1;
        end
      end
      WDATA: if (bitcnt == 8) begin
        if (first) begin
          ptr = shreg;
          first = 0;
        end
        else begin
          mem[ptr] = shreg;
          ptr = ptr + 1;
        end
        sda_low = 1;
        state = W_ACK;
      end
      W_ACK: begin
        sda_low = 0;
        bitcnt = 0;
        state = WDATA;
      end
      RDATA: begin
        if (bitcnt < 8) begin
          sda_low = ~shreg[7];
          shreg = {shreg[6:0], 1'b0};
          bitcnt = bitcnt + 1;
        end else begin
          sda_low = 0;
          state = R_ACK;
        end
      end
      R_ACK: begin
        if (m_nack) state = IDLE;
        else begin
          shreg = mem[ptr];
          ptr = ptr + 1;
          state = RDATA;
          sda_low = ~shreg[7];
          shreg = {shreg[6:0], 1'b0};
          bitcnt = 1;
        end
      end
      default: ;
    endcase
  end
endmodule
