// ***************
// Filename: lvds_tx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for lvds_tx. A vid_timing_gen with
//   even timing drives frames whose pixels encode (x, y, frame). The lane
//   words are decoded with a table of bit positions written independently of
//   the RTL (OpenLDI VESA / JEIDA 24 bpp and 18 bpp), for single link and
//   dual link (pixel pairs split over links A and B). Every received pixel
//   (the six MSBs for 18 bpp), the DE / HS / VS bits, the clock word and the
//   number of lines and pixels per frame are checked. Prints TEST PASSED on
//   success.
// Date: 2026-10-02
`timescale 1ns/1ps
module lvds_tx_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  localparam int HA = 40, VA = 6;
  logic de, hs, vs, sof, eol, vbl, wt; logic [15:0] x, y;
  vid_timing_gen u_vtg (.clk, .rst_n, .enable_i(1'b1), .h_active_i(16'(HA)), .h_fp_i(16'd4), .h_sync_i(16'd8), .h_bp_i(16'd12),
    .v_active_i(16'(VA)), .v_fp_i(16'd2), .v_sync_i(16'd2), .v_bp_i(16'd2), .hs_pol_i(1'b1), .vs_pol_i(1'b1),
    .lock_en_i(1'b0), .src_ready_i(1'b1), .lock_max_i(16'd0),
    .de_o(de), .hs_o(hs), .vs_o(vs), .x_o(x), .y_o(y), .sof_o(sof), .eol_o(eol), .vblank_o(vbl), .waiting_o(wt));
  int fcount = 0; logic vs_q = 0;
  always @(posedge clk) begin vs_q <= vs; if (vs && !vs_q) fcount <= fcount + 1; end
  function automatic logic [23:0] pix(input int px, input int py, input int f);
    // every bit of B, R and G[1:0] toggles over a frame; G[7:2] = frame (survives 18 bpp)
    return {8'(px * 53 + py * 29 + 7), {6'(f), 2'(px + py)}, 8'((px * 37) ^ (py * 91) ^ 8'hC3)};
  endfunction
  wire [23:0] rgb = de ? pix(x, y, fcount) : 24'h0;

  logic dual, b18, jei; logic [27:0] la, lb; logic [6:0] cw; logic stb;
  lvds_tx dut (.clk, .rst_n, .dual_i(dual), .bpp18_i(b18), .jeida_i(jei), .rgb_i(rgb), .de_i(de), .hs_i(hs), .vs_i(vs),
    .link_a_o(la), .link_b_o(lb), .clk_word_o(cw), .stb_o(stb));

  // Bit position tables: lane l, word bit k (6 = first) -> source.
  // Source code: comp * 8 + bit, comp 0 R, 1 G, 2 B; 24 DE, 25 VS, 26 HS; 31 = zero
  int tv [4][7], tj [4][7], t18 [4][7];
  initial begin
    tv = '{'{8*1+0, 5, 4, 3, 2, 1, 0}, '{16+1, 16+0, 8+5, 8+4, 8+3, 8+2, 8+1},
           '{24, 25, 26, 16+5, 16+4, 16+3, 16+2}, '{31, 16+7, 16+6, 8+7, 8+6, 7, 6}};
    tj = '{'{8+2, 7, 6, 5, 4, 3, 2}, '{16+3, 16+2, 8+7, 8+6, 8+5, 8+4, 8+3},
           '{24, 25, 26, 16+7, 16+6, 16+5, 16+4}, '{31, 16+1, 16+0, 8+1, 8+0, 1, 0}};
    t18 = tj;
    for (int k = 0; k < 7; k++) t18[3][k] = 31;
  end
  // Decode a link: returns {DE, VS, HS, B, G, R} and checks constant-zero bits
  function automatic logic [26:0] decode(input logic [27:0] w);
    logic [26:0] o; int code; logic bitv; o = '0;
    for (int l = 0; l < 4; l++) for (int k = 0; k < 7; k++) begin
      code = b18 ? t18[l][6-k] : jei ? tj[l][6-k] : tv[l][6-k];     // table lists bit 6 first
      bitv = w[7*l + k];
      if (code == 31) begin if (bitv) errors++; end
      else if (code >= 24) o[code] = bitv;
      else o[code] = bitv;
    end
    return o;
  endfunction

  // Rebuild frames from the decoded stream
  int lx, ly, npix, nlines, nframes; bit de_seen, vs_prev;
  task automatic take(input logic [26:0] d);
    if (d[25] && !vs_prev) begin                        // vsync leading edge: frame done
      if (de_seen) begin check(nlines == VA, $sformatf("frame with %0d lines", nlines)); nframes++; end
      nlines = 0; ly = 0;
    end
    vs_prev = d[25];
    if (d[24]) begin
      logic [23:0] e, m; int f;
      f = int'(d[15:10]);                               // frame number from G[7:2]
      e = pix(lx, ly, f);
      m = b18 ? 24'hFCFCFC : 24'hFFFFFF;
      check((d[23:0] & m) == (e & m), $sformatf("%s pixel (%0d,%0d) = %h exp %h", dual ? "dual" : "single", lx, ly, d[23:0] & m, e & m));
      lx++; npix++; de_seen = 1;
    end else if (lx != 0) begin
      check(lx == HA, $sformatf("line of %0d pixels", lx));
      lx = 0; ly++; nlines++;
    end
  endtask
  always @(posedge clk) if (rst_n && stb) begin
    check(cw == 7'b1100011, "clock word");
    take(decode(la));
    if (dual) take(decode(lb));
  end

  task automatic mode(input bit d2, input bit bb, input bit jj, input string name);
    dual = d2; b18 = bb; jei = jj;
    lx = 0; ly = 0; npix = 0; nlines = 0; nframes = 0; de_seen = 0; vs_prev = 1;
    repeat (4) @(posedge vs);
    repeat (5) @(posedge clk);
    check(nframes >= 2, $sformatf("%s: %0d complete frames", name, nframes));
    $display("%s: %0d frames of %0dx%0d decoded", name, nframes, HA, VA);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("lvds_tx_tb.vcd"); $dumpvars(0, lvds_tx_tb); end
    dual = 0; b18 = 0; jei = 0;
    repeat (4) @(posedge clk); rst_n = 1;
    mode(0, 0, 0, "single link, 24 bpp VESA");
    mode(0, 0, 1, "single link, 24 bpp JEIDA");
    mode(0, 1, 0, "single link, 18 bpp");
    mode(1, 0, 0, "dual link, 24 bpp VESA");
    mode(1, 0, 1, "dual link, 24 bpp JEIDA");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
