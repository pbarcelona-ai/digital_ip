// ***************
// Filename: ip_version_pkg.sv
// Author: FPGA Cores 4 U
// Description: Library-wide package. Holds the library version, small
//   constant functions (safe clog2, power-of-two test) and common AXI
//   response codes. Not required by any IP (each IP keeps its own
//   IP_VERSION localparam so it can be copied alone) but useful in
//   projects that use several. Clock - none. Reset - none. Latency - 0,
//   constants and functions only. Errors - none. Version 1.0.0.
// Date: 2026-09-29
package ip_version_pkg;
  localparam logic [31:0] IP_LIB_VERSION = 32'h0001_0000;   // major.minor.patch = 1.0.0
  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;
  function automatic int clog2_safe(input int n);
    int r;
    r = 0;
    for (int v = (n < 2) ? 1 : n - 1; v > 0; v = v >> 1) r++;
    clog2_safe = (r < 1) ? 1 : r;
  endfunction
  function automatic bit is_pow2(input int n);
    is_pow2 = (n > 0) && ((n & (n - 1)) == 0);
  endfunction
endpackage
