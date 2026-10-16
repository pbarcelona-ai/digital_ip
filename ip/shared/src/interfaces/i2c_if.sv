// ***************
// Filename: i2c_if.sv
// Author: FPGA Cores 4 U
// Description: I2C pins in i / o / t form (open drain: drive o = 0 with t = 0, release with t =
//   1) between an I2C master and the pad (IOBUF) or a bus model. Modules take widths as
//   parameters (no $bits on interface members: Icarus); connect a port with the plain instance
//   name (.p(u_if)). A top-level module for synthesis keeps discrete ports
//   (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface i2c_if ();
  logic scl_i;                          // SCL pin level
  logic scl_o;                          // SCL output value (0: open drain)
  logic scl_t;                          // SCL tri-state (1: released)
  logic sda_i;                          // SDA pin level
  logic sda_o;                          // SDA output value
  logic sda_t;                          // SDA tri-state (1: released)

  modport master (output scl_o, scl_t, sda_o, sda_t, input scl_i, sda_i);
  modport pad (output scl_i, sda_i, input scl_o, scl_t, sda_o, sda_t);
  modport monitor (input scl_i, scl_o, scl_t, sda_i, sda_o, sda_t);
endinterface
