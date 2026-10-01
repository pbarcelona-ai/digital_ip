// ***************
// Filename: rst_sync.sv
// Author: FPGA Cores 4 U
// Description: Reset synchronizer with asynchronous assertion and synchronous
//   de-assertion. Parameterized number of flop stages, input and output
//   polarity, and a minimum reset pulse stretch counter so short glitches
//   still produce a clean reset pulse of at least HOLD cycles. Works at any
//   clock frequency because it is cycle based. Version 1.0.0. Helper block of
//   its IP; see the top level description for clock, reset, latency and error
//   behavior. Clock - the clock of the parent block, all signals are
//   synchronous to it. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
//   synchronous to it. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module rst_sync #(
  parameter int STAGES         = 3,   // synchronizer flops (>=2)
  parameter bit ACTIVE_LOW_IN  = 1,   // polarity of rst_i
  parameter bit ACTIVE_LOW_OUT = 1,   // polarity of rst_o
  parameter bit ASYNC_ASSERT   = 1    // 1: async assert, 0: sync assert
) (
  input  logic                  clk,
  input  logic                  rst_i,      // asynchronous request
  input  logic [15:0]           hold_i,     // min cycles reset stays active
  output logic                  rst_o,      // synchronized reset
  output logic                  active_o    // 1 while reset is asserted
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_chk_stg $error("%m: STAGES must be >= 2"); end

  // Normalize the input to active-high
  wire req = ACTIVE_LOW_IN ? ~rst_i : rst_i;

  (* async_reg = "true", shreg_extract = "no" *) logic [STAGES-1:0] sync_q;
  logic [15:0] hold_cnt;
  logic        stretch;                    // pulse stretch active

  // Synchronizer chain: async set (reset asserted) / sync clear
  generate
    if (ASYNC_ASSERT) begin : g_async
      always_ff @(posedge clk or posedge req) begin
        if (req) sync_q <= '1;
        else     sync_q <= {sync_q[STAGES-2:0], 1'b0};
      end
    end else begin : g_sync
      always_ff @(posedge clk) begin
        sync_q <= {sync_q[STAGES-2:0], req};
      end
    end
  endgenerate

  wire rst_sync_hi = sync_q[STAGES-1];       // synchronized, active-high

  // Pulse stretcher: reload counter whenever reset is seen
  always_ff @(posedge clk) begin
    if (rst_sync_hi) begin
      hold_cnt <= hold_i;
      stretch  <= (hold_i != 16'd0);
    end else if (hold_cnt != 16'd0) begin
      hold_cnt <= hold_cnt - 16'd1;
      stretch  <= (hold_cnt != 16'd1);
    end else begin
      stretch  <= 1'b0;
    end
  end

  // Registered output for clean timing. In async mode the output flop is
  // also set asynchronously so the reset asserts without a clock edge.
  logic out_q;
  generate
    if (ASYNC_ASSERT) begin : g_out_async
      always_ff @(posedge clk or posedge req) begin
        if (req) out_q <= 1'b1;
        else     out_q <= rst_sync_hi | stretch;
      end
    end else begin : g_out_sync
      always_ff @(posedge clk) out_q <= rst_sync_hi | stretch;
    end
  endgenerate

  assign active_o = out_q;
  assign rst_o    = ACTIVE_LOW_OUT ? ~out_q : out_q;
endmodule
