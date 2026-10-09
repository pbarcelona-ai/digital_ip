// ***************
// Filename: uart_bfm.sv
// Author: FPGA Cores 4 U
// Description: UART bus functional model: an asynchronous serial device
//   connected crosswise to the DUT (txd -> DUT receive input, rxd <- DUT
//   transmit output). Time based (bit_ns per bit), 5..8 data bits, optional
//   even / odd parity, one or two stop bits.
//   Transmitter: send_frame() drives one frame with full control, including
//   a wrong parity bit or a missing stop bit (error injection); send() and
//   send_string() use the line format in nbits / parity_en / parity_odd /
//   stop2; glitch() drives a short low pulse.
//   Receiver (rx_en): checks the start bit, then samples every DUT frame in
//   the middle of each bit
//   using the same line format, checks parity and stop bit(s), appends data
//   and error flags to rx_q / rx_perr_q / rx_ferr_q, updates rx_data /
//   rx_perr / rx_ferr / rx_count and triggers rx_done. Characters are also
//   assembled into text lines (LF ends a line, CR is dropped): line /
//   lines / line_count, line_done.
// Date: 2026-10-09
`timescale 1ns/1ps

module uart_bfm #(
  parameter real BIT_NS = 1000.0              // bit time in ns (1 Mbaud)
) (
  output logic txd,                           // BFM transmitter -> DUT receive input (idle high)
  input  logic rxd                            // DUT transmit output -> BFM receiver
);
  // line format (receiver, and send() / send_string())
  real bit_ns     = BIT_NS;
  int  nbits      = 8;
  bit  parity_en  = 0;
  bit  parity_odd = 0;
  bit  stop2      = 0;
  bit  rx_en      = 1;                        // receiver enable

  // receiver results
  logic [7:0] rx_data;                        // last frame
  bit         rx_perr, rx_ferr;               // last frame: parity / stop bit error
  int         rx_count = 0;
  int         rx_glitches = 0;                // falling edges that were not a valid start bit
  logic [7:0] rx_q[$];
  bit         rx_perr_q[$], rx_ferr_q[$];
  event       rx_done;
  string      line = "";                      // text line being received
  string      lines[$];                       // completed lines
  string      last_line = "";
  int         line_count = 0;
  event       line_done;

  initial txd = 1'b1;

  // ---------------- transmitter ----------------
  // One frame with explicit format; bad_par inverts the parity bit, bad_stop sends a 0 stop bit
  task automatic send_frame(input logic [7:0] b, input int nb, input bit pen, input bit podd, input bit two_stop,
                            input bit bad_par = 0, input bit bad_stop = 0);
    bit p;
    p = 0;
    txd = 0;                                  // start bit
    #(bit_ns);
    for (int i = 0; i < nb; i++) begin
      txd = b[i];
      p ^= b[i];
      #(bit_ns);
    end
    if (pen) begin
      txd = p ^ podd ^ bad_par;
      #(bit_ns);
    end
    txd = bad_stop ? 1'b0 : 1'b1;             // stop bit
    #(bit_ns);
    txd = 1'b1;
    if (bad_stop) #(bit_ns);                  // let the line recover
    if (two_stop) #(bit_ns);
  endtask

  // A short low pulse on the line (not a frame): receivers must reject it
  task automatic glitch(input real ns);
    txd = 0;
    #(ns);
    txd = 1'b1;
  endtask

  task automatic send(input logic [7:0] b);
    send_frame(b, nbits, parity_en, parity_odd, stop2);
  endtask

  task automatic send_string(input string s);
    for (int i = 0; i < s.len(); i++) send(s[i]);
  endtask

  // ---------------- receiver ----------------
  always @(negedge rxd) if (rx_en) begin
    logic [7:0] b;
    bit p, perr, ferr;
    #(bit_ns * 0.5);                          // middle of the start bit
    if (rxd != 1'b0) begin
      rx_glitches++;                          // not a start bit
    end else begin
      #(bit_ns);                              // middle of the first data bit
      b = 0;
      p = 0;
      for (int i = 0; i < nbits; i++) begin
        b[i] = rxd;
        p ^= rxd;
        #(bit_ns);
      end
      perr = 0;
      if (parity_en) begin
        perr = (rxd != (p ^ parity_odd));
        #(bit_ns);
      end
      ferr = (rxd != 1'b1);
      if (stop2) begin
        #(bit_ns);
        ferr |= (rxd != 1'b1);
      end
      rx_data = b;
      rx_perr = perr;
      rx_ferr = ferr;
      rx_q.push_back(b);
      rx_perr_q.push_back(perr);
      rx_ferr_q.push_back(ferr);
      rx_count++;
      if (b == 8'h0A) begin
        last_line = line;
        lines.push_back(line);
        line_count++;
        line = "";
        -> line_done;
      end else if (b != 8'h0D) begin
        line = $sformatf("%s%c", line, b);
      end
      -> rx_done;
    end
  end
endmodule
