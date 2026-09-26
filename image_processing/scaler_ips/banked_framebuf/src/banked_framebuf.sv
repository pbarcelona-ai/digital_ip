// ***************
// Filename: banked_framebuf.sv
// Author: Paul Barcelona
// Description: Frame store with a TAPSxTAPS window read per clock.
//   The image is split over B x B RAM banks (B = next power of two >=
//   TAPS). Pixel (x,y) lives in bank (y mod B, x mod B) at address
//   (y div B)*BW + (x div B), so any B consecutive rows/columns hit B
//   different banks and a whole window needs one access per bank.
//   Edges are clamp-to-edge. The clamped taps of a window still form a
//   contiguous range of <= TAPS coordinates, so the clamped window is
//   also conflict free.
//   Read pipeline (registers advance only when rd_adv = 1):
//     stage A : per-bank addresses and tap->bank selects registered
//     stage B : RAM read data registered
//     rd_win  : combinational tap mux from the stage-B registers
//   rd_win therefore belongs to the rd_x0/rd_y0 given two rd_adv cycles
//   earlier. Tap (row j, column i) is rd_win[((j*TAPS)+i)*PIX_W +: PIX_W].
//   Write port: one pixel per clock at (wr_x, wr_y).
// Date: 2026-09-26

module banked_framebuf #(
  parameter int PIX_W = 24,     // bits per pixel
  parameter int TAPS  = 4,      // window size (TAPS x TAPS)
  parameter int MAX_W = 1920,   // largest image width stored
  parameter int MAX_H = 1080    // largest image height stored
)(
  input  logic                         clk,
  // write port (one pixel per clock)
  input  logic                         wr_en,   // write strobe
  input  logic [15:0]                  wr_x,    // pixel column
  input  logic [15:0]                  wr_y,    // pixel row
  input  logic [PIX_W-1:0]             wr_data, // pixel value
  // window read port
  input  logic                         rd_adv,  // advance read pipeline
  input  logic signed [17:0]           rd_x0,   // left column of window
  input  logic signed [17:0]           rd_y0,   // top row of window
  input  logic [15:0]                  img_w,   // valid image size (>= 1)
  input  logic [15:0]                  img_h,
  output logic [TAPS*TAPS*PIX_W-1:0]   rd_win   // window, row-major taps
);

  // Smallest power of two >= v (elaboration-time helper)
  function automatic int pow2ceil(input int v);
    int p = 1;
    while (p < v) p = p * 2;
    return p;
  endfunction

  localparam int B     = pow2ceil(TAPS);          // banks per dimension
  localparam int LB    = $clog2(B);
  localparam int SELW  = (LB == 0) ? 1 : LB;      // bank index width
  localparam int BW    = (MAX_W + B - 1) / B;     // bank words per row
  localparam int BH    = (MAX_H + B - 1) / B;     // bank rows
  localparam int DEPTH = BW * BH;                 // words per bank
  localparam int AW    = (DEPTH <= 2) ? 1 : $clog2(DEPTH);  // addr width

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------
  // Clamp a signed coordinate into [0, size-1] (clamp-to-edge)
  function automatic logic [15:0] clampc(input logic signed [17:0] v,
                                         input logic [15:0] size);
    if (v < 0)                          return 16'd0;
    else if (v > $signed({2'b0, size}) - 18'sd1) return size - 16'd1;
    else                                return v[15:0];
  endfunction

  // ---------------------------------------------------------------------------
  // write port
  // ---------------------------------------------------------------------------
  // Bank selected by the low coordinate bits, word address by the rest.
  // B is a power of two, so % and / reduce to bit selects and shifts.
  wire [SELW-1:0] wbx   = SELW'(wr_x % B);                      // bank col
  wire [SELW-1:0] wby   = SELW'(wr_y % B);                      // bank row
  wire [AW-1:0]   waddr = AW'((wr_y / B) * BW + (wr_x / B));    // word

  // ---------------------------------------------------------------------------
  // stage A : per-bank coordinates and per-tap selects
  // ---------------------------------------------------------------------------
  // lo/hi: first and last clamped coordinate covered by the window
  logic [15:0]    lo_x, hi_x, lo_y, hi_y;
  logic [15:0]    bcx [B];      // column held by bank column bx
  logic [15:0]    bcy [B];      // row    held by bank row    by
  logic [SELW-1:0] tsx [TAPS];  // bank column used by tap column i
  logic [SELW-1:0] tsy [TAPS];  // bank row    used by tap row    j

  // For every bank index b find the unique coordinate c in [lo, hi]
  // with c mod B == b. Banks with no such coordinate are unused; their
  // coordinate is clamped to hi to keep the address in range. Each tap
  // then selects the bank that holds its own clamped coordinate.
  always_comb begin
    lo_x = clampc(rd_x0, img_w);
    hi_x = clampc(rd_x0 + 18'(TAPS - 1), img_w);
    lo_y = clampc(rd_y0, img_h);
    hi_y = clampc(rd_y0 + 18'(TAPS - 1), img_h);
    for (int b = 0; b < B; b++) begin
      logic [15:0] c;
      c = lo_x + 16'((b - int'(lo_x % B)) & (B - 1));
      bcx[b] = (c > hi_x) ? hi_x : c;
      c = lo_y + 16'((b - int'(lo_y % B)) & (B - 1));
      bcy[b] = (c > hi_y) ? hi_y : c;
    end
    for (int t = 0; t < TAPS; t++) begin
      tsx[t] = SELW'(clampc(rd_x0 + 18'(t), img_w) % B);
      tsy[t] = SELW'(clampc(rd_y0 + 18'(t), img_h) % B);
    end
  end

  // Stage A registers: the bank word address is split into a column
  // part (per bank column) and a row part (per bank row) that are added
  // in stage B. Tap selects are delayed two stages to meet the RAM data.
  logic [AW-1:0]   colpart_q [B];
  logic [AW-1:0]   rowpart_q [B];
  logic [SELW-1:0] tsx_q [TAPS], tsy_q [TAPS];     // stage A selects
  logic [SELW-1:0] tsx_qq [TAPS], tsy_qq [TAPS];   // stage B selects

  always_ff @(posedge clk) begin
    if (rd_adv) begin
      for (int b = 0; b < B; b++) begin
        colpart_q[b] <= AW'(bcx[b] / B);
        rowpart_q[b] <= AW'((bcy[b] / B) * BW);
      end
      for (int t = 0; t < TAPS; t++) begin
        tsx_q[t]  <= tsx[t];
        tsy_q[t]  <= tsy[t];
        tsx_qq[t] <= tsx_q[t];
        tsy_qq[t] <= tsy_q[t];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // stage B : banks
  // ---------------------------------------------------------------------------
  logic [PIX_W-1:0] bank_q [B][B];   // [row bank][column bank]

  // B x B independent single-write / single-read RAMs
  for (genvar gy = 0; gy < B; gy++) begin : g_by
    for (genvar gx = 0; gx < B; gx++) begin : g_bx
      logic [PIX_W-1:0] mem [DEPTH];           // one bank
      always_ff @(posedge clk) begin
        // write when the pixel maps to this bank
        if (wr_en && wbx == SELW'(gx) && wby == SELW'(gy))
          mem[waddr] <= wr_data;
        // registered read, held while the pipeline is stalled
        if (rd_adv)
          bank_q[gy][gx] <= mem[rowpart_q[gy] + colpart_q[gx]];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // tap mux
  // ---------------------------------------------------------------------------
  // Route each bank output to the tap(s) that need it
  always_comb begin
    for (int j = 0; j < TAPS; j++)
      for (int i = 0; i < TAPS; i++)
        rd_win[((j*TAPS)+i)*PIX_W +: PIX_W] = bank_q[tsy_qq[j]][tsx_qq[i]];
  end

endmodule
