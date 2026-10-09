// ***************
// Filename: axil_protocol_checker.sv
// Author: FPGA Cores 4 U
// Description: Concurrent SVA protocol checker for AXI4-Lite slave ports.
//   Passive monitor - bind it to any IP's s_axil_* ports. Checks that
//   VALID signals stay asserted until READY, that address, data and
//   strobes are stable while stalled, that a write response never comes
//   without a write address and data, a read response never without a read
//   address, that responses are OKAY, SLVERR or DECERR (never EXOKAY), and
//   that BVALID and RVALID hold until accepted. Runs under Verilator
//   (--assert) and full-SVA simulators; Yosys ignores it (not part of any
//   build.f). Clock - aclk. Reset - active low aresetn, checks disabled in
//   reset. Latency - 0, passive. Errors - reported with $error.
// Date: 2026-09-29
module axil_protocol_checker #(
  parameter int ADDR_W = 8
) (
  input logic              aclk,
  input logic              aresetn,
  input logic [ADDR_W-1:0] awaddr, input logic awvalid, input logic awready,
  input logic [31:0]       wdata,  input logic [3:0] wstrb, input logic wvalid, input logic wready,
  input logic [1:0]        bresp,  input logic bvalid, input logic bready,
  input logic [ADDR_W-1:0] araddr, input logic arvalid, input logic arready,
  input logic [31:0]       rdata,  input logic [1:0] rresp, input logic rvalid, input logic rready
);
  a_aw_hold:   assert property (@(posedge aclk) disable iff (!aresetn) awvalid && !awready |=> awvalid && $stable(awaddr)) else $error("%m: AW not held");
  a_w_hold:    assert property (@(posedge aclk) disable iff (!aresetn) wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb)) else $error("%m: W not held");
  a_ar_hold:   assert property (@(posedge aclk) disable iff (!aresetn) arvalid && !arready |=> arvalid && $stable(araddr)) else $error("%m: AR not held");
  a_b_hold:    assert property (@(posedge aclk) disable iff (!aresetn) bvalid && !bready |=> bvalid && $stable(bresp)) else $error("%m: B not held");
  a_r_hold:    assert property (@(posedge aclk) disable iff (!aresetn) rvalid && !rready |=> rvalid && $stable(rdata) && $stable(rresp)) else $error("%m: R not held");
  a_bresp:     assert property (@(posedge aclk) disable iff (!aresetn) bvalid |-> bresp != 2'b01) else $error("%m: EXOKAY on AXI-Lite B");
  a_rresp:     assert property (@(posedge aclk) disable iff (!aresetn) rvalid |-> rresp != 2'b01) else $error("%m: EXOKAY on AXI-Lite R");
  // outstanding accounting: responses only follow accepted requests
  int aw_n, w_n, b_n, ar_n, r_n;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      aw_n <= 0;
      w_n <= 0;
      b_n <= 0;
      ar_n <= 0;
      r_n <= 0;
    end
    else begin
      if (awvalid && awready) aw_n <= aw_n + 1;
      if (wvalid && wready) w_n <= w_n + 1;
      if (bvalid && bready) b_n <= b_n + 1;
      if (arvalid && arready) ar_n <= ar_n + 1;
      if (rvalid && rready) r_n <= r_n + 1;
    end
  end
  a_b_after_req: assert property (@(posedge aclk) disable iff (!aresetn) bvalid |-> (b_n < aw_n) && (b_n < w_n)) else $error("%m: BVALID without accepted AW and W");
  a_r_after_req: assert property (@(posedge aclk) disable iff (!aresetn) rvalid |-> (r_n < ar_n)) else $error("%m: RVALID without accepted AR");
  c_write: cover property (@(posedge aclk) disable iff (!aresetn) bvalid && bready);
  c_read:  cover property (@(posedge aclk) disable iff (!aresetn) rvalid && rready);
  c_err:   cover property (@(posedge aclk) disable iff (!aresetn) bvalid && bready && bresp != 2'b00);
endmodule
