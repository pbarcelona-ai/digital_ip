// ***************
// Filename: axil_regbus_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_axil_regbus testbench
//   (axil_regbus_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     wr  AXI write with a random AW/W order and delay and late bready
//         (SLVERR expected on ERR_WORD)
//     rd  AXI read with late rready (SLVERR expected on ERR_WORD)
// Date: 2026-10-16
// ***************
  // AXI write with a random AW/W order and delay and late bready; the
  // model is updated with the strobed bytes
  task automatic wr(input int a, input logic [31:0] d, input logic [3:0] s);
    int order = $urandom_range(2, 0);        // 0: together, 1: AW first, 2: W first
    bit aw_done = 0, w_done = 0;
    int delay = $urandom_range(3, 0);
    @(negedge clk);
    s_axil.awaddr = ADDR_W'(a);
    s_axil.wdata = d;
    s_axil.wstrb = s;
    s_axil.awvalid = (order != 2);
    s_axil.wvalid = (order != 1);
    while (!(aw_done && w_done)) begin
      @(posedge clk);
      if (s_axil.awvalid && s_axil.awready) aw_done = 1;
      if (s_axil.wvalid && s_axil.wready)   w_done  = 1;
      @(negedge clk);
      if (aw_done) s_axil.awvalid = 0;
      if (w_done)  s_axil.wvalid  = 0;
      if (delay > 0) delay--;
      else begin
        if (!aw_done) s_axil.awvalid = 1;
        if (!w_done)  s_axil.wvalid  = 1;
      end
    end
    repeat ($urandom_range(3, 0)) @(negedge clk);   // late bready
    s_axil.bready = 1;
    do @(posedge clk);
    while (!s_axil.bvalid);
    checks++;
    if (s_axil.bresp !== (((a >> 2) == ERR_WORD) ? 2'b10 : 2'b00)) begin   // SLVERR on the error word
      errors++;
      $display("ERROR: write 0x%02h bresp %0d", a, s_axil.bresp);
    end
    @(negedge clk) s_axil.bready = 0;
    if ((a >> 2) != ERR_WORD)
      for (int b = 0; b < 4; b++) if (s[b]) model[a >> 2][b*8 +: 8] = d[b*8 +: 8];
  endtask

  // AXI read with late rready; R data must stay stable while stalled
  // and must equal the model
  task automatic rd(input int a);
    logic [31:0] d0;
    @(negedge clk);
    s_axil.araddr = ADDR_W'(a);
    s_axil.arvalid = 1;
    do @(posedge clk);
    while (!s_axil.arready);
    @(negedge clk);
    s_axil.arvalid = 0;
    wait (s_axil.rvalid);
    d0 = s_axil.rdata;
    repeat ($urandom_range(3, 0)) begin       // rdata must stay stable
      @(negedge clk);
      if (s_axil.rdata !== d0 || !s_axil.rvalid) begin
        errors++;
        $display("ERROR: R channel unstable");
      end
    end
    @(negedge clk) s_axil.rready = 1;
    do @(posedge clk);
    while (!s_axil.rvalid);
    checks++;
    if (s_axil.rdata !== model[a >> 2] || s_axil.rresp !== (((a >> 2) == ERR_WORD) ? 2'b10 : 2'b00)) begin
      errors++;
      $display("ERROR: read 0x%02h got 0x%08h exp 0x%08h", a, s_axil.rdata, model[a >> 2]);
    end
    @(negedge clk) s_axil.rready = 0;
  endtask
