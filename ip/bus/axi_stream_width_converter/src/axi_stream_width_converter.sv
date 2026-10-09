// ***************
// Filename: axi_stream_width_converter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream data width converter. Version 1.0.0. Converts
//   between IN_BYTES and OUT_BYTES wide streams; one width must be an
//   integer multiple of the other (or equal, giving a register slice).
//   Little-endian byte order - byte 0 of the wide word is the first byte
//   on the narrow side. tkeep and tlast are honoured. Downsizing splits
//   each input beat into OUT_BYTES chunks, skipping trailing all-zero-keep
//   chunks and setting tlast on the last valid chunk of a packet. Upsizing
//   packs beats into one output word, flushing early on tlast (tkeep marks
//   the valid bytes). tuser is carried on the tlast beat only. Clock -
//   aclk. Reset - synchronous aresetn, idle. Throughput - full rate on the
//   narrow side. Latency - 1 clock (downsize/equal) or IN/OUT ratio clocks
//   (upsize). Errors - unsupported ratios rejected at elaboration; tkeep
//   patterns must be contiguous from byte 0 (a gap raises keep_err_o for
//   one clock and the beat is passed as given).
// Date: 2026-09-29
module axi_stream_width_converter #(
  parameter int IN_BYTES  = 4,
  parameter int OUT_BYTES = 1,
  parameter int USER_W    = 1
) (
  input  logic                    aclk,
  input  logic                    aresetn,
  input  logic [IN_BYTES*8-1:0]   s_axis_tdata,
  input  logic [IN_BYTES-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tlast,
  input  logic [USER_W-1:0]       s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  output logic [OUT_BYTES*8-1:0]  m_axis_tdata,
  output logic [OUT_BYTES-1:0]    m_axis_tkeep,
  output logic                    m_axis_tlast,
  output logic [USER_W-1:0]       m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic                    keep_err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int DOWN = (IN_BYTES > OUT_BYTES);
  localparam int RATIO = DOWN ? IN_BYTES / OUT_BYTES : OUT_BYTES / IN_BYTES;
  if (IN_BYTES < 1 || OUT_BYTES < 1) begin : g_b1 $error("axi_stream_width_converter: widths must be >= 1"); end
  if ((DOWN && (IN_BYTES % OUT_BYTES) != 0) || (!DOWN && (OUT_BYTES % IN_BYTES) != 0)) begin : g_b2
    $error("axi_stream_width_converter: widths must be integer multiples");
  end
  // keep contiguity check (registered flag)
  wire contiguous = ((s_axis_tkeep & (s_axis_tkeep + 1'b1)) == '0);   // 0..01..1 pattern
  always_ff @(posedge aclk) begin
    if (!aresetn) keep_err_o <= 1'b0;
    else keep_err_o <= s_axis_tvalid & s_axis_tready & ~contiguous;
  end

  if (IN_BYTES == OUT_BYTES) begin : g_eq
    // register slice with skid-free single register
    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        m_axis_tvalid <= 1'b0;
        m_axis_tdata <= '0;
        m_axis_tkeep <= '0;
        m_axis_tlast <= 1'b0;
        m_axis_tuser <= '0;
      end
      else if (s_axis_tready) begin
        m_axis_tvalid <= s_axis_tvalid;
        m_axis_tdata <= s_axis_tdata;
        m_axis_tkeep <= s_axis_tkeep;
        m_axis_tlast <= s_axis_tlast;
        m_axis_tuser <= s_axis_tuser;
      end
    end
    assign s_axis_tready = ~m_axis_tvalid | m_axis_tready;
  end else if (DOWN) begin : g_down
    logic [IN_BYTES*8-1:0] dat;
    logic [IN_BYTES-1:0] kp;
    logic lst;
    logic [USER_W-1:0] usr;
    logic busy;
    logic [$clog2(RATIO+1)-1:0] idx;
    logic [$clog2(RATIO+1)-1:0] last_idx;
    // index of the last chunk holding valid bytes
    logic [$clog2(RATIO+1)-1:0] lc;
    always_comb begin
      lc = '0;
      for (int c = 0; c < RATIO; c++) if (|s_axis_tkeep[c*OUT_BYTES +: OUT_BYTES]) lc = c[$clog2(RATIO+1)-1:0];
    end
    assign s_axis_tready = ~busy;
    assign m_axis_tvalid = busy;
    always_comb begin
      m_axis_tdata = dat[idx*OUT_BYTES*8 +: OUT_BYTES*8];
      m_axis_tkeep = kp[idx*OUT_BYTES +: OUT_BYTES];
      m_axis_tlast = lst & (idx == last_idx);
      m_axis_tuser = (lst & (idx == last_idx)) ? usr : '0;
    end
    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        busy <= 1'b0;
        idx <= '0;
        last_idx <= '0;
        dat <= '0;
        kp <= '0;
        lst <= 1'b0;
        usr <= '0;
      end
      else if (!busy) begin
        if (s_axis_tvalid) begin
          dat <= s_axis_tdata;
          kp <= s_axis_tkeep;
          lst <= s_axis_tlast;
          usr <= s_axis_tuser;
          // non-last beats send every chunk; last beats stop at the last valid chunk
          last_idx <= s_axis_tlast ? lc : (RATIO - 1);
          idx <= '0;
          busy <= 1'b1;
        end
      end else if (m_axis_tready) begin
        if (idx == last_idx) busy <= 1'b0;
        else idx <= idx + 1'b1;
      end
    end
  end else begin : g_up
    logic [OUT_BYTES*8-1:0] dat;
    logic [OUT_BYTES-1:0] kp;
    logic [$clog2(RATIO+1)-1:0] cnt;
    logic full;
    assign s_axis_tready = ~full;
    assign m_axis_tvalid = full;
    assign m_axis_tdata = dat;
    assign m_axis_tkeep = kp;
    logic lst_q;
    logic [USER_W-1:0] usr_q;
    assign m_axis_tlast = lst_q;
    assign m_axis_tuser = usr_q;
    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        dat <= '0;
        kp <= '0;
        cnt <= '0;
        full <= 1'b0;
        lst_q <= 1'b0;
        usr_q <= '0;
      end
      else begin
        if (full && m_axis_tready) begin
          full <= 1'b0;
          kp <= '0;
          cnt <= '0;
          lst_q <= 1'b0;
          usr_q <= '0;
          dat <= '0;
        end
        if (s_axis_tvalid && s_axis_tready) begin
          dat[cnt*IN_BYTES*8 +: IN_BYTES*8] <= s_axis_tdata;
          kp[cnt*IN_BYTES +: IN_BYTES] <= s_axis_tkeep;
          if (s_axis_tlast || cnt == RATIO - 1) begin
            full <= 1'b1;
            lst_q <= s_axis_tlast;
            usr_q <= s_axis_tuser;
          end
          else cnt <= cnt + 1'b1;
        end
      end
    end
  end
endmodule
