// ***************
// Filename: fir_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the fir_tb testbench (fir_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     setc
//     push
//     sample
// Date: 2026-10-08
// ***************
  task automatic setc(input int k, input int v);
    @(posedge clk);
    #1 cwe = 1;
    cidx = k;
    cval = v;
    @(posedge clk);
    #1 cwe = 0;
    cm[k] = v;
  endtask

  task automatic push(input int x);
    longint acc, r, pr [T];
    for (int k = 0; k < T; k++) pr[k] = x * cm[k];
    acc = pr[0] + zm[0];
    for (int k = 0; k < T - 2; k++) zm[k] = pr[k+1] + zm[k+1];
    zm[T-2] = pr[T-1];
    r = (acc + (1 << (SH - 1))) >>> SH;
    if (r > 32767) begin
      expq.push_back(16'sh7FFF);
      satq.push_back(1);
    end
    else if (r < -32768) begin
      expq.push_back(16'sh8000);
      satq.push_back(1);
    end
    else begin
      expq.push_back(r[15:0]);
      satq.push_back(0);
    end
  endtask

  task automatic sample(input int x);
    @(posedge clk);
    #1 vi = 1;
    din = x;
    push(x);
    @(posedge clk);
    #1 vi = 0;
  endtask
