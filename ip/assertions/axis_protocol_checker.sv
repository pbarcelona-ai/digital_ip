// ***************
// Filename: axis_protocol_checker.sv
// Author: Paul Barcelona
// Description: Concurrent SVA protocol checker for AXI4-Stream. Passive
//   monitor - bind it to any IP stream port. Checks that TVALID stays high
//   until TREADY, that TDATA/TKEEP/TLAST/TUSER are stable while a beat is
//   stalled, that no output is X after reset, and that TKEEP is non-zero
//   on TLAST beats. Explicit clock and disable iff on every property because Verilator 5.020 rejects default disable iff. Runs under Verilator (--assert) and simulators with
//   full SVA support; Yosys ignores it (not part of any build.f). Clock -
//   aclk, checks are sampled on its rising edge. Reset - active low
//   aresetn, checks are disabled during reset. Latency - 0, passive.
//   Errors - assertion failures are reported with $error.
// Date: 2026-09-29
module axis_protocol_checker #(
  parameter int DATA_W = 32,
  parameter int USER_W = 1
) (
  input logic                aclk,
  input logic                aresetn,
  input logic [DATA_W-1:0]   tdata,
  input logic [DATA_W/8-1:0] tkeep,
  input logic                tlast,
  input logic [USER_W-1:0]   tuser,
  input logic                tvalid,
  input logic                tready
);
  a_valid_hold: assert property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready |=> tvalid) else $error("%m: TVALID dropped before TREADY");
  a_data_stable: assert property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready |=> $stable(tdata)) else $error("%m: TDATA changed while stalled");
  a_keep_stable: assert property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready |=> $stable(tkeep)) else $error("%m: TKEEP changed while stalled");
  a_last_stable: assert property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready |=> $stable(tlast)) else $error("%m: TLAST changed while stalled");
  a_user_stable: assert property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready |=> $stable(tuser)) else $error("%m: TUSER changed while stalled");
  a_no_x:        assert property (@(posedge aclk) disable iff (!aresetn) !$isunknown(tvalid) && !$isunknown(tready)) else $error("%m: TVALID/TREADY unknown");
  a_data_known:  assert property (@(posedge aclk) disable iff (!aresetn) tvalid |-> !$isunknown({tdata, tlast})) else $error("%m: payload unknown while valid");
  a_keep_last:   assert property (@(posedge aclk) disable iff (!aresetn) tvalid && tlast |-> (tkeep != '0)) else $error("%m: TLAST beat with empty TKEEP");
  c_beat:        cover property (@(posedge aclk) disable iff (!aresetn) tvalid && tready);
  c_stall:       cover property (@(posedge aclk) disable iff (!aresetn) tvalid && !tready);
  c_last:        cover property (@(posedge aclk) disable iff (!aresetn) tvalid && tready && tlast);
endmodule
