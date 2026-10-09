// ***************
// Filename: packet_parser_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of pp_case, the test-case module of the
//   packet_parser testbench (packet_parser_tb.sv), moved out of it and
//   `included into that module, so they use its signals, parameters and
//   models directly. Tasks, in file order:
//     send
// Date: 2026-10-08
// ***************
  task automatic send(input int nbytes, input bit match_hdr);
    int idx; logic [HB*8-1:0] hh;
    pk.delete(); for (int i = 0; i < nbytes; i++) pk.push_back($urandom);
    if (nbytes >= HB) begin
      pk[0] = match_hdr ? 8'hA5 : 8'h5A; pk[1] = match_hdr ? 8'h3C : $urandom;
      hh = 0; for (int i = 0; i < HB; i++) hh[i*8 +: 8] = pk[i]; exp_hdr.push_back(hh);
      exp_len.push_back(nbytes);
    end else exp_runt.push_back(1);
    if (!STRIP) begin                                   // pass-through: everything is forwarded, nothing is dropped
      for (int i = 0; i < nbytes; i++) exp_out.push_back(pk[i]);
      exp_pkt_ends.push_back(exp_out.size());
    end else if (nbytes >= HB) begin
      if (!match_hdr) exp_drop.push_back(1);
      else begin
        for (int i = HB; i < nbytes; i++) exp_out.push_back(pk[i]);
        if (nbytes > HB) exp_pkt_ends.push_back(exp_out.size());
      end
    end
    idx = 0;
    while (idx < nbytes) begin
      logic [31:0] w32; logic [3:0] kp; w32 = 0; kp = 0;
      for (int b2 = 0; b2 < 4; b2++) if (idx + b2 < nbytes) begin w32[b2*8 +: 8] = pk[idx + b2]; kp[b2] = 1; end
      while ($urandom_range(0, 4) == 0) @(posedge clk);
      #1 sv = 1; sd = w32; sk = kp; sl = (idx + 4 >= nbytes); idx += 4;
      @(posedge clk); while (!sr) @(posedge clk);
      #1 sv = 0;
    end
  endtask
