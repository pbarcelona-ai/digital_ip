// ***************
// Filename: py_soc.sv
// Author: FPGA Cores 4 U
// Description: Python microcontroller. py_core plus code/constant memory,
//   a flash boot loader, an AXI4-Lite interconnect and the library
//   peripherals: SPI NOR flash controller, 2x UART, 2x I2C master, 2x SPI
//   master, 3x 32-bit GPIO, watchdog and interrupt controller. Every
//   streaming data path (UART, I2C, SPI, flash) goes through a
//   py_stream_port with its own TX and RX FIFO (*_TX_FIFO / *_RX_FIFO
//   words, default 16), so receive can be polled (RXDATA valid bit) or
//   interrupt driven (IRQ_EN).
//   Every peripheral instance has its own parameter set: UART0 / UART1
//   (*_BAUD, *_TX_FIFO, *_RX_FIFO), I2C0 / I2C1 (*_HZ, FIFOs), SPI0 / SPI1
//   (*_HZ, *_DATA_W, FIFOs), FLASH (FLASH_CLKDIV, FIFOs). The shared
//   UART_BAUD, I2C_HZ, SPI_HZ and *_TX/RX_FIFO parameters are the defaults
//   of both instances of a kind.
//
//   Boot - on every release of reset (rst_n or watchdog) py_boot owns the
//   bus, copies the pyc.py image from flash address BOOT_ADDR into code and
//   constant memory, checks it, and starts the core at pc 0. boot_done_o /
//   boot_err_o / boot_err_code_o report the result; a bad image leaves the
//   core stopped. After boot the core owns the bus, and the flash stays
//   available to software (e.g. data logging) at 0xC000.
//
//   Address map (each window 256 bytes; *_D = py_stream_port data port):
//     0x0100 SYSCTL (reset cause, boot status, cycle counter, ID, CORE_RESET)
//     0x1000 INTC   0x2000 WDT    0x3000 GPIO0  0x4000 GPIO1  0x5000 GPIO2
//     0x6000 UART0  0x6100 UART0_D  0x7000 UART1  0x7100 UART1_D
//     0x8000 I2C0   0x8100 I2C0_D   0x9000 I2C1   0x9100 I2C1_D
//     0xA000 SPI0   0xA100 SPI0_D   0xB000 SPI1   0xB100 SPI1_D
//     0xC000 FLASH  0xC100 FLASH_D
//     0x1_0000-0x1_FFFF EXT (EXT_EN = 1): the m_ext_axil_* master port, for
//                       registers outside py_soc (address offset in the window)
//   Unmapped addresses return DECERR (core trap TRAP_BUS).
//
//   Core logic reset - core_rst_n_o follows SYSCTL CORE_RESET[0] (0x0110):
//   low from every system reset until the firmware writes 1, so the logic
//   outside py_soc (e.g. a video datapath) stays in reset until the CPU has
//   booted and tested itself. Synchronous to clk; synchronise it per clock
//   domain (reset_sync) where it is used.
//
//   Interrupt controller sources (all level):
//     0 UART0_D  1 UART1_D  2 I2C0_D  3 I2C1_D  4 SPI0_D  5 SPI1_D
//     6 GPIO0    7 GPIO1    8 GPIO2   9 WDT pre-timeout
//     10 FLASH command done  11 FLASH_D
//     12-15 ext_irq_i[3:0] (level, synchronous to clk; tie low if unused)
//
//   Reset - rst_n (synchronous, active low) resets everything. A watchdog
//   expiry is stretched to WDT_RST_CYCLES clocks (wdt_reset_o) and resets
//   the whole system, watchdog included, so it comes back disabled like
//   any other reset; the system then boots from flash again. Clock - clk
//   only.
//
//   Clock generator (CLKGEN_EN = 1) - clk is then the reference clock
//   (REF_KHZ) and rst_n an asynchronous reset. clk_gen (ip/clock/clk_gen,
//   two all-digital PLLs) makes the CPU clock REF_KHZ * CPU_M / (CPU_D *
//   CPU_O), a clock multiplier, which runs everything in py_soc (cpu_clk_o),
//   and NCLK further clocks clk_o[n] = CPU clock * CLK_M / (CLK_D *
//   CLK_O[n]), phase aligned with each other. The system stays in reset
//   until the CPU loop is locked (cpu_rst_n_o, synchronous to cpu_clk_o,
//   for logic outside py_soc in the CPU clock domain). SYSCTL CLK_EN
//   (0x0114) gates each clk_o[n] (reset value CLK_EN_RST), CLK_STATUS
//   (0x0118) bit 0 shows the output loop locked, and core_rst_n_o is only
//   released while it is (CORE_RESET AND locked, registered), so the core
//   logic reset keeps a single source. With CLKGEN_EN = 0 (default) clk is
//   the CPU clock, cpu_clk_o = clk, cpu_rst_n_o = rst_n, clk_o = 0. CLK_HZ
//   is the CPU clock frequency in both cases (checked against the clock
//   generator setting to 100 ppm). Defaults: CLKGEN_EN = 1, 33.333 MHz
//   reference, CPU 200 MHz (x24 / 4), one 100 MHz output (x4 / 8); UART
//   115200 baud, I2C 400 kHz, SPI 10 MHz, boot flash 33 MHz. For synthesis only the PLL oscillators
//   (dpll_dco) are black boxes; see clk_gen.sv.
// Date: 2026-10-09
module py_soc #(
  parameter int          CLK_HZ       = 200_000_000,  // CPU clock (with CLKGEN_EN: the generated one)
  parameter int          UART_BAUD    = 115_200,
  parameter int          I2C_HZ       = 400_000,       // fast mode
  parameter int          SPI_HZ       = 10_000_000,
  // Data-port FIFO depths in words (powers of two >= 2)
  parameter int          UART_TX_FIFO = 16,
  parameter int          UART_RX_FIFO = 16,
  parameter int          I2C_TX_FIFO  = 16,
  parameter int          I2C_RX_FIFO  = 16,
  parameter int          SPI_TX_FIFO  = 16,
  parameter int          SPI_RX_FIFO  = 16,
  parameter int          FLASH_TX_FIFO = 16,
  parameter int          FLASH_RX_FIFO = 16,
  // Per instance (default: the shared value above)
  parameter int          UART0_BAUD    = UART_BAUD,
  parameter int          UART0_TX_FIFO = UART_TX_FIFO,
  parameter int          UART0_RX_FIFO = UART_RX_FIFO,
  parameter int          UART1_BAUD    = UART_BAUD,
  parameter int          UART1_TX_FIFO = UART_TX_FIFO,
  parameter int          UART1_RX_FIFO = UART_RX_FIFO,
  parameter int          I2C0_HZ       = I2C_HZ,
  parameter int          I2C0_TX_FIFO  = I2C_TX_FIFO,
  parameter int          I2C0_RX_FIFO  = I2C_RX_FIFO,
  parameter int          I2C1_HZ       = I2C_HZ,
  parameter int          I2C1_TX_FIFO  = I2C_TX_FIFO,
  parameter int          I2C1_RX_FIFO  = I2C_RX_FIFO,
  parameter int          SPI0_HZ       = SPI_HZ,
  parameter int          SPI0_DATA_W   = 16,              // max bits per SPI word (<= 24)
  parameter int          SPI0_TX_FIFO  = SPI_TX_FIFO,
  parameter int          SPI0_RX_FIFO  = SPI_RX_FIFO,
  parameter int          SPI1_HZ       = SPI_HZ,
  parameter int          SPI1_DATA_W   = 16,
  parameter int          SPI1_TX_FIFO  = SPI_TX_FIFO,
  parameter int          SPI1_RX_FIFO  = SPI_RX_FIFO,
  parameter int          CODE_AW      = 13,
  parameter int          CONST_AW     = 8,
  parameter logic [23:0] BOOT_ADDR    = 24'h00_0000,   // image location in flash
  parameter int          FLASH_CLKDIV = 3,             // boot sclk half period in clocks (>= 3): 33 MHz
  parameter int          WDT_RST_CYCLES = 32,          // system reset length after a watchdog expiry
  parameter bit          EXT_EN       = 1'b0,          // decode the external window (m_ext_axil_*)
  // Clock generator (CLKGEN_EN = 1): CPU clock = REF_KHZ * CPU_M / (CPU_D * CPU_O) (= CLK_HZ),
  // clk_o[n] = CPU clock * CLK_M / (CLK_D * CLK_O[16n +: 16]); see clk_gen.sv
  // Defaults: 33.333 MHz board clock -> CPU x24 / 4 = 200 MHz -> core clock x4 / 8 = 100 MHz
  parameter bit          CLKGEN_EN    = 1'b1,
  parameter longint      REF_KHZ      = 33_333,
  parameter int          CPU_M        = 24,
  parameter int          CPU_D        = 1,
  parameter int          CPU_O        = 4,
  parameter longint      CPU_VCO_MIN_KHZ = 400_000,
  parameter longint      CPU_VCO_MAX_KHZ = 1_600_000,
  parameter int          NCLK         = 1,
  parameter int          CLK_M        = 4,
  parameter int          CLK_D        = 1,
  parameter logic [16*NCLK-1:0] CLK_O = {NCLK{16'd8}},
  parameter longint      CLK_VCO_MIN_KHZ = 400_000,
  parameter longint      CLK_VCO_MAX_KHZ = 1_600_000,
  parameter logic [NCLK-1:0] CLK_EN_RST = '1,          // SYSCTL CLK_EN reset value
  parameter int          CPU_MISMATCH_PPM = 0,         // PLL oscillator errors (simulation model)
  parameter int          CLK_MISMATCH_PPM = 0
) (
  input  logic                clk,             // CPU clock, or the reference clock (CLKGEN_EN = 1)
  input  logic                rst_n,           // synchronous, or asynchronous (CLKGEN_EN = 1)
  // Clocks (CLKGEN_EN = 1: generated; else cpu_clk_o = clk, clk_o = 0)
  output logic                cpu_clk_o,
  output logic                cpu_rst_n_o,     // CPU clock domain reset (synchronous to cpu_clk_o)
  output logic [NCLK-1:0]     clk_o,
  // Run control / status
  input  logic                start_i,         // restart the program without re-booting
  input  logic                resume_i,
  input  logic [CODE_AW-1:0]  resume_pc_i,
  output logic                done_o,
  output logic [33:0]         result_o,
  output logic                trap_o,
  output logic [3:0]          trap_cause_o,
  output logic [CODE_AW-1:0]  trap_pc_o,
  output logic                boot_done_o,
  output logic                boot_err_o,
  output logic [2:0]          boot_err_code_o,
  // SPI NOR flash (program store)
  output logic                flash_sclk_o,
  output logic                flash_cs_n_o,
  output logic                flash_mosi_o,
  input  logic                flash_miso_i,
  // UART
  output logic [1:0]          uart_txd_o,
  input  logic [1:0]          uart_rxd_i,
  // I2C (open drain: o is 0, t=1 releases the line)
  input  logic [1:0]          i2c_scl_i,
  output logic [1:0]          i2c_scl_o,
  output logic [1:0]          i2c_scl_t,
  input  logic [1:0]          i2c_sda_i,
  output logic [1:0]          i2c_sda_o,
  output logic [1:0]          i2c_sda_t,
  // SPI (2 chip selects each: [1:0] SPI0, [3:2] SPI1)
  output logic [1:0]          spi_sclk_o,
  output logic [1:0]          spi_mosi_o,
  input  logic [1:0]          spi_miso_i,
  output logic [3:0]          spi_cs_n_o,
  // GPIO: [31:0] bank 0, [63:32] bank 1, [95:64] bank 2 (t=1 means input)
  input  logic [95:0]         gpio_i,
  output logic [95:0]         gpio_o,
  output logic [95:0]         gpio_t,
  // Watchdog
  output logic                wdt_reset_o,
  // Reset of the logic outside py_soc, released by the firmware (SYSCTL CORE_RESET)
  output logic                core_rst_n_o,
  // External interrupts (intc sources 12-15)
  input  logic [3:0]          ext_irq_i,
  // External AXI4-Lite master: window 0x1_0000-0x1_FFFF (EXT_EN = 1), 16-bit offset.
  // With EXT_EN = 0 the window is not decoded (DECERR) and the port is idle.
  output logic [15:0]         m_ext_axil_awaddr,
  output logic                m_ext_axil_awvalid,
  input  logic                m_ext_axil_awready,
  output logic [31:0]         m_ext_axil_wdata,
  output logic [3:0]          m_ext_axil_wstrb,
  output logic                m_ext_axil_wvalid,
  input  logic                m_ext_axil_wready,
  input  logic [1:0]          m_ext_axil_bresp,
  input  logic                m_ext_axil_bvalid,
  output logic                m_ext_axil_bready,
  output logic [15:0]         m_ext_axil_araddr,
  output logic                m_ext_axil_arvalid,
  input  logic                m_ext_axil_arready,
  input  logic [31:0]         m_ext_axil_rdata,
  input  logic [1:0]          m_ext_axil_rresp,
  input  logic                m_ext_axil_rvalid,
  output logic                m_ext_axil_rready
);
  import py_core_pkg::*;
  // The peripherals' internal FIFOs are kept minimal: py_stream_port does the buffering
  localparam int IP_FIFO = 2;

  // ---------------- clocks ----------------
  // sclk runs everything in py_soc; srst_n is the reset synchronous to it
  // CLK_HZ is the nominal CPU clock for the peripheral dividers; with the clock generator it must
  // match REF_KHZ * CPU_M / (CPU_D * CPU_O) within 100 ppm (e.g. 33.333 MHz x 6 = 200 MHz)
  localparam int SYS_HZ = CLK_HZ;
  localparam longint PLL_HZ = REF_KHZ * 1000 * CPU_M / (CPU_D * CPU_O);
  if (CLKGEN_EN && (PLL_HZ - CLK_HZ > CLK_HZ / 10_000 || CLK_HZ - PLL_HZ > CLK_HZ / 10_000)) begin : g_bad_hz
    $error(
    "py_soc: CLK_HZ %0d differs from the generated CPU clock %0d Hz",
    CLK_HZ,
    PLL_HZ
  );
  end
  logic sclk, srst_n, clk_ok, core_rel;
  logic [NCLK-1:0] clk_en;
  if (CLKGEN_EN) begin : g_clkgen
    logic cpu_locked;
    clk_gen #(
      .REF_KHZ(REF_KHZ),
      .CPU_M(CPU_M),
      .CPU_D(CPU_D),
      .CPU_O(CPU_O),
      .CPU_VCO_MIN_KHZ(CPU_VCO_MIN_KHZ),
      .CPU_VCO_MAX_KHZ(CPU_VCO_MAX_KHZ),
      .NCLK(NCLK),
      .CLK_M(CLK_M),
      .CLK_D(CLK_D),
      .CLK_O(CLK_O),
      .CLK_VCO_MIN_KHZ(CLK_VCO_MIN_KHZ),
      .CLK_VCO_MAX_KHZ(CLK_VCO_MAX_KHZ),
      .CPU_MISMATCH_PPM(CPU_MISMATCH_PPM),
      .CLK_MISMATCH_PPM(CLK_MISMATCH_PPM)
    ) u_clkgen (
      .ref_clk(clk),
      .arst_n(rst_n),
      .clk_en_i(clk_en),
      .cpu_clk_o(sclk),
      .clk_o,
      .cpu_locked_o(cpu_locked),
      .clk_locked_o(clk_ok)
    );
    assign srst_n = cpu_locked;                        // arst_n AND locked, released on sclk
    // core logic reset: CORE_RESET while the output clocks are locked, one register (glitch free)
    always_ff @(posedge sclk or negedge srst_n)
      if (!srst_n) core_rst_n_o <= 1'b0;
      else         core_rst_n_o <= core_rel & clk_ok;
  end else begin : g_no_clkgen
    assign sclk   = clk;
    assign srst_n = rst_n;
    assign clk_ok = 1'b1;
    assign clk_o  = '0;
    assign core_rst_n_o = core_rel;
  end
  assign cpu_clk_o   = sclk;
  assign cpu_rst_n_o = srst_n;

  // ---------------- reset ----------------
  // The watchdog is reset by its own expiry, so its output is only a trigger:
  // the stretch counter here holds the system in reset.
  logic sys_rst_n, wdt_rst;
  logic [$clog2(WDT_RST_CYCLES+1)-1:0] rst_cnt;
  always_ff @(posedge sclk) begin
    if (!srst_n)         rst_cnt <= '0;
    else if (wdt_rst)    rst_cnt <= WDT_RST_CYCLES;
    else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'b1;
    sys_rst_n <= srst_n && !wdt_rst && rst_cnt == 0;
  end
  assign wdt_reset_o = wdt_rst || rst_cnt != 0;

  // Processor-side bus into the interconnect (driven by the boot loader, then the core)
  logic [31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
  logic [3:0] c_wstrb;
  logic [1:0] c_bresp, c_rresp;
  logic c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready, c_arvalid, c_arready, c_rvalid, c_rready;

  // ---------------- boot loader ----------------
  logic        boot_busy, boot_done, boot_done_q;
  logic        code_we, const_we;
  logic [CODE_AW-1:0] code_waddr;
  logic [7:0] code_wdata;
  logic [CONST_AW-1:0] const_waddr;
  logic [33:0] const_wdata;
  logic [31:0] l_awaddr, l_wdata, l_araddr;
  logic [3:0] l_wstrb;
  logic        l_awvalid, l_wvalid, l_bready, l_arvalid, l_rready;

  py_boot #(
    .CODE_AW(CODE_AW),
    .CONST_AW(CONST_AW),
    .FLASH_REGS(32'h0000_C000),
    .FLASH_PORT(32'h0000_C100),
    .BOOT_ADDR(BOOT_ADDR),
    .FLASH_CLKDIV(FLASH_CLKDIV)
  ) u_boot (
    .clk(sclk),
    .rst_n(sys_rst_n),
    .busy_o(boot_busy),
    .done_o(boot_done),
    .err_o(boot_err_o),
    .err_code_o(boot_err_code_o),
    .code_we_o(code_we),
    .code_waddr_o(code_waddr),
    .code_wdata_o(code_wdata),
    .const_we_o(const_we),
    .const_waddr_o(const_waddr),
    .const_wdata_o(const_wdata),
    .m_axil_awaddr(l_awaddr),
    .m_axil_awvalid(l_awvalid),
    .m_axil_awready(c_awready),
    .m_axil_wdata(l_wdata),
    .m_axil_wstrb(l_wstrb),
    .m_axil_wvalid(l_wvalid),
    .m_axil_wready(c_wready),
    .m_axil_bresp(c_bresp),
    .m_axil_bvalid(c_bvalid),
    .m_axil_bready(l_bready),
    .m_axil_araddr(l_araddr),
    .m_axil_arvalid(l_arvalid),
    .m_axil_arready(c_arready),
    .m_axil_rdata(c_rdata),
    .m_axil_rresp(c_rresp),
    .m_axil_rvalid(c_rvalid),
    .m_axil_rready(l_rready)
  );
  assign boot_done_o = boot_done;

  // Start the core in the clock after a successful copy
  always_ff @(posedge sclk) boot_done_q <= sys_rst_n & boot_done;
  wire boot_start = boot_done & ~boot_done_q;

  // ---------------- core ----------------
  logic [CODE_AW-1:0] code_addr;
  logic [7:0] code_q;
  logic [CONST_AW-1:0] const_addr;
  logic [33:0] const_q;
  logic [31:0] p_awaddr, p_wdata, p_araddr;
  logic [3:0] p_wstrb;
  logic p_awvalid, p_wvalid, p_bready, p_arvalid, p_rready;
  logic irq;
  trap_e cause;
  assign trap_cause_o = cause;

  py_core #(
    .CODE_AW(CODE_AW),
    .CONST_AW(CONST_AW)
  ) u_core (
    .clk(sclk),
    .rst_n(sys_rst_n),
    .start_i((start_i & boot_done) | boot_start),
    .resume_i,
    .resume_pc_i,
    .busy_o(),
    .done_o,
    .result_o,
    .trap_o,
    .trap_cause_o(cause),
    .trap_pc_o,
    .trap_op_o(),
    .irq_i(irq),
    .in_irq_o(),
    .code_addr_o(code_addr),
    .code_data_i(code_q),
    .const_addr_o(const_addr),
    .const_data_i(const_q),
    .m_axil_awaddr(p_awaddr),
    .m_axil_awvalid(p_awvalid),
    .m_axil_awready(c_awready),
    .m_axil_wdata(p_wdata),
    .m_axil_wstrb(p_wstrb),
    .m_axil_wvalid(p_wvalid),
    .m_axil_wready(c_wready),
    .m_axil_bresp(c_bresp),
    .m_axil_bvalid(c_bvalid),
    .m_axil_bready(p_bready),
    .m_axil_araddr(p_araddr),
    .m_axil_arvalid(p_arvalid),
    .m_axil_arready(c_arready),
    .m_axil_rdata(c_rdata),
    .m_axil_rresp(c_rresp),
    .m_axil_rvalid(c_rvalid),
    .m_axil_rready(p_rready)
  );

  // Bus master select: the boot loader until it finishes (the core is idle meanwhile)
  wire boot_owns = !boot_done;
  assign c_awaddr  = boot_owns ? l_awaddr  : p_awaddr;
  assign c_awvalid = boot_owns ? l_awvalid : p_awvalid;
  assign c_wdata   = boot_owns ? l_wdata   : p_wdata;
  assign c_wstrb   = boot_owns ? l_wstrb   : p_wstrb;
  assign c_wvalid  = boot_owns ? l_wvalid  : p_wvalid;
  assign c_bready  = boot_owns ? l_bready  : p_bready;
  assign c_araddr  = boot_owns ? l_araddr  : p_araddr;
  assign c_arvalid = boot_owns ? l_arvalid : p_arvalid;
  assign c_rready  = boot_owns ? l_rready  : p_rready;

  // ---------------- code / constant memory (written only by the boot loader) ----------------
  logic [7:0]  code_mem  [2**CODE_AW];
  logic [33:0] const_mem [2**CONST_AW];
  always_ff @(posedge sclk) begin
    if (code_we)  code_mem[code_waddr]   <= code_wdata;
    if (const_we) const_mem[const_waddr] <= const_wdata;
    code_q  <= code_mem[code_addr];
    const_q <= const_mem[const_addr];
  end

  // ---------------- interconnect ----------------
  localparam int NS = 20 + int'(EXT_EN);
  localparam int S_INTC = 0, S_WDT = 1, S_GPIO = 2,             // GPIO 2..4
                 S_UART = 5, S_I2C = 9, S_SPI = 13,             // +2*n regs, +2*n+1 data port
                 S_FLASH = 17,                                  // 17 regs, 18 data port
                 S_SYS = 19, S_EXT = 20;
  // Slave 20 (EXT) is dropped from the decode when EXT_EN = 0 (the casts keep the low NS entries)
  localparam logic [NS*32-1:0] BASE = (NS*32)'({
    32'h0001_0000,                                                // 20     EXT
    32'h0000_0100,                                                // 19     SYSCTL
    32'h0000_C100, 32'h0000_C000,                                 // 18..17 FLASH_D FLASH
    32'h0000_B100, 32'h0000_B000, 32'h0000_A100, 32'h0000_A000,   // 16..13 SPI1_D SPI1 SPI0_D SPI0
    32'h0000_9100, 32'h0000_9000, 32'h0000_8100, 32'h0000_8000,   // 12..9  I2C
    32'h0000_7100, 32'h0000_7000, 32'h0000_6100, 32'h0000_6000,   // 8..5   UART
    32'h0000_5000, 32'h0000_4000, 32'h0000_3000,                  // 4..2   GPIO
    32'h0000_2000, 32'h0000_1000});                               // 1..0   WDT INTC
  localparam logic [NS*32-1:0] MASK = (NS*32)'({32'hFFFF_0000, {20{32'hFFFF_FF00}}});

  logic [31:0] b_awaddr, b_wdata, b_araddr;
  logic [3:0] b_wstrb;
  logic [NS-1:0] awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [NS*2-1:0] bresp, rresp;
  logic [NS*32-1:0] rdata;

  py_axil_xbar #(
    .NSLAVE(NS),
    .BASE(BASE),
    .MASK(MASK)
  ) u_xbar (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil_awaddr(c_awaddr),
    .s_axil_awvalid(c_awvalid),
    .s_axil_awready(c_awready),
    .s_axil_wdata(c_wdata),
    .s_axil_wstrb(c_wstrb),
    .s_axil_wvalid(c_wvalid),
    .s_axil_wready(c_wready),
    .s_axil_bresp(c_bresp),
    .s_axil_bvalid(c_bvalid),
    .s_axil_bready(c_bready),
    .s_axil_araddr(c_araddr),
    .s_axil_arvalid(c_arvalid),
    .s_axil_arready(c_arready),
    .s_axil_rdata(c_rdata),
    .s_axil_rresp(c_rresp),
    .s_axil_rvalid(c_rvalid),
    .s_axil_rready(c_rready),
    .m_axil_awaddr(b_awaddr),
    .m_axil_awvalid(awvalid),
    .m_axil_awready(awready),
    .m_axil_wdata(b_wdata),
    .m_axil_wstrb(b_wstrb),
    .m_axil_wvalid(wvalid),
    .m_axil_wready(wready),
    .m_axil_bresp(bresp),
    .m_axil_bvalid(bvalid),
    .m_axil_bready(bready),
    .m_axil_araddr(b_araddr),
    .m_axil_arvalid(arvalid),
    .m_axil_arready(arready),
    .m_axil_rdata(rdata),
    .m_axil_rresp(rresp),
    .m_axil_rvalid(rvalid),
    .m_axil_rready(rready)
  );

  // AXI4-Lite slave port hookup for slave index K
  `define PY_AXIL_PORT(K) \
    .s_axil_awaddr(b_awaddr[7:0]), .s_axil_awvalid(awvalid[K]), .s_axil_awready(awready[K]), \
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(wvalid[K]), .s_axil_wready(wready[K]), \
    .s_axil_bresp(bresp[(K)*2 +: 2]), .s_axil_bvalid(bvalid[K]), .s_axil_bready(bready[K]), \
    .s_axil_araddr(b_araddr[7:0]), .s_axil_arvalid(arvalid[K]), .s_axil_arready(arready[K]), \
    .s_axil_rdata(rdata[(K)*32 +: 32]), .s_axil_rresp(rresp[(K)*2 +: 2]), .s_axil_rvalid(rvalid[K]), .s_axil_rready(rready[K])

  logic [15:0] irq_src;
  assign irq_src[15:12] = ext_irq_i;

  // ---------------- external window ----------------
  if (EXT_EN) begin : g_ext
    assign m_ext_axil_awaddr = b_awaddr[15:0];
    assign m_ext_axil_awvalid = awvalid[S_EXT];
    assign awready[S_EXT] = m_ext_axil_awready;
    assign m_ext_axil_wdata  = b_wdata;
    assign m_ext_axil_wstrb   = b_wstrb;
    assign m_ext_axil_wvalid = wvalid[S_EXT];
    assign wready[S_EXT]      = m_ext_axil_wready;
    assign bresp[S_EXT*2 +: 2] = m_ext_axil_bresp;
    assign bvalid[S_EXT]  = m_ext_axil_bvalid;
    assign m_ext_axil_bready = bready[S_EXT];
    assign m_ext_axil_araddr = b_araddr[15:0];
    assign m_ext_axil_arvalid = arvalid[S_EXT];
    assign arready[S_EXT] = m_ext_axil_arready;
    assign rdata[S_EXT*32 +: 32] = m_ext_axil_rdata;
    assign rresp[S_EXT*2 +: 2] = m_ext_axil_rresp;
    assign rvalid[S_EXT] = m_ext_axil_rvalid;
    assign m_ext_axil_rready  = rready[S_EXT];
  end else begin : g_no_ext
    assign m_ext_axil_awaddr = '0;
    assign m_ext_axil_awvalid = 1'b0;
    assign m_ext_axil_wdata = '0;
    assign m_ext_axil_wstrb = '0;
    assign m_ext_axil_wvalid = 1'b0;
    assign m_ext_axil_bready = 1'b0;
    assign m_ext_axil_araddr = '0;
    assign m_ext_axil_arvalid = 1'b0;
    assign m_ext_axil_rready = 1'b0;
  end

  // ---------------- system control ----------------
  py_sysctl #(
    .NCLK(NCLK),
    .CLK_EN_RST(CLK_EN_RST),
    .CLKGEN(CLKGEN_EN)
  ) u_sys (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .por_n(srst_n),
    .wdt_reset_i(wdt_reset_o),
    .boot_done_i(boot_done),
    .boot_err_i(boot_err_o),
    .boot_err_code_i(boot_err_code_o),
    .core_rst_n_o(core_rel),
    .clk_en_o(clk_en),
    .clk_locked_i(clk_ok),
    `PY_AXIL_PORT(S_SYS));

  // ---------------- interrupt controller ----------------
  intc_top #(.NUM_IRQ(16)) u_intc (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    `PY_AXIL_PORT(S_INTC),
    .irq_i(irq_src),
    .irq_o(irq));

  // ---------------- watchdog ----------------
  watchdog_top u_wdt (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    `PY_AXIL_PORT(S_WDT),
    .irq_o(irq_src[9]),
    .wdt_reset_o(wdt_rst));

  // ---------------- GPIO x3 ----------------
  for (genvar g = 0; g < 3; g++) begin : g_gpio
    gpio_top #(.WIDTH(32)) u_gpio (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_GPIO + g),
      .gpio_i(gpio_i[g*32 +: 32]),
      .gpio_o(gpio_o[g*32 +: 32]),
      .gpio_t(gpio_t[g*32 +: 32]),
      .irq_o(irq_src[6 + g]));
  end

  // ---------------- UART x2 ----------------
  for (genvar u = 0; u < 2; u++) begin : g_uart
    logic [7:0] tx_d, rx_d;
    logic tx_v, tx_r, tx_l, rx_v, rx_r, rx_l;
    localparam int BAUD    = u == 0 ? UART0_BAUD : UART1_BAUD;
    localparam int TX_FIFO = u == 0 ? UART0_TX_FIFO : UART1_TX_FIFO;
    localparam int RX_FIFO = u == 0 ? UART0_RX_FIFO : UART1_RX_FIFO;
    uart_top #(
      .CLK_HZ(SYS_HZ),
      .BAUD(BAUD),
      .FIFO_DEPTH(IP_FIFO)
    ) u_uart (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_UART + 2*u),
      .s_axis_tdata(tx_d),
      .s_axis_tvalid(tx_v),
      .s_axis_tready(tx_r),
      .s_axis_tlast(tx_l),
      .m_axis_tdata(rx_d),
      .m_axis_tvalid(rx_v),
      .m_axis_tready(rx_r),
      .m_axis_tlast(rx_l),
      .uart_txd_o(uart_txd_o[u]),
      .uart_rxd_i(uart_rxd_i[u]));
    py_stream_port #(
      .DATA_W(8),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_UART + 2*u + 1),
      .m_axis_tdata(tx_d),
      .m_axis_tvalid(tx_v),
      .m_axis_tready(tx_r),
      .m_axis_tlast(tx_l),
      .s_axis_tdata(rx_d),
      .s_axis_tvalid(rx_v),
      .s_axis_tready(rx_r),
      .s_axis_tlast(rx_l),
      .irq_o(irq_src[0 + u]));
  end

  // ---------------- I2C x2 ----------------
  for (genvar n = 0; n < 2; n++) begin : g_i2c
    logic [7:0] tx_d, rx_d;
    logic tx_v, tx_r, tx_l, rx_v, rx_r, rx_l;
    localparam int SCL_HZ  = n == 0 ? I2C0_HZ : I2C1_HZ;
    localparam int TX_FIFO = n == 0 ? I2C0_TX_FIFO : I2C1_TX_FIFO;
    localparam int RX_FIFO = n == 0 ? I2C0_RX_FIFO : I2C1_RX_FIFO;
    i2c_top #(
      .CLK_HZ(SYS_HZ),
      .SCL_HZ(SCL_HZ),
      .FIFO_DEPTH(IP_FIFO)
    ) u_i2c (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_I2C + 2*n),
      .s_axis_tdata(tx_d),
      .s_axis_tvalid(tx_v),
      .s_axis_tready(tx_r),
      .s_axis_tlast(tx_l),
      .m_axis_tdata(rx_d),
      .m_axis_tvalid(rx_v),
      .m_axis_tready(rx_r),
      .m_axis_tlast(rx_l),
      .scl_i(i2c_scl_i[n]),
      .scl_o(i2c_scl_o[n]),
      .scl_t(i2c_scl_t[n]),
      .sda_i(i2c_sda_i[n]),
      .sda_o(i2c_sda_o[n]),
      .sda_t(i2c_sda_t[n]));
    py_stream_port #(
      .DATA_W(8),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_I2C + 2*n + 1),
      .m_axis_tdata(tx_d),
      .m_axis_tvalid(tx_v),
      .m_axis_tready(tx_r),
      .m_axis_tlast(tx_l),
      .s_axis_tdata(rx_d),
      .s_axis_tvalid(rx_v),
      .s_axis_tready(rx_r),
      .s_axis_tlast(rx_l),
      .irq_o(irq_src[2 + n]));
  end

  // ---------------- SPI x2 ----------------
  for (genvar s = 0; s < 2; s++) begin : g_spi
    localparam int SCLK_HZ = s == 0 ? SPI0_HZ : SPI1_HZ;
    localparam int DW      = s == 0 ? SPI0_DATA_W : SPI1_DATA_W;
    localparam int TX_FIFO = s == 0 ? SPI0_TX_FIFO : SPI1_TX_FIFO;
    localparam int RX_FIFO = s == 0 ? SPI0_RX_FIFO : SPI1_RX_FIFO;
    logic [DW-1:0] tx_d, rx_d;
    logic tx_v, tx_r, tx_l, rx_v, rx_r, rx_l;
    spi_top #(
      .CLK_HZ(SYS_HZ),
      .SCLK_HZ(SCLK_HZ),
      .DATA_W(DW),
      .NUM_CS(2),
      .FIFO_DEPTH(IP_FIFO)
    ) u_spi (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_SPI + 2*s),
      .s_axis_tdata(tx_d),
      .s_axis_tvalid(tx_v),
      .s_axis_tready(tx_r),
      .s_axis_tlast(tx_l),
      .m_axis_tdata(rx_d),
      .m_axis_tvalid(rx_v),
      .m_axis_tready(rx_r),
      .m_axis_tlast(rx_l),
      .spi_sclk_o(spi_sclk_o[s]),
      .spi_mosi_o(spi_mosi_o[s]),
      .spi_miso_i(spi_miso_i[s]),
      .spi_cs_n_o(spi_cs_n_o[s*2 +: 2]));
    py_stream_port #(
      .DATA_W(DW),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      `PY_AXIL_PORT(S_SPI + 2*s + 1),
      .m_axis_tdata(tx_d),
      .m_axis_tvalid(tx_v),
      .m_axis_tready(tx_r),
      .m_axis_tlast(tx_l),
      .s_axis_tdata(rx_d),
      .s_axis_tvalid(rx_v),
      .s_axis_tready(rx_r),
      .s_axis_tlast(rx_l),
      .irq_o(irq_src[4 + s]));
  end
  // ---------------- SPI NOR flash ----------------
  logic [7:0] fl_tx_d, fl_rx_d;
  logic fl_tx_v, fl_tx_r, fl_tx_l, fl_rx_v, fl_rx_r, fl_rx_l;
  spi_flash_ctrl u_flash (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    `PY_AXIL_PORT(S_FLASH),
    .s_axis_tdata(fl_tx_d),
    .s_axis_tvalid(fl_tx_v),
    .s_axis_tready(fl_tx_r),
    .m_axis_tdata(fl_rx_d),
    .m_axis_tvalid(fl_rx_v),
    .m_axis_tready(fl_rx_r),
    .m_axis_tlast(fl_rx_l),
    .sclk_o(flash_sclk_o),
    .cs_n_o(flash_cs_n_o),
    .mosi_o(flash_mosi_o),
    .miso_i(flash_miso_i),
    .irq_o(irq_src[10]));
  py_stream_port #(
    .DATA_W(8),
    .TX_DEPTH(FLASH_TX_FIFO),
    .RX_DEPTH(FLASH_RX_FIFO)
  ) u_flash_port (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    `PY_AXIL_PORT(S_FLASH + 1),
    .m_axis_tdata(fl_tx_d),
    .m_axis_tvalid(fl_tx_v),
    .m_axis_tready(fl_tx_r),
    .m_axis_tlast(fl_tx_l),
    .s_axis_tdata(fl_rx_d),
    .s_axis_tvalid(fl_rx_v),
    .s_axis_tready(fl_rx_r),
    .s_axis_tlast(fl_rx_l),
    .irq_o(irq_src[11]));
  `undef PY_AXIL_PORT
endmodule
