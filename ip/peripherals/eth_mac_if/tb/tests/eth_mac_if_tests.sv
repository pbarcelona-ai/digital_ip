// ***************
// Filename: eth_mac_if_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the eth_mac_if_tb testbench
//   (eth_mac_if_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check          Counts an error and prints the message when the condition
//                    is false
//     send_frame_ok  Frame sender
//     inject_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // ---------------- frame sender ----------------
  task automatic send_frame_ok(input int n);
    byte f[$];
    int i;
    f.delete();
    for (int k = 0; k < n; k++) f.push_back($urandom);
    @(posedge clk);
    #1 sv = 1;
    sd = f[0];
    sl = (n == 1);
    i = 0;
    while (i < n) begin
      @(posedge clk);
      if (sr) begin
        i++;
        #1;
        if (i < n) begin
          sd = f[i];
          sl = (i == n - 1);
        end
      end else #1;
    end
    #1 sv = 0;
    sl = 0;
    foreach (f[k]) sent_data.push_back(f[k]);
    sent_len.push_back(n);
  endtask

  task automatic inject_frame(input int n, input int er_at);
    phy.send_frame(n, er_at);
  endtask
