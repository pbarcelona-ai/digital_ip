// ***************
// Filename: axi4_mem_model.sv
// Author: FPGA Cores 4 U
// Description: Behavioral AXI4 slave memory model for testbenches. 32 bit
//   data, INCR bursts up to 256 beats, byte strobes, random ready/valid
//   stalls (STALL percent), SLVERR for addresses beyond the memory size.
//   The mem array is accessible hierarchically so tests can preload and
//   inspect memory.
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_mem_model #(
  parameter int WORDS = 4096,           // memory size in 32 bit words
  parameter int STALL = 25              // percent of cycles ready/valid is held low
) (
  input  logic        aclk,
  input  logic        aresetn,
  input  logic [31:0] awaddr, input logic [7:0] awlen, input logic awvalid, output logic awready,
  input  logic [31:0] wdata, input logic [3:0] wstrb, input logic wlast, input logic wvalid, output logic wready,
  output logic [1:0]  bresp, output logic bvalid, input logic bready,
  input  logic [31:0] araddr, input logic [7:0] arlen, input logic arvalid, output logic arready,
  output logic [31:0] rdata, output logic [1:0] rresp, output logic rlast, output logic rvalid, input logic rready
);
  logic [31:0] mem [0:WORDS-1];
  logic rnd_a, rnd_w, rnd_r, rnd_ar;
  always @(posedge aclk) begin
    rnd_a  <= ($urandom_range(0, 99) >= STALL);
    rnd_w  <= ($urandom_range(0, 99) >= STALL);
    rnd_r  <= ($urandom_range(0, 99) >= STALL);
    rnd_ar <= ($urandom_range(0, 99) >= STALL);
  end
  int wr_bursts = 0, rd_bursts = 0, max_awlen = 0;
  // ---------------- write path ----------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_t;
  wst_t wst; logic [31:0] waddr; logic werr;
  assign awready = (wst == W_IDLE) & rnd_a;
  assign wready  = (wst == W_DATA) & rnd_w;
  always @(posedge aclk) begin
    if (!aresetn) begin wst <= W_IDLE; bvalid <= 0; bresp <= 0; end
    else case (wst)
      W_IDLE: if (awvalid & awready) begin
        waddr <= awaddr; werr <= 0; wst <= W_DATA; wr_bursts++;
        if (awlen > max_awlen) max_awlen = awlen;
        // AXI rule: a burst must not cross a 4 KB boundary
        if (({1'b0, awaddr[11:0]} + ((awlen + 1) << 2)) > 13'd4096)
          $display("ERROR (mem model): write burst crosses 4KB @%h len %0d", awaddr, awlen);
      end
      W_DATA: if (wvalid & wready) begin
        if (waddr[31:2] < WORDS) begin
          for (int b = 0; b < 4; b++) if (wstrb[b]) mem[waddr[31:2]][b*8 +: 8] <= wdata[b*8 +: 8];
        end else werr <= 1;
        waddr <= waddr + 4;
        if (wlast) begin wst <= W_RESP; bvalid <= 1; bresp <= (werr | (waddr[31:2] >= WORDS)) ? 2'b10 : 2'b00; end
      end
      W_RESP: if (bready) begin bvalid <= 0; wst <= W_IDLE; end
      default: wst <= W_IDLE;
    endcase
  end
  // ---------------- read path ----------------
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_t;
  rst_t rst; logic [31:0] raddr; int rleft;
  assign arready = (rst == R_IDLE) & rnd_ar;
  always @(posedge aclk) begin
    if (!aresetn) begin rst <= R_IDLE; rvalid <= 0; rlast <= 0; rdata <= 0; rresp <= 0; end
    else case (rst)
      R_IDLE: if (arvalid & arready) begin
        raddr <= araddr; rleft <= arlen + 1; rst <= R_DATA; rd_bursts++;
        if (({1'b0, araddr[11:0]} + ((arlen + 1) << 2)) > 13'd4096)
          $display("ERROR (mem model): read burst crosses 4KB @%h len %0d", araddr, arlen);
      end
      R_DATA: begin
        if (rvalid & rready & rlast) begin rvalid <= 0; rlast <= 0; rst <= R_IDLE; end
        else if (!rvalid || rready) begin
          if (rleft > 0 && rnd_r) begin
            rvalid <= 1; rdata <= (raddr[31:2] < WORDS) ? mem[raddr[31:2]] : 32'hBAD0_BAD0;
            rresp <= (raddr[31:2] < WORDS) ? 2'b00 : 2'b10;
            rlast <= (rleft == 1); rleft <= rleft - 1; raddr <= raddr + 4;
          end else rvalid <= 0;
        end
      end
      default: rst <= R_IDLE;
    endcase
  end
endmodule
