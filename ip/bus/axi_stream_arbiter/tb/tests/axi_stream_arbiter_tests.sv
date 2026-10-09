// ***************
// Filename: axi_stream_arbiter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the axi_stream_arbiter_tb testbench
//   (axi_stream_arbiter_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     source  Stimulus
// Date: 2026-10-08
// ***************
  // stimulus: each source sends packets
  task automatic source(input int id, input int npk);
    for (int p = 0; p < npk; p++) begin
      int len;
      len = $urandom_range(1, 8);
      for (int b = 0; b < len; b++) begin
        @(posedge clk);
        #1 sv[id] = 1;
        sd[id*DW +: DW] = $urandom;
        sl[id] = (b == len - 1);
        sk[id*2 +: 2] = 2'b11;
        while (!sr[id]) begin
          @(posedge clk);
          #1;
        end
      end
      @(posedge clk);
      #1 sv[id] = 0;
      sl[id] = 0;
      if (gaps_en) repeat ($urandom_range(0, 4)) @(posedge clk);
      pkts_in[id]++;
    end
  endtask
