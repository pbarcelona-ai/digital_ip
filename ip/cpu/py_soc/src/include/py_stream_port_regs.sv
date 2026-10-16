// ***************
// Filename: py_stream_port_regs.sv
// Author: FPGA Cores 4 U
// Description: Register map of py_stream_port: its AXI4-Lite register slave
//   (axi4_lite_slave front end) with every register of the block, the ID
//   block first; the registers go to py_stream_port's logic on named ports,
//   its status comes back on input ports. AXI4-Lite to AXI-Stream data port:
//   TX FIFO writes, RX FIFO reads, FIFO status, interrupt enables. Generated
//   by ip/scripts/regmap_gen.py from py_stream_port_regs.json: edit the JSON
//   and regenerate (the IP_VERSION / IP_DATE stamps are kept).
//   Register map (ADDR_W = 8, byte offsets):
//     0x00 ID          RO   "PORT" IP identifier, 4 ASCII characters (first
//                       in [31:24])
//     0x04 VERSION     RO   version, ASCII "d.dd" (+0.01 at every source
//                       update)
//     0x08 DATE        RO   date of the last source update, BCD mm/dd/yyyy
//                       (0xMMDDYYYY)
//     0x0C reserved    RO   0
//     0x10 TXDATA      WO   pushed into the TX FIFO, or dropped with
//                       STATUS.TX_OVF set when it is full
//                       [23:0] DATA: data
//                       [24] LAST: tlast
//     0x14 RXDATA      RC   oldest received word; a read with VALID = 1
//                       removes it from the RX FIFO
//                       [23:0] DATA: data
//                       [24] LAST: tlast
//                       [31] VALID: 1: a word was read (0: the RX FIFO was
//                         empty)
//     0x18 STATUS      CMD  FIFO status; write 1 to [2] to clear TX_OVF
//                       [0] RX_VALID: RX FIFO not empty
//                       [1] TX_READY: TX FIFO not full
//                       [2] TX_OVF: a TXDATA write was dropped (W1C)
//                       [3] TX_EMPTY: TX FIFO empty
//                       [19:8] RX_LEVEL: words in the RX FIFO
//                       [31:20] TX_LEVEL: words in the TX FIFO
//     0x1C IRQ_EN      RW   irq_o while an enabled condition holds, reset 0x0
//                       [0] RX_VALID: RX FIFO not empty
//                       [1] TX_READY: TX FIFO not full
//                       [2] TX_EMPTY: TX FIFO empty
//   Access: RW read / write (byte strobes), RO read only (writes answer
//   SLVERR), W1C hardware sets / software writes 1 to clear (a set wins), W1S
//   software writes 1 to set / hardware clears, WO write only (reads 0), CMD
//   reads the hardware value, a write gives a pulse with its data. Unmapped
//   words read 0 and ignore writes; above the map: DECERR. Clock - aclk.
//   Reset - synchronous active low aresetn. Latency - 2 clocks per write and
//   read.
// Date: 2026-10-16
module py_stream_port_regs (
  input  logic          aclk,           // clock
  input  logic          aresetn,        // synchronous reset, active low
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
  axil_if.slave s_axil,
  // r: py_stream_port_regs_if.regs (src/include/py_stream_port_regs_if.sv) {txdata_o=cfg_txdata txdata_wr_o=cfg_txdata_wr rxdata_i=sts_rxdata rxdata_rd_o=cfg_rxdata_rd status_i=sts_status status_o=cfg_status status_wr_o=cfg_status_wr irq_en_o=cfg_irq_en irq_en_wr_o=cfg_irq_en_wr}
  py_stream_port_regs_if.regs r
);
  // register signals, joined to the interface r
  logic [25-1:0] txdata_o;
  logic txdata_wr_o;
  logic [32-1:0] rxdata_i;
  logic rxdata_rd_o;
  logic [32-1:0] status_i;
  logic [32-1:0] status_o;
  logic status_wr_o;
  logic [3-1:0] irq_en_o;
  logic irq_en_wr_o;
  assign r.cfg_txdata = txdata_o;
  assign r.cfg_txdata_wr = txdata_wr_o;
  assign rxdata_i = r.sts_rxdata;
  assign r.cfg_rxdata_rd = rxdata_rd_o;
  assign status_i = r.sts_status;
  assign r.cfg_status = status_o;
  assign r.cfg_status_wr = status_wr_o;
  assign r.cfg_irq_en = irq_en_o;
  assign r.cfg_irq_en_wr = irq_en_wr_o;
  // ---------------- register map
  localparam logic [31:0] IP_ID      = "PORT";
  localparam logic [31:0] IP_VERSION = "1.10";
  localparam logic [31:0] IP_DATE    = 32'h10122026;   // mm/dd/yyyy, BCD
  localparam logic [7:0] A_ID = 8'h0, A_VERSION = 8'h4, A_DATE = 8'h8;
  localparam logic [7:0] A_TXDATA = 8'h10;
  localparam logic [7:0] A_RXDATA = 8'h14;
  localparam logic [7:0] A_STATUS = 8'h18;
  localparam logic [7:0] A_IRQ_EN = 8'h1C;
  localparam int MAP_WORDS = 8;

  logic             wr_en, rd_en, wr_err_q;
  logic [7:0]       wr_addr, rd_addr, rd_addr_q;
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
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axil(s_axil),
    .bus(bus)
  );
  wire [7:0] wa = {wr_addr[7:2], 2'b00};
  // byte strobes applied to the written word
  logic [31:0] wmask;
  always_comb for (int b = 0; b < 4; b++) wmask[b*8 +: 8] = {8{wr_strb[b]}};

  // ---------------- writes
  logic [31:0] txdata_q;
  logic [31:0] status_q;
  logic [31:0] irq_en_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      txdata_q <= '0;
      txdata_wr_o <= 1'b0;
      status_q <= '0;
      status_wr_o <= 1'b0;
      irq_en_q <= 32'h0;
      irq_en_wr_o <= 1'b0;
      wr_err_q <= 1'b0;
    end else begin
      wr_err_q <= wr_en && (wa == A_ID || wa == A_VERSION || wa == A_DATE || wa == A_RXDATA);   // writes to read-only words: SLVERR
      begin
        txdata_wr_o <= wr_en && wa == A_TXDATA;
        if (wr_en && wa == A_TXDATA) txdata_q <= (txdata_q & ~wmask) | (wr_data & wmask);
      end
      begin
        status_wr_o <= wr_en && wa == A_STATUS;
        if (wr_en && wa == A_STATUS) status_q <= (status_q & ~wmask) | (wr_data & wmask);
      end
      begin
        irq_en_wr_o <= wr_en && wa == A_IRQ_EN;
        if (wr_en && wa == A_IRQ_EN) irq_en_q <= (irq_en_q & ~wmask) | (wr_data & wmask);
      end
    end
  end
  assign txdata_o = txdata_q[25-1:0];
  assign status_o = status_q[32-1:0];
  assign irq_en_o = irq_en_q[3-1:0];

  // ---------------- reads: the word addressed in the clock before
  always_ff @(posedge aclk) if (rd_en) rd_addr_q <= {rd_addr[7:2], 2'b00};
  always_comb begin
    rd_data = '0;
    case (rd_addr_q)
      A_ID:      rd_data = IP_ID;
      A_VERSION: rd_data = IP_VERSION;
      A_DATE:    rd_data = IP_DATE;
      A_RXDATA: rd_data = 32'(rxdata_i);
      A_STATUS: rd_data = 32'(status_i);
      A_IRQ_EN: rd_data = irq_en_q;
      default: begin
      end
    endcase
  end

  // ---------------- read pulses (RC): the clock the value is returned
  logic rd_take_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) rd_take_q <= 1'b0;
    else rd_take_q <= rd_en;
  end
  assign rxdata_rd_o = rd_take_q && rd_addr_q == A_RXDATA;
endmodule
