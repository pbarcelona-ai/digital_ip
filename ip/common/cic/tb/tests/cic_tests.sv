// ***************
// Filename: cic_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the cic_tb testbench (cic_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     mpush
//     feed
// Date: 2026-10-08
// ***************
  task automatic mpush(input int x);
    longint v [N+1];
    longint res, rnd, old [N];
    for (int k = 0; k < N; k++) old[k] = integ[k];                       // registers update in parallel
    integ[0] = wrap(old[0] + x);
    for (int k = 1; k < N; k++) integ[k] = wrap(old[k] + old[k-1]);
    if (mcnt == mr_lat - 1) begin
      v[0] = old[N-1];
      for (int k = 0; k < N; k++) begin
        v[k+1] = wrap(v[k] - cd[k]);
        cd[k] = v[k];
      end
      rnd = wrap(v[N] + (sh == 0 ? 0 : (64'd1 << (sh - 1))));
      res = rnd >>> sh;
      if (res > 32767) begin
        expq.push_back(16'sh7FFF);
        exp_sat.push_back(1);
      end
      else if (res < -32768) begin
        expq.push_back(16'sh8000);
        exp_sat.push_back(1);
      end
      else begin
        expq.push_back(res[15:0]);
        exp_sat.push_back(0);
      end
      mcnt = 0;
      mr_lat = (r == 0) ? 1 : (r > RM) ? RM : r;
    end else mcnt++;
  endtask

  task automatic feed(input int n, input int mode, input real freq);   // mode 0 random, 1 DC, 2 sine
    for (int i = 0; i < n; i++) begin
      int x;
      @(posedge clk);
      #1 vi = 1;
      x = (mode == 0) ? $urandom_range(0, 65535) - 32768 : (mode == 1) ? 1000 : $rtoi(10000.0 * $sin(6.283185307 * freq * i));
      din = x;
      mpush(x);
      nin++;
      if (mode == 0 && $urandom_range(0, 4) == 0) begin
        @(posedge clk);
        #1 vi = 0;
      end
    end
    @(posedge clk);
    #1 vi = 0;
  endtask
