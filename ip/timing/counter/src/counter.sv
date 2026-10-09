// ***************
// Filename: counter.sv
// Author: FPGA Cores 4 U
// Description: Generic programmable up/down counter. Version 1.0.0.
//   DIRECTION 0 counts up from 0 to top_i then wraps to 0, 1 counts down
//   from top_i to 0 then reloads top_i, 2 selects up or down at run time
//   through dir_i (up wraps top->0, down wraps 0->top). Synchronous load
//   has priority over counting. wrap_o is a registered one-clock pulse on
//   every wrap. Clock - clk; en_i is a clock enable. Reset - synchronous
//   active low, count = 0. Latency - count_o updates one clock after en_i;
//   wrap_o in the same clock as the wrapped count. Errors - WIDTH < 1 or
//   invalid DIRECTION rejected at elaboration; load_val_i above top_i is
//   clamped to top_i.
// Date: 2026-09-29
module counter #(
  parameter int WIDTH     = 16,
  parameter int DIRECTION = 0            // 0 up, 1 down, 2 runtime
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             load_i,
  input  logic [WIDTH-1:0] load_val_i,
  input  logic [WIDTH-1:0] top_i,        // terminal value
  input  logic             dir_i,        // 1 = down (DIRECTION==2 only)
  output logic [WIDTH-1:0] count_o,
  output logic             wrap_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1) begin : g_bw $error("counter: WIDTH must be >= 1"); end
  if (DIRECTION < 0 || DIRECTION > 2) begin : g_bd $error("counter: DIRECTION must be 0..2"); end
  wire down = (DIRECTION == 1) ? 1'b1 : (DIRECTION == 2) ? dir_i : 1'b0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_o <= '0;
      wrap_o <= 1'b0;
    end
    else begin
      wrap_o <= 1'b0;
      if (load_i) count_o <= (load_val_i > top_i) ? top_i : load_val_i;
      else if (en_i) begin
        if (!down) begin
          if (count_o >= top_i) begin
            count_o <= '0;
            wrap_o <= 1'b1;
          end
          else count_o <= count_o + 1'b1;
        end else begin
          if (count_o == '0) begin
            count_o <= top_i;
            wrap_o <= 1'b1;
          end
          else count_o <= count_o - 1'b1;
        end
      end
    end
  end
endmodule
