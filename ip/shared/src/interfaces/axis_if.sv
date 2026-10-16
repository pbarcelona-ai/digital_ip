// ***************
// Filename: axis_if.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Stream interface of the FPGA Cores 4 U library, the
//   common definition every block's stream ports follow. Version 1.0.0.
//   Signals: tdata [DATA_W-1:0], tkeep [KEEP_W-1:0] (byte enables, used by
//   byte streams such as CSI-2; tie high or leave unconnected otherwise),
//   tlast (end of line / packet), tuser [USER_W-1:0] (bit 0: start of
//   frame), tvalid, tready. Handshake rules: a beat moves when tvalid and
//   tready are both high; tvalid must not depend on tready, and once high it
//   stays high with stable payload until the beat moves.
//   Modports: master (drives the payload and tvalid), slave (drives
//   tready), monitor (observes everything, a passive tap).
//   Tool note: Icarus Verilog cannot drive members of interface arrays and
//   Yosys cannot read interfaces without sv2v, so the library's modules keep
//   discrete ports named <prefix>_tdata, <prefix>_tvalid, ... and name the
//   interface and modport in a comment above each port group, e.g.
//     // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
//   Testbenches and Verilator flows may use the interface directly.
//   Parameters - DATA_W (>= 1), USER_W (>= 1), KEEP_W (>= 1, normally
//   DATA_W / 8). Clocks / resets - none (the stream is synchronous to the
//   clock of the blocks it connects).
// Date: 2026-10-16
interface axis_if #(
  parameter int DATA_W = 24,                     // payload width
  parameter int USER_W = 1,                      // tuser width (bit 0: start of frame)
  parameter int KEEP_W = (DATA_W >= 8) ? DATA_W / 8 : 1  // byte enables
) ();
  logic [DATA_W-1:0] tdata;                      // payload
  logic [KEEP_W-1:0] tkeep;                      // byte enables (byte streams)
  logic              tlast;                      // end of line / packet
  logic [USER_W-1:0] tuser;                      // [0] start of frame
  logic              tvalid;                     // payload valid
  logic              tready;                     // sink accepts

  modport master (output tdata, tkeep, tlast, tuser, tvalid, input tready);
  modport slave (input tdata, tkeep, tlast, tuser, tvalid, output tready);
  modport monitor (input tdata, tkeep, tlast, tuser, tvalid, tready);
endinterface
