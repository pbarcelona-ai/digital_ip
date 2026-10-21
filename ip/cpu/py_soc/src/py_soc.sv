// ***************
// Filename: py_soc.sv
// Author: FPGA Cores 4 U
// Description: Python microcontroller. py_core plus code/constant memory,
//   a 64 KB data RAM, a flash boot loader, an AXI4-Lite interconnect and the library
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
//   Address map (src/py_soc_map_pkg.sv, read by the decoder below, the
//   testbenches and the firmware; each window 256 bytes; *_D =
//   py_stream_port data port):
//     0x0100 SYSCTL (reset cause, boot status, cycle counter, ID, CORE_RESET)
//     0x1000 INTC   0x2000 WDT    0x3000 GPIO0  0x4000 GPIO1  0x5000 GPIO2
//     0x6000 UART0  0x6100 UART0_D  0x7000 UART1  0x7100 UART1_D
//     0x8000 I2C0   0x8100 I2C0_D   0x9000 I2C1   0x9100 I2C1_D
//     0xA000 SPI0   0xA100 SPI0_D   0xB000 SPI1   0xB100 SPI1_D
//     0xC000 FLASH  0xC100 FLASH_D
//     0x1_0000-0x1_FFFF EXT (EXT_EN = 1): the m_ext_axil master port, for
//                       registers outside py_soc (address offset in the window)
//     0x4_0000-0x4_FFFF RAM: the data RAM (py_data_ram, 32-bit words, byte
//                       strobes; undefined until written, kept over a system
//                       reset)
//     0x1000_0000-0x13FF_FFFF DDR (DDR_EN = 1): the m_ddr_axil master port,
//                       a 64 MB window onto the external DDR (26-bit offset)
//   Unmapped addresses return DECERR (core trap TRAP_BUS).
//
//   Core logic reset - core_rst_n_o follows SYSCTL CORE_RESET[0] (0x0120):
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
//     16 SYSCTL timer (TIMER_CMP reached)
//   I2Cn's source is its data port's interrupt OR the controller's
//   command-done interrupt (i2c_master IRQ_EN).
//
//   Core - py_core with the parameters CODE_AW, CONST_AW, STACK_DEPTH,
//   N_LOCALS, N_FRAMES, N_GLOBALS; the defaults are the v2 system (32 KB code,
//   64-word stack, 32 locals, 32 frames, 256 globals: PyCore.v2() in the
//   model ip/cpu/py_soc/model/py_soc_model.py).
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
//   (0x0124) gates each clk_o[n] (reset value CLK_EN_RST), CLK_STATUS
//   (0x0128) bit 0 shows the output loop locked, and core_rst_n_o is only
//   released while it is (CORE_RESET AND locked, registered), so the core
//   logic reset keeps a single source. With CLKGEN_EN = 0 (default) clk is
//   the CPU clock, cpu_clk_o = clk, cpu_rst_n_o = rst_n, clk_o = 0. CLK_HZ
//   is the CPU clock frequency in both cases (checked against the clock
//   generator setting to 100 ppm). Defaults: CLKGEN_EN = 1, 33.333 MHz
//   reference, CPU 200 MHz (x24 / 4), one 100 MHz output (x4 / 8); UART
//   115200 baud, I2C 400 kHz, SPI 10 MHz, boot flash 33 MHz. For synthesis only the PLL oscillators
//   (dpll_dco) are black boxes; see clk_gen.sv.
// Date: 2026-10-20
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
  // py_core (defaults: the v2 system, PyCore.v2() in the model)
  parameter int          CODE_AW      = 15,            // code memory 2**CODE_AW bytes
  parameter int          CONST_AW     = 8,
  parameter int          STACK_DEPTH  = 64,            // py_core operand stack (shared by every call and the handler)
  parameter int          N_LOCALS     = 32,            // py_core locals per frame
  parameter int          N_FRAMES     = 32,            // py_core call depth (main program and a handler included)
  parameter int          N_GLOBALS    = 256,
  parameter logic [23:0] BOOT_ADDR    = 24'h00_0000,   // image location in flash
  parameter int          FLASH_CLKDIV = 3,             // boot sclk half period in clocks (>= 3): 33 MHz
  parameter int          WDT_RST_CYCLES = 32,          // system reset length after a watchdog expiry
  parameter bit          EXT_EN       = 1'b0,          // decode the external window (m_ext_axil)
  parameter bit          DDR_EN       = 1'b0,          // decode the DDR window (m_ddr_axil)
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
  // m_ext_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 16
  axil_if.master m_ext_axil,
  // DDR AXI4-Lite master: window 0x1000_0000-0x13FF_FFFF (DDR_EN = 1), 26-bit offset.
  // With DDR_EN = 0 the window is not decoded (DECERR) and the port is idle.
  // m_ddr_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 26
  axil_if.master m_ddr_axil
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
  if (CLKGEN_EN && (PLL_HZ - longint'(CLK_HZ) > longint'(CLK_HZ) / 10_000 ||
                  longint'(CLK_HZ) - PLL_HZ > longint'(CLK_HZ) / 10_000)) begin : g_bad_hz
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
    // srst_n clears this flop asynchronously (a lost CPU PLL must reset the core logic at once) and is
    // the synchronous reset of the rest of py_soc: both are intended (reset_sync waives the net)
    always_ff @(posedge sclk or negedge srst_n)
      if (!srst_n) core_rst_n_o <= 1'b0;
      else         core_rst_n_o <= core_rel & clk_ok;
  end else begin : g_no_clkgen
    assign sclk   = clk;
    assign srst_n = rst_n;
    assign clk_ok = 1'b1;
    assign clk_o  = '0;
    assign core_rst_n_o = core_rel;
    wire unused_clk_en = &{1'b0, clk_en, 1'b0};        // SYSCTL CLK_EN: no clock outputs to gate
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
    else if (wdt_rst)    rst_cnt <= $bits(rst_cnt)'(WDT_RST_CYCLES);
    else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'b1;
    sys_rst_n <= srst_n && !wdt_rst && rst_cnt == 0;
  end
  assign wdt_reset_o = wdt_rst || rst_cnt != 0;

  // Processor-side bus into the interconnect (driven by the boot loader, then the core)
  axil_if #(.ADDR_W(32), .DATA_W(32)) m_axil ();
  logic [31:0] c_awaddr, c_wdata, c_araddr;
  logic [3:0] c_wstrb;
  logic c_awvalid, c_wvalid, c_bready, c_arvalid, c_rready;

  // ---------------- boot loader ----------------
  logic        boot_busy, boot_done, boot_done_q;
  logic        code_we, const_we;
  logic [CODE_AW-1:0] code_waddr;
  logic [7:0] code_wdata;
  logic [CONST_AW-1:0] const_waddr;
  logic [33:0] const_wdata;

  py_boot #(
    .CODE_AW(CODE_AW),
    .CONST_AW(CONST_AW),
    .FLASH_REGS(py_soc_map_pkg::FLASH_BASE),
    .FLASH_PORT(py_soc_map_pkg::FLASH_BASE + py_soc_map_pkg::DPORT),
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
    .m_axil(m_axil)
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
  logic core_busy, core_in_irq;                        // status not brought out
  logic [7:0] core_trap_op;
  assign trap_cause_o = cause;

  axil_if #(.ADDR_W(32)) u_core_m_axil ();
  assign p_awaddr = u_core_m_axil.awaddr;
  assign p_awvalid = u_core_m_axil.awvalid;
  assign u_core_m_axil.awready = m_axil.awready;
  assign p_wdata = u_core_m_axil.wdata;
  assign p_wstrb = u_core_m_axil.wstrb;
  assign p_wvalid = u_core_m_axil.wvalid;
  assign u_core_m_axil.wready = m_axil.wready;
  assign u_core_m_axil.bresp = m_axil.bresp;
  assign u_core_m_axil.bvalid = m_axil.bvalid;
  assign p_bready = u_core_m_axil.bready;
  assign p_araddr = u_core_m_axil.araddr;
  assign p_arvalid = u_core_m_axil.arvalid;
  assign u_core_m_axil.arready = m_axil.arready;
  assign u_core_m_axil.rdata = m_axil.rdata;
  assign u_core_m_axil.rresp = m_axil.rresp;
  assign u_core_m_axil.rvalid = m_axil.rvalid;
  assign p_rready = u_core_m_axil.rready;
  py_core #(
    .CODE_AW(CODE_AW),
    .CONST_AW(CONST_AW),
    .STACK_DEPTH(STACK_DEPTH),
    .N_LOCALS(N_LOCALS),
    .N_FRAMES(N_FRAMES),
    .N_GLOBALS(N_GLOBALS)
  ) u_core (
    .clk(sclk),
    .rst_n(sys_rst_n),
    .start_i((start_i & boot_done) | boot_start),
    .resume_i,
    .resume_pc_i,
    .busy_o(core_busy),
    .done_o,
    .result_o,
    .trap_o,
    .trap_cause_o(cause),
    .trap_pc_o,
    .trap_op_o(core_trap_op),
    .irq_i(irq),
    .in_irq_o(core_in_irq),
    .code_addr_o(code_addr),
    .code_data_i(code_q),
    .const_addr_o(const_addr),
    .const_data_i(const_q),
    .m_axil(u_core_m_axil)
  );

  // Bus master select: the boot loader until it finishes (the core is idle meanwhile)
  wire boot_owns = !boot_done;
  assign c_awaddr  = boot_owns ? m_axil.awaddr  : p_awaddr;
  assign c_awvalid = boot_owns ? m_axil.awvalid : p_awvalid;
  assign c_wdata   = boot_owns ? m_axil.wdata   : p_wdata;
  assign c_wstrb   = boot_owns ? m_axil.wstrb   : p_wstrb;
  assign c_wvalid  = boot_owns ? m_axil.wvalid  : p_wvalid;
  assign c_bready  = boot_owns ? m_axil.bready  : p_bready;
  assign c_araddr  = boot_owns ? m_axil.araddr  : p_araddr;
  assign c_arvalid = boot_owns ? m_axil.arvalid : p_arvalid;
  assign c_rready  = boot_owns ? m_axil.rready  : p_rready;

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
  // Slaves 0-20 are always decoded; DDR and EXT follow when enabled (their index packs down)
  localparam int NS = 21 + int'(DDR_EN) + int'(EXT_EN);
  localparam int S_INTC = 0, S_WDT = 1, S_GPIO = 2,             // GPIO 2..4
                 S_UART = 5, S_I2C = 9, S_SPI = 13,             // +2*n regs, +2*n+1 data port
                 S_FLASH = 17,                                  // 17 regs, 18 data port
                 S_SYS = 19, S_RAM = 20,
                 S_DDR = DDR_EN ? 21 : 0,                       // (0: not used)
                 S_EXT = EXT_EN ? 21 + int'(DDR_EN) : 0;
  // bases and masks from the memory map package (py_soc_map_pkg.sv)
  localparam logic [21*32-1:0] BASE_FIXED = {
    py_soc_map_pkg::RAM_BASE,                                                         // 20  RAM
    py_soc_map_pkg::SYSCTL_BASE,                                                      // 19  SYSCTL
    py_soc_map_pkg::FLASH_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::FLASH_BASE,   // 18..17
    py_soc_map_pkg::SPI1_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::SPI1_BASE,     // 16..13
    py_soc_map_pkg::SPI0_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::SPI0_BASE,
    py_soc_map_pkg::I2C1_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::I2C1_BASE,     // 12..9
    py_soc_map_pkg::I2C0_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::I2C0_BASE,
    py_soc_map_pkg::UART1_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::UART1_BASE,   // 8..5
    py_soc_map_pkg::UART0_BASE + py_soc_map_pkg::DPORT, py_soc_map_pkg::UART0_BASE,
    py_soc_map_pkg::GPIO2_BASE, py_soc_map_pkg::GPIO1_BASE, py_soc_map_pkg::GPIO0_BASE, // 4..2
    py_soc_map_pkg::WDT_BASE, py_soc_map_pkg::INTC_BASE};                             // 1..0
  localparam logic [21*32-1:0] MASK_FIXED = {py_soc_map_pkg::RAM_MASK, {20{py_soc_map_pkg::WIN_MASK}}};
  function automatic logic [NS*32-1:0] map_vec(input logic [21*32-1:0] fixed, input logic [31:0] ddr,
                                               input logic [31:0] ext);
    logic [NS*32-1:0] v;
    v = '0;
    v[21*32-1:0] = fixed;
    if (DDR_EN) v[S_DDR*32 +: 32] = ddr;
    if (EXT_EN) v[S_EXT*32 +: 32] = ext;
    return v;
  endfunction
  localparam logic [NS*32-1:0] BASE = map_vec(BASE_FIXED, py_soc_map_pkg::DDR_BASE, py_soc_map_pkg::EXT_BASE);
  localparam logic [NS*32-1:0] MASK = map_vec(MASK_FIXED, py_soc_map_pkg::DDR_MASK, py_soc_map_pkg::EXT_MASK);

  logic [31:0] b_awaddr, b_wdata, b_araddr;
  logic [3:0] b_wstrb;
  logic [NS-1:0] awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [NS*2-1:0] bresp, rresp;
  logic [NS*32-1:0] rdata;

  axil_if #(.ADDR_W(32)) u_xbar_s_axil ();
  assign u_xbar_s_axil.awaddr = c_awaddr;
  assign u_xbar_s_axil.awvalid = c_awvalid;
  assign m_axil.awready = u_xbar_s_axil.awready;
  assign u_xbar_s_axil.wdata = c_wdata;
  assign u_xbar_s_axil.wstrb = c_wstrb;
  assign u_xbar_s_axil.wvalid = c_wvalid;
  assign m_axil.wready = u_xbar_s_axil.wready;
  assign m_axil.bresp = u_xbar_s_axil.bresp;
  assign m_axil.bvalid = u_xbar_s_axil.bvalid;
  assign u_xbar_s_axil.bready = c_bready;
  assign u_xbar_s_axil.araddr = c_araddr;
  assign u_xbar_s_axil.arvalid = c_arvalid;
  assign m_axil.arready = u_xbar_s_axil.arready;
  assign m_axil.rdata = u_xbar_s_axil.rdata;
  assign m_axil.rresp = u_xbar_s_axil.rresp;
  assign m_axil.rvalid = u_xbar_s_axil.rvalid;
  assign u_xbar_s_axil.rready = c_rready;
  py_axil_xbar #(
    .NSLAVE(NS),
    .BASE(BASE),
    .MASK(MASK)
  ) u_xbar (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_xbar_s_axil),
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

  // AXI4-Lite slave K of the crossbar as an axil_if named N (declared just before the instance that
  // takes it as .s_axil(N)): the crossbar's slave side is packed vectors (one bit / field per slave)
  `define PY_AXIL_IF(K, N) \
    axil_if #(.ADDR_W(8)) N (); \
    assign N.awaddr = b_awaddr[7:0]; assign N.awvalid = awvalid[K]; assign awready[K] = N.awready; \
    assign N.wdata = b_wdata; assign N.wstrb = b_wstrb; assign N.wvalid = wvalid[K]; assign wready[K] = N.wready; \
    assign bresp[(K)*2 +: 2] = N.bresp; assign bvalid[K] = N.bvalid; assign N.bready = bready[K]; \
    assign N.araddr = b_araddr[7:0]; assign N.arvalid = arvalid[K]; assign arready[K] = N.arready; \
    assign rdata[(K)*32 +: 32] = N.rdata; assign rresp[(K)*2 +: 2] = N.rresp; assign rvalid[K] = N.rvalid; \
    assign N.rready = rready[K];

  logic [16:0] irq_src;
  assign irq_src[15:12] = ext_irq_i;

  // ---------------- data RAM ----------------
  axil_if #(.ADDR_W(16)) u_ram_axil ();
  assign u_ram_axil.awaddr = b_awaddr[15:0];
  assign u_ram_axil.awvalid = awvalid[S_RAM];
  assign awready[S_RAM] = u_ram_axil.awready;
  assign u_ram_axil.wdata = b_wdata;
  assign u_ram_axil.wstrb = b_wstrb;
  assign u_ram_axil.wvalid = wvalid[S_RAM];
  assign wready[S_RAM] = u_ram_axil.wready;
  assign bresp[S_RAM*2 +: 2] = u_ram_axil.bresp;
  assign bvalid[S_RAM] = u_ram_axil.bvalid;
  assign u_ram_axil.bready = bready[S_RAM];
  assign u_ram_axil.araddr = b_araddr[15:0];
  assign u_ram_axil.arvalid = arvalid[S_RAM];
  assign arready[S_RAM] = u_ram_axil.arready;
  assign rdata[S_RAM*32 +: 32] = u_ram_axil.rdata;
  assign rresp[S_RAM*2 +: 2] = u_ram_axil.rresp;
  assign rvalid[S_RAM] = u_ram_axil.rvalid;
  assign u_ram_axil.rready = rready[S_RAM];
  py_data_ram #(.BYTES(65536)) u_ram (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_ram_axil));

  // ---------------- DDR window ----------------
  if (DDR_EN) begin : g_ddr
    assign m_ddr_axil.awaddr = b_awaddr[25:0];
    assign m_ddr_axil.awvalid = awvalid[S_DDR];
    assign awready[S_DDR] = m_ddr_axil.awready;
    assign m_ddr_axil.wdata  = b_wdata;
    assign m_ddr_axil.wstrb   = b_wstrb;
    assign m_ddr_axil.wvalid = wvalid[S_DDR];
    assign wready[S_DDR]      = m_ddr_axil.wready;
    assign bresp[S_DDR*2 +: 2] = m_ddr_axil.bresp;
    assign bvalid[S_DDR]  = m_ddr_axil.bvalid;
    assign m_ddr_axil.bready = bready[S_DDR];
    assign m_ddr_axil.araddr = b_araddr[25:0];
    assign m_ddr_axil.arvalid = arvalid[S_DDR];
    assign arready[S_DDR] = m_ddr_axil.arready;
    assign rdata[S_DDR*32 +: 32] = m_ddr_axil.rdata;
    assign rresp[S_DDR*2 +: 2] = m_ddr_axil.rresp;
    assign rvalid[S_DDR] = m_ddr_axil.rvalid;
    assign m_ddr_axil.rready  = rready[S_DDR];
  end else begin : g_no_ddr
    assign m_ddr_axil.awaddr = '0;
    assign m_ddr_axil.awvalid = 1'b0;
    assign m_ddr_axil.wdata = '0;
    assign m_ddr_axil.wstrb = '0;
    assign m_ddr_axil.wvalid = 1'b0;
    assign m_ddr_axil.bready = 1'b0;
    assign m_ddr_axil.araddr = '0;
    assign m_ddr_axil.arvalid = 1'b0;
    assign m_ddr_axil.rready = 1'b0;
    wire unused_ddr = &{1'b0, m_ddr_axil.awready, m_ddr_axil.wready, m_ddr_axil.bresp, m_ddr_axil.bvalid,
                        m_ddr_axil.arready, m_ddr_axil.rdata, m_ddr_axil.rresp, m_ddr_axil.rvalid, 1'b0};
  end

  // ---------------- external window ----------------
  if (EXT_EN) begin : g_ext
    assign m_ext_axil.awaddr = b_awaddr[15:0];
    assign m_ext_axil.awvalid = awvalid[S_EXT];
    assign awready[S_EXT] = m_ext_axil.awready;
    assign m_ext_axil.wdata  = b_wdata;
    assign m_ext_axil.wstrb   = b_wstrb;
    assign m_ext_axil.wvalid = wvalid[S_EXT];
    assign wready[S_EXT]      = m_ext_axil.wready;
    assign bresp[S_EXT*2 +: 2] = m_ext_axil.bresp;
    assign bvalid[S_EXT]  = m_ext_axil.bvalid;
    assign m_ext_axil.bready = bready[S_EXT];
    assign m_ext_axil.araddr = b_araddr[15:0];
    assign m_ext_axil.arvalid = arvalid[S_EXT];
    assign arready[S_EXT] = m_ext_axil.arready;
    assign rdata[S_EXT*32 +: 32] = m_ext_axil.rdata;
    assign rresp[S_EXT*2 +: 2] = m_ext_axil.rresp;
    assign rvalid[S_EXT] = m_ext_axil.rvalid;
    assign m_ext_axil.rready  = rready[S_EXT];
  end else begin : g_no_ext
    assign m_ext_axil.awaddr = '0;
    assign m_ext_axil.awvalid = 1'b0;
    assign m_ext_axil.wdata = '0;
    assign m_ext_axil.wstrb = '0;
    assign m_ext_axil.wvalid = 1'b0;
    assign m_ext_axil.bready = 1'b0;
    assign m_ext_axil.araddr = '0;
    assign m_ext_axil.arvalid = 1'b0;
    assign m_ext_axil.rready = 1'b0;
    wire unused_ext = &{1'b0, m_ext_axil.awready, m_ext_axil.wready, m_ext_axil.bresp, m_ext_axil.bvalid,
                        m_ext_axil.arready, m_ext_axil.rdata, m_ext_axil.rresp, m_ext_axil.rvalid, 1'b0};
  end

  // ---------------- system control ----------------
  `PY_AXIL_IF(S_SYS, u_sys_axil)
  py_sysctl_top #(
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
    .timer_irq_o(irq_src[16]),
    .s_axil(u_sys_axil));

  // ---------------- interrupt controller ----------------
  `PY_AXIL_IF(S_INTC, u_intc_axil)
  intc_top #(.NUM_IRQ(17)) u_intc (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_intc_axil),
    .irq_i(irq_src),
    .irq_o(irq));

  // ---------------- watchdog ----------------
  `PY_AXIL_IF(S_WDT, u_wdt_axil)
  watchdog_top u_wdt (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_wdt_axil),
    .irq_o(irq_src[9]),
    .wdt_reset_o(wdt_rst));

  // ---------------- GPIO x3 ----------------
  for (genvar g = 0; g < 3; g++) begin : g_gpio
    `PY_AXIL_IF(S_GPIO + g, u_gpio_axil)
    gpio_top #(.WIDTH(32)) u_gpio (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_gpio_axil),
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
    `PY_AXIL_IF(S_UART + 2*u, u_uart_axil)
    axis_if #(.DATA_W(8)) u_uart_s_axis ();
    assign u_uart_s_axis.tdata = tx_d;
    assign u_uart_s_axis.tvalid = tx_v;
    assign tx_r = u_uart_s_axis.tready;
    assign u_uart_s_axis.tlast = tx_l;
    assign u_uart_s_axis.tuser = '0;                  // not used (the TX FIFO stores it)
    axis_if #(.DATA_W(8)) u_uart_m_axis ();
    assign rx_d = u_uart_m_axis.tdata;
    assign rx_v = u_uart_m_axis.tvalid;
    assign u_uart_m_axis.tready = rx_r;
    assign rx_l = u_uart_m_axis.tlast;
    uart_if u_uart_uart ();
    assign uart_txd_o[u] = u_uart_uart.txd;
    assign u_uart_uart.rxd = uart_rxd_i[u];
    uart_top #(
      .CLK_HZ(SYS_HZ),
      .BAUD(BAUD),
      .FIFO_DEPTH(IP_FIFO)
    ) u_uart (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_uart_axil),
      .s_axis(u_uart_s_axis),
      .m_axis(u_uart_m_axis),
      .uart(u_uart_uart)
      );
    `PY_AXIL_IF(S_UART + 2*u + 1, u_port_axil)
    axis_if #(.DATA_W(8)) u_port_m_axis ();
    assign tx_d = u_port_m_axis.tdata;
    assign tx_v = u_port_m_axis.tvalid;
    assign u_port_m_axis.tready = tx_r;
    assign tx_l = u_port_m_axis.tlast;
    axis_if #(.DATA_W(8)) u_port_s_axis ();
    assign u_port_s_axis.tdata = rx_d;
    assign u_port_s_axis.tvalid = rx_v;
    assign rx_r = u_port_s_axis.tready;
    assign u_port_s_axis.tlast = rx_l;
    assign u_port_s_axis.tuser = '0;                  // not used by the data port
    py_stream_port_top #(
      .DATA_W(8),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_port_axil),
      .m_axis(u_port_m_axis),
      .s_axis(u_port_s_axis),
      .irq_o(irq_src[0 + u])
      );
  end

  // ---------------- I2C x2 ----------------
  for (genvar n = 0; n < 2; n++) begin : g_i2c
    logic [7:0] tx_d, rx_d;
    logic tx_v, tx_r, tx_l, rx_v, rx_r, rx_l;
    localparam int SCL_HZ  = n == 0 ? I2C0_HZ : I2C1_HZ;
    localparam int TX_FIFO = n == 0 ? I2C0_TX_FIFO : I2C1_TX_FIFO;
    localparam int RX_FIFO = n == 0 ? I2C0_RX_FIFO : I2C1_RX_FIFO;
    `PY_AXIL_IF(S_I2C + 2*n, u_i2c_axil)
    axis_if #(.DATA_W(8)) u_i2c_s_axis ();
    assign u_i2c_s_axis.tdata = tx_d;
    assign u_i2c_s_axis.tvalid = tx_v;
    assign tx_r = u_i2c_s_axis.tready;
    assign u_i2c_s_axis.tlast = tx_l;
    assign u_i2c_s_axis.tuser = '0;                  // not used (the TX FIFO stores it)
    axis_if #(.DATA_W(8)) u_i2c_m_axis ();
    assign rx_d = u_i2c_m_axis.tdata;
    assign rx_v = u_i2c_m_axis.tvalid;
    assign u_i2c_m_axis.tready = rx_r;
    assign rx_l = u_i2c_m_axis.tlast;
    logic i2c_irq, port_irq;
    assign irq_src[2 + n] = port_irq | i2c_irq;          // the data port's or the command-done interrupt
    i2c_if u_i2c_i2c ();
    assign u_i2c_i2c.scl_i = i2c_scl_i[n];
    assign i2c_scl_o[n] = u_i2c_i2c.scl_o;
    assign i2c_scl_t[n] = u_i2c_i2c.scl_t;
    assign u_i2c_i2c.sda_i = i2c_sda_i[n];
    assign i2c_sda_o[n] = u_i2c_i2c.sda_o;
    assign i2c_sda_t[n] = u_i2c_i2c.sda_t;
    i2c_top #(
      .CLK_HZ(SYS_HZ),
      .SCL_HZ(SCL_HZ),
      .FIFO_DEPTH(IP_FIFO)
    ) u_i2c (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_i2c_axil),
      .s_axis(u_i2c_s_axis),
      .m_axis(u_i2c_m_axis),
      .i2c(u_i2c_i2c),
      .irq_o(i2c_irq)
      );
    `PY_AXIL_IF(S_I2C + 2*n + 1, u_port_axil)
    axis_if #(.DATA_W(8)) u_port_m_axis ();
    assign tx_d = u_port_m_axis.tdata;
    assign tx_v = u_port_m_axis.tvalid;
    assign u_port_m_axis.tready = tx_r;
    assign tx_l = u_port_m_axis.tlast;
    axis_if #(.DATA_W(8)) u_port_s_axis ();
    assign u_port_s_axis.tdata = rx_d;
    assign u_port_s_axis.tvalid = rx_v;
    assign rx_r = u_port_s_axis.tready;
    assign u_port_s_axis.tlast = rx_l;
    assign u_port_s_axis.tuser = '0;                  // not used by the data port
    py_stream_port_top #(
      .DATA_W(8),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_port_axil),
      .m_axis(u_port_m_axis),
      .s_axis(u_port_s_axis),
      .irq_o(port_irq)
      );
  end

  // ---------------- SPI x2 ----------------
  for (genvar s = 0; s < 2; s++) begin : g_spi
    localparam int SCLK_HZ = s == 0 ? SPI0_HZ : SPI1_HZ;
    localparam int DW      = s == 0 ? SPI0_DATA_W : SPI1_DATA_W;
    localparam int TX_FIFO = s == 0 ? SPI0_TX_FIFO : SPI1_TX_FIFO;
    localparam int RX_FIFO = s == 0 ? SPI0_RX_FIFO : SPI1_RX_FIFO;
    logic [DW-1:0] tx_d, rx_d;
    logic tx_v, tx_r, tx_l, rx_v, rx_r, rx_l;
    `PY_AXIL_IF(S_SPI + 2*s, u_spi_axil)
    axis_if #(.DATA_W(DW)) u_spi_s_axis ();
    assign u_spi_s_axis.tdata = tx_d;
    assign u_spi_s_axis.tvalid = tx_v;
    assign tx_r = u_spi_s_axis.tready;
    assign u_spi_s_axis.tlast = tx_l;
    assign u_spi_s_axis.tuser = '0;                  // not used (the TX FIFO stores it)
    axis_if #(.DATA_W(DW)) u_spi_m_axis ();
    assign rx_d = u_spi_m_axis.tdata;
    assign rx_v = u_spi_m_axis.tvalid;
    assign u_spi_m_axis.tready = rx_r;
    assign rx_l = u_spi_m_axis.tlast;
    spi_if #(.NUM_CS(2)) u_spi_spi ();
    assign spi_sclk_o[s] = u_spi_spi.sclk;
    assign spi_mosi_o[s] = u_spi_spi.mosi;
    assign u_spi_spi.miso = spi_miso_i[s];
    assign spi_cs_n_o[s*2 +: 2] = u_spi_spi.cs_n;
    spi_top #(
      .CLK_HZ(SYS_HZ),
      .SCLK_HZ(SCLK_HZ),
      .DATA_W(DW),
      .NUM_CS(2),
      .FIFO_DEPTH(IP_FIFO)
    ) u_spi (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_spi_axil),
      .s_axis(u_spi_s_axis),
      .m_axis(u_spi_m_axis),
      .spi(u_spi_spi)
      );
    `PY_AXIL_IF(S_SPI + 2*s + 1, u_port_axil)
    axis_if #(.DATA_W(DW)) u_port_m_axis ();
    assign tx_d = u_port_m_axis.tdata;
    assign tx_v = u_port_m_axis.tvalid;
    assign u_port_m_axis.tready = tx_r;
    assign tx_l = u_port_m_axis.tlast;
    axis_if #(.DATA_W(DW)) u_port_s_axis ();
    assign u_port_s_axis.tdata = rx_d;
    assign u_port_s_axis.tvalid = rx_v;
    assign rx_r = u_port_s_axis.tready;
    assign u_port_s_axis.tlast = rx_l;
    assign u_port_s_axis.tuser = '0;                  // not used by the data port
    py_stream_port_top #(
      .DATA_W(DW),
      .TX_DEPTH(TX_FIFO),
      .RX_DEPTH(RX_FIFO)
    ) u_port (
      .aclk(sclk),
      .aresetn(sys_rst_n),
      .s_axil(u_port_axil),
      .m_axis(u_port_m_axis),
      .s_axis(u_port_s_axis),
      .irq_o(irq_src[4 + s])
      );
  end
  // ---------------- SPI NOR flash ----------------
  axis_if #(.DATA_W(8)) fl_rx ();
  axis_if #(.DATA_W(8)) fl_tx ();
  logic fl_tx_l;
  `PY_AXIL_IF(S_FLASH, u_flash_axil)
  spi_if #(.NUM_CS(1)) u_flash_spi ();
  assign flash_sclk_o = u_flash_spi.sclk;
  assign flash_cs_n_o = u_flash_spi.cs_n;
  assign flash_mosi_o = u_flash_spi.mosi;
  assign u_flash_spi.miso = flash_miso_i;
  spi_flash_ctrl_top u_flash (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_flash_axil),
    .s_axis(fl_tx),
    .m_axis(fl_rx),
    .spi(u_flash_spi),
    .irq_o(irq_src[10])
    );
  `PY_AXIL_IF(S_FLASH + 1, u_flash_port_axil)
  axis_if #(.DATA_W(8)) u_flash_port_m_axis ();
  assign fl_tx.tdata = u_flash_port_m_axis.tdata;
  assign fl_tx.tvalid = u_flash_port_m_axis.tvalid;
  assign u_flash_port_m_axis.tready = fl_tx.tready;
  assign fl_tx_l = u_flash_port_m_axis.tlast;
  assign fl_tx.tlast = fl_tx_l;                       // not used: the controller counts LEN bytes
  assign fl_tx.tuser = '0;
  py_stream_port_top #(
    .DATA_W(8),
    .TX_DEPTH(FLASH_TX_FIFO),
    .RX_DEPTH(FLASH_RX_FIFO)
  ) u_flash_port (
    .aclk(sclk),
    .aresetn(sys_rst_n),
    .s_axil(u_flash_port_axil),
    .m_axis(u_flash_port_m_axis),
    .s_axis(fl_rx),
    .irq_o(irq_src[11])
    );
  `undef PY_AXIL_IF

  // not used: core status, the boot loader's busy, the flash write stream's tlast (the controller counts
  // LEN bytes), the address bits above the widest window (b_*addr[15:0] slaves, [25:16] DDR window)
  wire unused_ok = &{1'b0, core_busy, core_in_irq, core_trap_op, boot_busy, fl_tx_l,
                     b_awaddr[31:16], b_araddr[31:16], 1'b0};
endmodule
