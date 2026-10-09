// ***************
// Filename: axi_checkers_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_axi_checkers testbench
//   (axi_checkers_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     expect_err
//     stream_frame  Legal stream frame, random stalls
//     lite_write    Legal AXI-Lite write/read (acting as both master and
//                   slave)
//     lite_read
// Date: 2026-10-08
// ***************
  task automatic expect_err(input string what, input int prev, input int now);
    checks++;
    if (now <= prev) begin errors++; $display("ERROR: checker missed %s", what); end
    else $display("detected: %s", what);
  endtask

  // legal stream frame, random stalls; the "sink" readiness is random
  task automatic stream_frame();
    for (int y = 0; y < fh; y++)
      for (int x = 0; x < fw; x++) begin
        @(negedge clk);
        while ($urandom_range(3, 0) == 0) begin tvalid = 0; tready = $urandom_range(1, 0); @(negedge clk); end
        tvalid = 1; tdata = $urandom; tuser = (x == 0 && y == 0); tlast = (x == fw - 1);
        tready = $urandom_range(1, 0);
        @(posedge clk);
        while (!tready) begin @(negedge clk); tready = $urandom_range(1, 0); @(posedge clk); end
      end
    @(negedge clk) begin tvalid = 0; tuser = 0; tlast = 0; end
  endtask

  // legal AXI-Lite write/read (acting as both master and slave)
  task automatic lite_write(input int order);
    @(negedge clk);
    awaddr = $urandom; wdata = $urandom; wstrb = 4'hF;
    if (order != 2) awvalid = 1;
    if (order != 1) wvalid  = 1;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    awvalid = 1; wvalid = 1;
    if (order == 1) begin awready = 1; @(negedge clk); awvalid = 0; awready = 0; wready = 1; end
    else if (order == 2) begin wready = 1; @(negedge clk); wvalid = 0; wready = 0; awready = 1; end
    else begin awready = 1; wready = 1; end
    @(negedge clk); awvalid = 0; wvalid = 0; awready = 0; wready = 0;
    bvalid = 1; bresp = 0; bready = 0;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    bready = 1; @(negedge clk); bvalid = 0; bready = 0;
  endtask

  task automatic lite_read();
    @(negedge clk); araddr = $urandom; arvalid = 1;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    arready = 1; @(negedge clk); arvalid = 0; arready = 0;
    rvalid = 1; rdata = $urandom; rresp = 0; rready = 0;
    repeat ($urandom_range(2, 0)) @(negedge clk);
    rready = 1; @(negedge clk); rvalid = 0; rready = 0;
  endtask
