// ***************
// Filename: packet_formatter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of pf_case, the test-case module of the
//   packet_formatter testbench (packet_formatter_tb.sv), moved out of it and
//   `included into that module, so they use its signals, parameters and
//   models directly. Tasks, in file order:
//     send
// Date: 2026-10-08
// ***************
  task automatic send(input int nbeats);
    logic [31:0] pl [8];
    logic [63:0] h; h[31:0] = $urandom; h[63:32] = $urandom; hdr = h; trl = $urandom; exp_h.push_back(h);
    for (int i = 0; i < 2; i++) exp_q.push_back({1'b0, h[i*32 +: 32]});
    for (int i = 0; i < nbeats; i++) begin pl[i] = $urandom; end
    begin int total; total = 2 + nbeats;
      for (int i = 0; i < nbeats; i++) exp_q.push_back({1'b0, pl[i]});
      if (TRL) begin while (total + 1 < MINB) begin exp_q.push_back(33'd0); total++; end exp_q.push_back({1'b0, trl}); total++; end
      else while (total < MINB) begin exp_q.push_back(33'd0); total++; end
      begin logic [32:0] lst; lst = exp_q[exp_q.size()-1]; lst[32] = 1; exp_q[exp_q.size()-1] = lst; end
    end
    for (int i = 0; i < nbeats; i++) begin
      while ($urandom_range(0, 3) == 0) @(posedge clk);
      #1 sv = 1; sd = pl[i]; sk = 4'hF; sl = (i == nbeats - 1);
      @(posedge clk); while (!sr) @(posedge clk);
      #1 sv = 0; hdr = h;
    end
    npk++; repeat (12) @(posedge clk);
  endtask
