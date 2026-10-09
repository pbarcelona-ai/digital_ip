// ***************
// Filename: spi_flash_bfm.sv
// Author: FPGA Cores 4 U
// Description: SPI NOR flash bus functional model (behavioral serial flash device)
//   driven by sclk / cs_n / mosi, answering on miso. Used by spi_flash_ctrl
//   and by the py_soc / video_processor system testbenches (boot flash).
// Date: 2026-10-09
`timescale 1ns/1ps

module spi_flash_bfm (input logic sclk, input logic cs_n, input logic mosi, output logic miso, output int wip_cycles);
  byte mem [0:65535];
  logic wel = 0, wip = 0;
  int bitc = 0, nb = 0;
  logic [7:0] sh, cmd, outb;
  logic [23:0] adr;
  bit ignore = 0;
  logic [23:0] ta;
  int pg_a[$];
  byte pg_d[$];
  bit pend_erase = 0;
  logic [23:0] erase_a;
  bit pend_wel = 0, pend_wel_clr = 0;
  initial begin
    for (int i = 0; i < 65536; i++) mem[i] = 8'hFF;
    miso = 0;
    wip_cycles = 0;
  end
  function automatic logic [7:0] id_byte(input int i);
    return (i == 0) ? 8'hEF : (i == 1) ? 8'h40 : 8'h17 + i - 2;
  endfunction
  always @(negedge cs_n) begin
    bitc = 0;
    nb = 0;
    ignore = 0;
    pg_a.delete();
    pg_d.delete();
    pend_erase = 0;
    pend_wel = 0;
    pend_wel_clr = 0;
    outb = 0;
  end
  always @(posedge sclk) if (!cs_n) begin
    sh = {sh[6:0], mosi};
    bitc++;
    if (bitc % 8 == 0) begin
      nb++;
      if (nb == 1) begin
        cmd = sh;
        outb = 8'h00;
        if (cmd == 8'h05) outb = {6'd0, wel, wip};
        if (cmd == 8'h06) pend_wel = 1;
        if (cmd == 8'h04) pend_wel_clr = 1;
        if (cmd == 8'h9F) outb = id_byte(0);
        if ((cmd == 8'h02 || cmd == 8'h20) && !wel) ignore = 1;
      end else begin
        case (cmd)
          8'h03, 8'h0B, 8'h02, 8'h20: begin
            if (nb <= 4) adr = {adr[15:0], sh};
            if (cmd == 8'h03 && nb == 4) outb = mem[adr[15:0]];
            else if (cmd == 8'h03 && nb > 4) begin
              adr = adr + 1;
              outb = mem[adr[15:0]];
            end
            if (cmd == 8'h0B && nb == 5) outb = mem[adr[15:0]];
            else if (cmd == 8'h0B && nb > 5) begin
              adr = adr + 1;
              outb = mem[adr[15:0]];
            end
            if (cmd == 8'h02 && nb >= 5 && !ignore) begin
              pg_a.push_back({adr[23:8], adr[7:0]});
              pg_d.push_back(sh);
              adr[7:0] = adr[7:0] + 1; // wraps inside the page
            end
            if (cmd == 8'h20 && nb == 4 && !ignore) begin
              pend_erase = 1;
              erase_a = adr;
            end
          end
          8'h9F: outb = id_byte(nb - 1);
          8'h05: outb = {6'd0, wel, wip};
          default: ;
        endcase
      end
    end
  end
  always @(negedge sclk) if (!cs_n) miso <= outb[7 - (bitc % 8)];
  always @(posedge cs_n) begin
    if (pend_wel) wel = 1;
    if (pend_wel_clr) wel = 0;
    if (cmd == 8'h02 && !ignore && pg_a.size() > 0) begin
      foreach (pg_a[i]) begin
        ta = pg_a[i];
        mem[ta[15:0]] = mem[ta[15:0]] & pg_d[i];
      end
      wip = 1;
      wel = 0;
      fork
        begin
          #1500;
          wip = 0;
          wip_cycles++;
        end
      join_none
    end
    if (pend_erase) begin
      for (int i = 0; i < 4096; i++) mem[{erase_a[15:12], 12'd0} + i] = 8'hFF;
      wip = 1;
      wel = 0;
      fork
        begin
          #3000;
          wip = 0;
          wip_cycles++;
        end
      join_none
    end
    pg_a.delete();
    pg_d.delete();
    pend_erase = 0;
  end
endmodule
