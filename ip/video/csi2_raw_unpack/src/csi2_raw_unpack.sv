// ***************
// Filename: csi2_raw_unpack.sv
// Author: FPGA Cores 4 U
// Description: CSI-2 RAW payload unpacker. Version 1.0.0. Converts the
//   packed payload bytes of csi2_rx (IN_BYTES bytes per word, tkeep
//   contiguous from bit 0, tlast = end of line, tuser = start of frame)
//   into one pixel per clock in the AXI-Stream video format of this library
//   (tuser = SOF on the first pixel, tlast = EOL on the last pixel of a line).
//   Formats (fmt_i = CSI-2 data type):
//     0x2A RAW8  - 1 byte  -> 1 pixel
//     0x2B RAW10 - 5 bytes -> 4 pixels: bytes 0-3 hold bits [9:2] of pixels
//                  0-3, byte 4 holds bits [1:0] of pixel i in bits [2i+1:2i]
//     0x2C RAW12 - 3 bytes -> 2 pixels: bytes 0-1 hold bits [11:4], byte 2
//                  holds bits [3:0] of pixel 0 in [3:0], pixel 1 in [7:4]
//   Pixels are aligned to OUT_W bits (shifted left when narrower, right when
//   wider). A line must hold whole groups (CSI-2 requires this). Unknown
//   formats are treated as RAW8.
//   Resync - grouping is checked against the line and frame markers: a group
//   that would run past the end of a line drops the bytes up to that end,
//   and one that would start before a start-of-frame byte drops the bytes
//   before it. Payload words lost upstream (e.g. a full clock-crossing FIFO)
//   therefore corrupt at most the line they belong to. Throughput - 1 pixel per clock; the input
//   is back-pressured while the byte buffer is full. Clock - clk only.
//   Reset - synchronous rst_n (active low). Latency - 2 clocks.
// Date: 2026-10-01
module csi2_raw_unpack #(
  parameter int IN_BYTES = 2,                  // bytes per input word (CSI-2 lanes)
  parameter int OUT_W    = 10                  // output pixel width
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic [5:0]              fmt_i,       // CSI-2 data type (change between frames)
  // Packed payload
  input  logic [IN_BYTES*8-1:0]   s_axis_tdata,
  input  logic [IN_BYTES-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tlast,
  input  logic                    s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  // Pixels
  output logic [OUT_W-1:0]        m_axis_tdata,
  output logic                    m_axis_tlast,
  output logic                    m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready
);
  localparam int BUF = IN_BYTES + 8;             // bytes held (largest group is 5)
  localparam int CW  = $clog2(BUF + 1);

  logic [7:0] bq [BUF]; logic [BUF-1:0] bfirst, blast;
  logic [CW-1:0] cnt;
  logic [1:0]    pi;                             // pixel index inside the group

  wire is10 = (fmt_i == 6'h2B), is12 = (fmt_i == 6'h2C);
  wire [2:0] gsize = is10 ? 3'd5 : (is12 ? 3'd3 : 3'd1);   // bytes per group
  wire [1:0] plast = is10 ? 2'd3 : (is12 ? 2'd1 : 2'd0);   // last pixel index of a group

  function automatic logic [OUT_W-1:0] align(input logic [11:0] v, input int w);
    logic [OUT_W-1:0] r;
    if (OUT_W >= w) r = OUT_W'(v) << (OUT_W - w);
    else            r = OUT_W'(v >> (w - OUT_W));
    align = r;
  endfunction

  // Current pixel of the group at the head of the buffer
  logic [OUT_W-1:0] px; logic glast;
  always_comb begin
    if (is10)      px = align({4'd0, bq[pi], bq[4][2*pi +: 2]}, 10);
    else if (is12) px = align((pi == 0) ? {bq[0], bq[2][3:0]} : {bq[1], bq[2][7:4]}, 12);
    else           px = align({4'd0, bq[0]}, 8);
    glast = 1'b0;
    for (int k = 0; k < 5; k++) if (k < gsize && blast[k]) glast = 1'b1;
  end

  // Misaligned group at the head (checked before its first pixel): a line end
  // before the group's last byte, or a frame start after its first byte
  logic mis; logic [2:0] dropn;
  always_comb begin
    mis = 1'b0; dropn = '0;
    for (int k = 4; k >= 0; k--) begin
      if (k < gsize && CW'(k) < cnt) begin
        if (k > 0 && bfirst[k])             begin mis = 1'b1; dropn = 3'(k);     end
        if (k < gsize - 1 && blast[k])      begin mis = 1'b1; dropn = 3'(k + 1); end
      end
    end
    if (pi != 0) mis = 1'b0;
  end

  wire have_group = (cnt >= CW'(gsize));
  wire out_free   = !m_axis_tvalid || m_axis_tready;
  wire emit       = have_group && out_free && !mis;
  wire pop        = emit && (pi == plast);
  wire [2:0] popn = mis ? dropn : (pop ? gsize : 3'd0);   // bytes removed this clock
  wire [CW-1:0] cnt_pop = cnt - CW'(popn);
  assign s_axis_tready = (cnt <= CW'(BUF - IN_BYTES));
  wire push = s_axis_tvalid && s_axis_tready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt <= '0; pi <= '0; bfirst <= '0; blast <= '0;
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
    end else begin
      // Output stage
      if (emit) begin
        m_axis_tvalid <= 1'b1; m_axis_tdata <= px;
        m_axis_tuser  <= (pi == 0) && bfirst[0];
        m_axis_tlast  <= (pi == plast) && glast;
        pi <= (pi == plast) ? 2'd0 : pi + 1'b1;
      end else if (m_axis_tready) m_axis_tvalid <= 1'b0;

      // Byte buffer: drop a consumed group, then append the new word
      begin : buf_update
        logic [7:0] nb [BUF]; logic [BUF-1:0] nf, nl; int last_k;
        for (int k = 0; k < BUF; k++) begin
          nb[k] = (k + popn < BUF) ? bq[k + popn] : bq[k];
          nf[k] = (k + popn < BUF) ? bfirst[k + popn] : 1'b0;
          nl[k] = (k + popn < BUF) ? blast[k + popn]  : 1'b0;
        end
        if (push) begin
          last_k = 0;
          for (int k = 0; k < IN_BYTES; k++) if (s_axis_tkeep[k]) last_k = k;
          for (int k = 0; k < IN_BYTES; k++) if (s_axis_tkeep[k]) begin
            nb[cnt_pop + k] = s_axis_tdata[8*k +: 8];
            nf[cnt_pop + k] = s_axis_tuser && (k == 0);
            nl[cnt_pop + k] = s_axis_tlast && (k == last_k);
          end
        end
        for (int k = 0; k < BUF; k++) bq[k] <= nb[k];
        bfirst <= nf; blast <= nl;
        cnt <= cnt_pop + (push ? CW'($countones(s_axis_tkeep)) : '0);
      end
    end
  end
endmodule
