// ***************
// Filename: frame_counter.sv
// Author: FPGA Cores 4 U
// Description: Frame counters for the video pipeline. Version 1.0.0.
//   NCH 32-bit counters, each advanced by an end-of-frame marker pulse
//   (eof_i[i], one clock): in video_processor channel 0 counts the frames
//   leaving the first pipeline stage (csi2_raw_unpack) and channel 1 the
//   frames reaching the last stream stage (into axis_to_video). Every
//   marker also sets STATUS[i]; irq_o[i] = STATUS[i] & IRQ_EN[i] (level,
//   until the CPU writes 1 to STATUS[i]), so the CPU can read COUNT[i] at
//   each end of frame. A marker in the same clock as a CLEAR still counts
//   (the counter becomes 1).
//   AXI4-Lite (ADDR_W = 8):
//     0x00 ID       RO "FCNT"
//     0x04 VERSION  RO 0x0001_0000
//     0x08 IRQ_EN   [NCH-1:0] interrupt enable per channel (reset 0)
//     0x0C STATUS   [NCH-1:0] end of frame seen, write 1 to clear
//     0x10 CLEAR    write: [NCH-1:0] 1 clears COUNT[i]
//     0x20 + 4 i    COUNT[i] RO frames counted by channel i
//   Clock - clk (the pipeline pixel clock). Reset - synchronous active low
//   rst_n.
// Date: 2026-10-08
module frame_counter #(
  parameter int NCH = 2                          // counters (1..8)
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [NCH-1:0] eof_i,                  // end-of-frame marker pulses
  output logic [NCH-1:0] irq_o,                  // per channel: end of frame, enabled, not yet cleared
  input  logic [7:0]     s_axil_awaddr,
  input  logic           s_axil_awvalid,
  output logic           s_axil_awready,
  input  logic [31:0]    s_axil_wdata,
  input  logic [3:0]     s_axil_wstrb,
  input  logic           s_axil_wvalid,
  output logic           s_axil_wready,
  output logic [1:0]     s_axil_bresp,
  output logic           s_axil_bvalid,
  input  logic           s_axil_bready,
  input  logic [7:0]     s_axil_araddr,
  input  logic           s_axil_arvalid,
  output logic           s_axil_arready,
  output logic [31:0]    s_axil_rdata,
  output logic [1:0]     s_axil_rresp,
  output logic           s_axil_rvalid,
  input  logic           s_axil_rready
);
  if (NCH < 1 || NCH > 8) begin : g_bad_nch $error("frame_counter: NCH must be 1..8"); end

  localparam int NREG = 8 + NCH;                 // 0x00-0x1C control, 0x20+ counters
  localparam int R_IRQ_EN = 2, R_STATUS = 3, R_CLEAR = 4, R_COUNT = 8;

  logic [NREG*32-1:0] regs, rd;
  logic [NREG-1:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(NREG)) u_regs (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .reg_o(regs),
    .wr_pulse_o(wr_pulse),
    .wr_data_o(wr_data),
    .rd_i(rd)
  );

  wire [NCH-1:0] irq_en = regs[R_IRQ_EN*32 +: NCH];
  logic [NCH-1:0] status;
  logic [31:0] count [NCH];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      status <= '0;
      for (int i = 0; i < NCH; i++) count[i] <= '0;
    end else begin
      for (int i = 0; i < NCH; i++) begin
        if (wr_pulse[R_CLEAR] && wr_data[i]) count[i] <= eof_i[i] ? 32'd1 : 32'd0;
        else if (eof_i[i])                  count[i] <= count[i] + 32'd1;
      end
      // a marker in the clock of the write-1-to-clear wins (it is a new end of frame)
      status <= ((wr_pulse[R_STATUS] ? status & ~wr_data[NCH-1:0] : status)) | eof_i;
    end
  end
  assign irq_o = status & irq_en;

  always_comb begin
    rd = '0;
    rd[0*32 +: 32] = 32'h46434E54;               // "FCNT"
    rd[1*32 +: 32] = 32'h0001_0000;
    rd[R_IRQ_EN*32 +: NCH] = irq_en;
    rd[R_STATUS*32 +: NCH] = status;
    for (int i = 0; i < NCH; i++) rd[(R_COUNT + i)*32 +: 32] = count[i];
  end
endmodule
