// ***************
// Filename: ddr_ctrl_regs.sv
// Author: FPGA Cores 4 U
// Description: Register map of ddr_ctrl: its AXI4-Lite register slave
//   (axi4_lite_slave front end) with every register of the block, the ID
//   block first; the registers go to ddr_ctrl's logic on named ports, its
//   status comes back on input ports. Generic DDR controller: statistics
//   clear, status, and the statistics counters (32-bit, wrapping). Generated
//   by ip/scripts/regmap_gen.py from ddr_ctrl_regs.json: edit the JSON and
//   regenerate (the IP_VERSION / IP_DATE stamps are kept).
//   Register map (ADDR_W = 8, byte offsets):
//     0x00 ID          RO   "DDRC" IP identifier, 4 ASCII characters (first
//                       in [31:24])
//     0x04 VERSION     RO   version, ASCII "d.dd" (+0.01 at every source
//                       update)
//     0x08 DATE        RO   date of the last source update, BCD mm/dd/yyyy
//                       (0xMMDDYYYY)
//     0x0C reserved    RO   0
//     0x10 CTRL        WO   [0] write 1: clear the statistics
//     0x14 STATUS      RO   [0] a burst active, [4:1] refreshes owed
//     0x18 RD_BEATS    RO   memory read beats (RD commands)
//     0x1C WR_BEATS    RO   memory write beats (WR commands)
//     0x20 ACTS        RO   ACT commands (row openings)
//     0x24 HITS        RO   memory beats issued without an ACT for the beat
//                       (row hits)
//     0x28 REFS        RO   REF commands
//     0x2C ERRS        RO   error bursts (SLVERR: size or burst type, DECERR:
//                       beyond the memory)
//   Access: RW read / write (byte strobes), RO read only (writes answer
//   SLVERR), W1C hardware sets / software writes 1 to clear (a set wins), W1S
//   software writes 1 to set / hardware clears, WO write only (reads 0), CMD
//   reads the hardware value, a write gives a pulse with its data. Unmapped
//   words read 0 and ignore writes; above the map: DECERR. Clock - clk. Reset
//   - synchronous active low rst_n. Latency - 2 clocks per write and read.
// Date: 2026-10-21
module ddr_ctrl_regs (
  input  logic          clk,            // clock
  input  logic          rst_n,          // synchronous reset, active low
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
  axil_if.slave s_axil,
  // r: ddr_ctrl_regs_if.regs (src/include/ddr_ctrl_regs_if.sv) {ctrl_o=cfg_ctrl ctrl_wr_o=cfg_ctrl_wr status_i=sts_status rd_beats_i=sts_rd_beats wr_beats_i=sts_wr_beats acts_i=sts_acts hits_i=sts_hits refs_i=sts_refs errs_i=sts_errs}
  ddr_ctrl_regs_if.regs r
);
  // register signals, joined to the interface r
  logic ctrl_o;
  logic ctrl_wr_o;
  logic [5-1:0] status_i;
  logic [32-1:0] rd_beats_i;
  logic [32-1:0] wr_beats_i;
  logic [32-1:0] acts_i;
  logic [32-1:0] hits_i;
  logic [32-1:0] refs_i;
  logic [32-1:0] errs_i;
  assign r.cfg_ctrl = ctrl_o;
  assign r.cfg_ctrl_wr = ctrl_wr_o;
  assign status_i = r.sts_status;
  assign rd_beats_i = r.sts_rd_beats;
  assign wr_beats_i = r.sts_wr_beats;
  assign acts_i = r.sts_acts;
  assign hits_i = r.sts_hits;
  assign refs_i = r.sts_refs;
  assign errs_i = r.sts_errs;
  // ---------------- register map
  localparam logic [31:0] IP_ID      = "DDRC";
  localparam logic [31:0] IP_VERSION = "1.00";
  localparam logic [31:0] IP_DATE    = 32'h10212026;   // mm/dd/yyyy, BCD
  localparam logic [7:0] A_ID = 8'h0, A_VERSION = 8'h4, A_DATE = 8'h8;
  localparam logic [7:0] A_CTRL = 8'h10;
  localparam logic [7:0] A_STATUS = 8'h14;
  localparam logic [7:0] A_RD_BEATS = 8'h18;
  localparam logic [7:0] A_WR_BEATS = 8'h1C;
  localparam logic [7:0] A_ACTS = 8'h20;
  localparam logic [7:0] A_HITS = 8'h24;
  localparam logic [7:0] A_REFS = 8'h28;
  localparam logic [7:0] A_ERRS = 8'h2C;
  localparam int MAP_WORDS = 12;

  logic             wr_en, rd_en, wr_err_q;
  logic [7:0]       wr_addr, rd_addr, rd_addr_q;
  wire unused_addr_lsbs = &{1'b0, wr_addr[1:0], rd_addr[1:0]};   // word access: the byte offset is not decoded
  logic [31:0]      wr_data, rd_data;
  logic [3:0]       wr_strb;
  regbus_if #(.ADDR_W(8)) bus ();               // register bus of the AXI4-Lite front end
  assign wr_en = bus.wr;
  assign wr_addr = bus.waddr;
  assign wr_data = bus.wdata;
  assign wr_strb = bus.wstrb;
  assign rd_en = bus.rd;
  assign rd_addr = bus.raddr;
  assign bus.wr_err = wr_err_q;
  assign bus.rdata = rd_data;
  assign bus.rd_valid = 1'b1;
  assign bus.rd_err = 1'b0;
  axi4_lite_slave #(
    .ADDR_W(8),
    .READ_WAIT(0),
    .MAP_WORDS(MAP_WORDS)
  ) u_axil (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axil(s_axil),
    .bus(bus)
  );
  wire [7:0] wa = {wr_addr[7:2], 2'b00};
  // byte strobes applied to the written word
  logic [31:0] wmask;
  always_comb for (int b = 0; b < 4; b++) wmask[b*8 +: 8] = {8{wr_strb[b]}};

  // ---------------- writes
  logic [31:0] ctrl_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctrl_q <= '0;
      ctrl_wr_o <= 1'b0;
      wr_err_q <= 1'b0;
    end else begin
      wr_err_q <= wr_en && (wa == A_ID || wa == A_VERSION || wa == A_DATE || wa == A_STATUS || wa == A_RD_BEATS || wa == A_WR_BEATS || wa == A_ACTS || wa == A_HITS || wa == A_REFS || wa == A_ERRS);   // writes to read-only words: SLVERR
      begin
        ctrl_wr_o <= wr_en && wa == A_CTRL;
        if (wr_en && wa == A_CTRL) ctrl_q <= (ctrl_q & ~wmask) | (wr_data & wmask);
      end
    end
  end
  assign ctrl_o = ctrl_q[1-1:0];

  // ---------------- reads: the word addressed in the clock before
  always_ff @(posedge clk) if (rd_en) rd_addr_q <= {rd_addr[7:2], 2'b00};
  always_comb begin
    rd_data = '0;
    case (rd_addr_q)
      A_ID:      rd_data = IP_ID;
      A_VERSION: rd_data = IP_VERSION;
      A_DATE:    rd_data = IP_DATE;
      A_STATUS: rd_data = 32'(status_i);
      A_RD_BEATS: rd_data = 32'(rd_beats_i);
      A_WR_BEATS: rd_data = 32'(wr_beats_i);
      A_ACTS: rd_data = 32'(acts_i);
      A_HITS: rd_data = 32'(hits_i);
      A_REFS: rd_data = 32'(refs_i);
      A_ERRS: rd_data = 32'(errs_i);
      default: begin
      end
    endcase
  end
endmodule
