// ***************
// Filename: axil_regbus_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_axil_regbus testbench
//   (axil_regbus_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     wr  AXI write with a random AW/W order and delay and late bready
//     rd  AXI read with late rready
// Date: 2026-10-08
// ***************
  // AXI write with a random AW/W order and delay and late bready; the
  // model is updated with the strobed bytes
  task automatic wr(input int a, input logic [31:0] d, input logic [3:0] s);
    int order = $urandom_range(2, 0);        // 0: together, 1: AW first, 2: W first
    bit aw_done = 0, w_done = 0;
    int delay = $urandom_range(3, 0);
    @(negedge clk);
    awaddr = ADDR_W'(a);
    wdata = d;
    wstrb = s;
    awvalid = (order != 2);
    wvalid = (order != 1);
    while (!(aw_done && w_done)) begin
      @(posedge clk);
      if (awvalid && awready) aw_done = 1;
      if (wvalid && wready)   w_done  = 1;
      @(negedge clk);
      if (aw_done) awvalid = 0;
      if (w_done)  wvalid  = 0;
      if (delay > 0) delay--;
      else begin
        if (!aw_done) awvalid = 1;
        if (!w_done)  wvalid  = 1;
      end
    end
    repeat ($urandom_range(3, 0)) @(negedge clk);   // late bready
    bready = 1;
    do @(posedge clk);
    while (!bvalid);
    checks++;
    if (bresp !== 2'b00) begin
      errors++;
      $display("ERROR: bresp");
    end
    @(negedge clk) bready = 0;
    for (int b = 0; b < 4; b++) if (s[b]) model[a >> 2][b*8 +: 8] = d[b*8 +: 8];
  endtask

  // AXI read with late rready; R data must stay stable while stalled
  // and must equal the model
  task automatic rd(input int a);
    logic [31:0] d0;
    @(negedge clk);
    araddr = ADDR_W'(a);
    arvalid = 1;
    do @(posedge clk);
    while (!arready);
    @(negedge clk);
    arvalid = 0;
    wait (rvalid);
    d0 = rdata;
    repeat ($urandom_range(3, 0)) begin       // rdata must stay stable
      @(negedge clk);
      if (rdata !== d0 || !rvalid) begin
        errors++;
        $display("ERROR: R channel unstable");
      end
    end
    @(negedge clk) rready = 1;
    do @(posedge clk);
    while (!rvalid);
    checks++;
    if (rdata !== model[a >> 2] || rresp !== 2'b00) begin
      errors++;
      $display("ERROR: read 0x%02h got 0x%08h exp 0x%08h", a, rdata, model[a >> 2]);
    end
    @(negedge clk) rready = 0;
  endtask
