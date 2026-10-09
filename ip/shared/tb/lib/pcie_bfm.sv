// ***************
// Filename: pcie_bfm.sv
// Author: FPGA Cores 4 U
// Description: PCI Express root complex bus functional model at the
//   transaction layer, connected to an endpoint's 64-bit TLP streams (two
//   DWs per beat, tkeep[4] marks the upper DW).
//   Requests: cfg_tlp() (CfgRd0 / CfgWr0, bus 1 dev 0 fn 0), mem_wr() /
//   mem_rd() (3DW or 4DW header, first / last byte enables, tag), or any
//   TLP built in tlp[] / tlp_n (dw0() makes the first header DW) and sent
//   with send_tlp(). The requester ID is HOST_ID.
//   Endpoint TLPs (completions, DMA writes) are accepted with random back
//   pressure: the DWs are appended to tx_flat, the DW count of each TLP to
//   tx_len.
// Date: 2026-10-09
`timescale 1ns/1ps

module pcie_bfm #(
  parameter logic [15:0] HOST_ID = 16'h00A0   // requester ID of the root complex
) (
  input  logic        clk,
  output logic [63:0] rx_d,                   // to the endpoint receive stream
  output logic [7:0]  rx_k,
  output logic        rx_l,
  output logic        rx_v,
  input  logic        rx_r,
  input  logic [63:0] tx_d,                   // from the endpoint transmit stream
  input  logic [7:0]  tx_k,
  input  logic        tx_l,
  input  logic        tx_v,
  output logic        tx_r
);
  initial begin
    rx_d = 0;
    rx_k = 0;
    rx_l = 0;
    rx_v = 0;
    tx_r = 1;
  end

  // ------------------------------------------------------------
  // TLP builder: fill tlp[] then send_tlp() packs 2 DWs per beat
  // ------------------------------------------------------------
  logic [31:0] tlp [0:63];
  int          tlp_n;
  function automatic logic [31:0] dw0(input logic [2:0] fmt, input logic [4:0] t,
                                      input int len);
    return {fmt, t, 1'b0, 3'b000, 4'b0000, 1'b0, 1'b0, 2'b00, 2'b00, 10'(len)};
  endfunction

  // ------------------------------------------------------------
  // Transmit capture (random back pressure), packet extraction
  // ------------------------------------------------------------
  logic [31:0] tx_flat [$];
  int          tx_len  [$];
  int          cur_len = 0;
  always @(posedge clk) tx_r <= ($urandom_range(0, 9) < 8);
  always @(posedge clk) if (tx_v && tx_r) begin
    tx_flat.push_back(tx_d[31:0]);
    cur_len++;
    if (tx_k[4]) begin
      tx_flat.push_back(tx_d[63:32]);
      cur_len++;
    end
    if (tx_l) begin
      tx_len.push_back(cur_len);
      cur_len = 0;
    end
  end

  task automatic send_tlp();
    for (int i = 0; i < tlp_n; i += 2) begin
      @(posedge clk);
      #1;
      rx_d = {(i + 1 < tlp_n) ? tlp[i+1] : 32'd0, tlp[i]};
      rx_k = (i + 1 < tlp_n) ? 8'hFF : 8'h0F;
      rx_l = (i + 2 >= tlp_n);
      rx_v = 1;
      wait (rx_r);
      @(posedge clk);
      #1 rx_v = 0;
      rx_l = 0;
    end
  endtask

  task automatic mem_wr(input logic [31:0] addr, input int n, input bit use4,
                        input logic [3:0] fbe, input logic [3:0] lbe,
                        input logic [7:0] tag, input logic [31:0] d0);
    tlp[0] = dw0(use4 ? 3'b011 : 3'b010, 5'b00000, n);
    tlp[1] = {HOST_ID, tag, lbe, fbe};
    if (use4) begin
      tlp[2] = 32'd0;
      tlp[3] = addr;
      tlp_n = 4;
    end
    else      begin
      tlp[2] = addr;
      tlp_n = 3;
    end
    for (int i = 0; i < n; i++) begin
      tlp[tlp_n] = d0 + i;
      tlp_n++;
    end
    send_tlp();
  endtask

  task automatic mem_rd(input logic [31:0] addr, input int n, input bit use4,
                        input logic [3:0] fbe, input logic [3:0] lbe,
                        input logic [7:0] tag);
    tlp[0] = dw0(use4 ? 3'b001 : 3'b000, 5'b00000, n);
    tlp[1] = {HOST_ID, tag, lbe, fbe};
    if (use4) begin
      tlp[2] = 32'd0;
      tlp[3] = addr;
      tlp_n = 4;
    end
    else      begin
      tlp[2] = addr;
      tlp_n = 3;
    end
    send_tlp();
  endtask

  task automatic cfg_tlp(input bit wr, input int reg_n, input logic [7:0] tag,
                         input logic [31:0] data);
    tlp[0] = dw0(wr ? 3'b010 : 3'b000, 5'b00100, 1);
    tlp[1] = {HOST_ID, tag, 4'h0, 4'hF};
    tlp[2] = {8'd1, 5'd0, 3'd0, 4'd0, 4'd0, 6'(reg_n), 2'b00};   // bus 1 dev 0 fn 0
    tlp_n = 3;
    if (wr) begin
      tlp[3] = data;
      tlp_n = 4;
    end
    send_tlp();
  endtask
endmodule
