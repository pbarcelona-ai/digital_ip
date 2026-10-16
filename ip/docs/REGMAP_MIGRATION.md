# Register map migration (work in progress, 2026-10-11)

Goal (requested): every IP with an AXI4-Lite register set gets

- `src/include/<ip>_regs.json` -> `src/include/<ip>_regs.sv`, `<ip>_regs.xml` (IP-XACT 1685-2014) and
  `<ip>_regs.h` (C header), all in `src/include/`, `<ip>_regs.md` in `docs/`
  (ip/scripts/regmap_gen.py; build.f lists `src/include/<ip>_regs.sv`): the AXI4-Lite slave
  (axi4_lite_slave front end) holding the IP's whole register map. Map starts with the ID block:
  0x00 ID (4 ASCII chars, first in [31:24], e.g. blur_filter "BLRF"), 0x04 VERSION (ASCII "d.dd"),
  0x08 DATE (BCD mm/dd/yyyy), 0x0C reserved; the IP's old map moves up by +0x10.
  IP_VERSION / IP_DATE localparams in `<ip>_regs.sv`, bumped (+0.01) and dated by
  ip/scripts/stamp_version.py (git pre-commit hook ip/scripts/hooks/pre-commit, `--check` for CI).
- `src/<ip>.sv`: the functional logic only (no AXI). Register ports by convention:
  `cfg_<reg>` (value in), `cfg_<reg>_wr` (write pulse, only if used), `sts_<reg>` (status out),
  `sts_<reg>_set` / `sts_<reg>_clr` (W1C / W1S hardware set / clear).
- `src/<ip>_top.sv`: generated wrapper = AXI4-Lite + functional ports, instantiates `<ip>_regs`
  (u_regs) and `<ip>` (u_core). IPs whose functional module was already `*_top` (uart_top, gpio_top,
  ...) keep `*_top` as the wrapper name; the logic moves to `<ip>.sv`.
- Testbenches and designs instantiate `<ip>_top`. Testbenches: `bfm.base = 'h10` (shared axil_bfm
  has `base`, `read_abs`, `write_abs`) or `reg_base` wrappers for own AXI tasks, plus `test_id_block`.
- Designs with several register blocks: one AXI4-Lite interface per clock domain, decoded by
  address; bases and sizes in a memory map package (`<design>_map_pkg.sv`): video_processor
  (pixel domain), py_soc (CPU domain), video_pipeline (its regs + scaler); higher-level packages
  place lower-level ones. Decoders, testbenches and firmware use the packages; pyc.py imports a
  `.sv` package (`from video_processor_map_pkg import *`) so software reads the same file.

## Status

regmap_gen.py generates `<ip>_top.sv` (wrapper) from the JSON and the core's cfg_/sts_ ports
(options: core, core_file, top, top_params, regs_params, top_localparams).

Full pattern done and passing (core + src/include/<ip>_regs.* + generated <ip>_top, tb on the
top, ips.csv top updated): frame_counter, conv2d_filter, blur_filter, sharpen_filter (the three
filters share the core conv2d_filter.sv).

object_tracker, symbol_overlay, blur_sharpen, uart (2026-10-12): moved from the intermediate pattern
(core instantiating its own u_regs) to the full pattern (core with cfg_* / sts_* ports, generated
<ip>_top: object_tracker_top, symbol_overlay_top, blur_sharpen_top, uart_top); testbenches on the
tops, ips.csv tops updated; video_processor instantiates the tops (its tb probes u_core).

gpio (2026-10-12): full pattern done and passing (src/gpio.sv core, src/include/gpio_regs.*,
generated gpio_top; tb on bfm.base 0x10 with test_id_block, 6 tests). py_soc and video_processor
build.f list gpio_regs.sv / gpio.sv; firmware G_* offsets +0x10 (py_soc tb/programs/selftest.py,
video_processor sw/video_init.py).

i2c_master (2026-10-12): full pattern done and passing (src/i2c_master.sv core,
src/include/i2c_master_regs.*, ID "I2CM", generated i2c_top; tb reg_base 0x10, 7 tests).
py_soc / video_processor build.f and firmware I_* offsets updated.

spi_master (2026-10-12): full pattern done and passing (src/spi_master.sv, spi_master_regs.*, ID
"SPIM", generated spi_top; tb bfm.base 0x10, 7 tests); py_soc / video_processor build.f and
firmware S_* offsets updated.

intc (2026-10-12): full pattern done and passing (src/intc.sv, intc_regs.*, ID "INTC", generated
intc_top; tb bfm.base 0x10, 7 tests); py_soc / video_processor build.f and firmware INTC_* offsets
updated.

watchdog (2026-10-12): full pattern done and passing (src/watchdog.sv, watchdog_regs.*, ID "WDOG",
generated watchdog_top; tb bfm.base 0x10, 7 tests); py_soc / video_processor build.f and firmware
W_* offsets updated.

spi_flash_ctrl (2026-10-12): full pattern done and passing (src/spi_flash_ctrl.sv core,
spi_flash_ctrl_regs.*, ID "SPFL", generated spi_flash_ctrl_top, ips.csv top updated; old 0x18
IP_VERSION register dropped (VERSION in the ID block); tb bfm.base 0x10, 11 tests). py_soc
instantiates spi_flash_ctrl_top; py_boot F_* offsets +0x10; firmware F_* offsets updated;
py_soc make test passes (boot and run, corrupted image).

py_sysctl, py_stream_port (2026-10-12, py_soc sub-blocks in ip/cpu/py_soc/src): full pattern
(cores, src/include/py_sysctl_regs.* ID "SCTL" and py_stream_port_regs.* ID "PORT", generated
py_sysctl_top / py_stream_port_top instantiated by py_soc). The old SYSCTL ID register is SOC_ID
(0x1C). regmap_gen.py has a new access type RC (read with a side effect: <n>_rd_o pulse in the
clock the value is returned) for RXDATA (pops the RX FIFO). Firmware offsets (SYSCTL, TXDATA /
RXDATA / PSTATUS / IRQ_EN), py_boot P_RX updated; py_soc make test passes.

pwm (ID "PWMT"), baud_nco ("BNCO"), edge_event_capture ("EDGE"), quadrature_decoder (quad_dec,
"QDEC") (2026-10-12): full pattern done and passing (cores pwm.sv / baud_nco.sv /
edge_event_capture.sv / quad_dec.sv, src/include/<ip>_regs.*, generated <ip>_top; testbenches
split into test_* tasks with test_id_block, register offsets from 0x10). No other design uses them.

axis_dma ("ADMA"), dma_engine ("DMAE") (2026-10-12): full pattern done and passing (the cores keep
the IP name, generated axis_dma_top / dma_engine_top, ips.csv tops updated). reset_ctrl ("RSTC"):
core src/reset_ctrl.sv, src/include/reset_ctrl_regs.*, hand-written wrapper ip_reset_sync_top.sv
("top": false: the register map is reset by the core's synchronized bus reset); tb passes.

sdio_host ("SDIO", generated sdio_host_top, ips.csv top updated; old 0x2C IP_VERSION dropped, RESP is
an RO array of 4), pcie_tl_ep ("PCIE", core pcie_tl_ep.sv, generated pcie_tl_ep_top; its private
copy pcie_axil_regs.sv removed), usb_fs_sie ("USBF", core usb_fs_sie.sv, generated usb_fs_sie_top;
usb_axil_regs.sv removed) (2026-10-12): full pattern done and passing.

Not converted (register-bank building blocks, like axi4_lite_slave): axi4_lite_regs (generic bank
with per-register access types, no function of its own to identify) and demo_regs (its usage
example: its own "ID" register at 0x00, the testbench checks the bank).

Scaler family (2026-10-12): scaler_ctrl, the shared control block of every scaler, answers the ID
block at 0x00-0x0C (ID = the scaler's IP_ID, VERSION / DATE = parameters IP_VERSION / IP_DATE of
the scaler) and moves the rest of the 0x000-0x0FF window up by 0x10 (common map 0x10-0x3C, IP
registers from 0x050; the IP's own decoder still sees 0x040+, the bus address less 0x10);
0x100 and up (coefficient tables) unchanged. Every scaler has IP_VERSION / IP_DATE localparams
(stamp_version.py); the wrappers bicubic / lanczos / trilinear / anisotropic pass theirs to
polyphase / mip (VERSION_OVR / DATE_OVR). sharpen_cas: ID block in its own decoder, map +0x10.
scaler_tb_lib: axil_write / axil_read / axil_check add 0x10 below 0x100 of each 16 KB window
(axil_id_block, 0 in axil_split's tb), *_abs variants, check_id_block; every scaler tb checks
its ID block. Intermediate pattern: the common registers are still decoded in scaler_ctrl, not a
generated map (a generated per-scaler map would need regmap_gen support for the IP window).

video_pipeline (2026-10-12): src/include/video_pipeline_regs.* (ID "VPIP", register k of the old
map at 0x10 + 4 k, the old ID register replaced by the ID block), instantiated in video_pipeline
in place of ip_axil_regs (in-module pattern: the block also holds the scaler behind its
axil_split). tb register tasks map the old offsets; make test passes.

vision_system (2026-10-12): src/include/vision_system_regs.* (ID "VSYS", old map + 0x10, old
VERSION register 0x28 -> reserved 0x38), instantiated in axi_lite_regs.sv in place of its own AXI
code (the derived-configuration logic stays there). Testbenches (SV, ext SDRAM, cocotb) and source
lists updated.

video_processor firmware: VP_*, VS_*, scaler dump use the new maps.

video_processor (2026-10-12): build.f lists the regs of the converted IPs (uart, blur_sharpen,
frame_counter + frame_counter_top, object_tracker, symbol_overlay), instantiates frame_counter_top,
and the firmware (sw/video_regs.py, U_STATUS in sw/video_init.py) uses their +0x10 maps; the
testbench probes u_frame_cnt.u_core / u_regs. py_soc build.f lists uart_regs.sv.

Next steps, in order:
1. (done) top generation; (done) pilot frame_counter.
3. Redo the converted IPs in that pattern; then (gpio, i2c, spi, intc, watchdog, spi_flash_ctrl,
   py_sysctl, py_stream_port, edge_event_capture, quad_dec, baud_nco, pwm, axis_dma,
   dma_engine, reset_ctrl, sdio, pcie_tl_ep (pcie_axil_regs), usb_fs_sie (usb_axil_regs), scaler_ctrl + scalers, sharpen_cas, video_pipeline,
   vision_system, object_tracker, symbol_overlay, blur_sharpen, uart done; axi4_lite_regs /
   demo_regs excluded). Step 3 complete.
4. (done 2026-10-12) Map packages + decoders: ip/cpu/py_soc/src/py_soc_map_pkg.sv (py_axil_xbar
   BASE / MASK, py_boot flash addresses), ip/video/video_pipeline/src/video_pipeline_map_pkg.sv
   (axil_split ADDR_W / SPLIT_BIT, scaler offset; video_pipeline tb), image_processing/
   video_processor/src/video_processor_map_pkg.sv (imports both; pixel-domain decoder u_vbus
   windows, CPU *_BASE addresses). pyc.py reads a .sv package for "from <pkg> import *" (-I
   directories): py_soc's selftest.py and video_processor's firmware (video_init.py,
   video_regs.py) take every base address from the packages (same flash image as before).
5. (done 2026-10-12) READMEs regenerated (ip/scripts/gen_readmes.py; intros refreshed from the
   new core headers), docs pages (gen_docs.py, migrated IPs only), prompts (make_ip_prompts.py:
   for a generated <ip>_top the prompt takes the core's behaviour and the JSON register table,
   ID block included).
6. (done 2026-10-13) Firmware offsets (map packages), system testbenches (py_soc passes), full
   system run.
   video_processor quick run (2026-10-13): sections 1-7 pass with the migrated maps (every ID
   block read back in the section 5 dump, image sequence transcript in order); section 8 stalled
   on a testbench pacing race (GIF frame k sent while frame k-1's corrected frame was still
   returning, so vs_stream_adapter dropped it). Fixed: the camera now also waits for the previous
   corrected frame to be fully out of vision_system. Rerun (runJ): all 6 GIF frames tracked, two
   testbench issues left - the transcript checker matched no line (iverilog returns the array
   size for ev_txt[k].len(); fixed by copying to a local string) and frame 2 had no box (the
   compressed frame period beat the firmware's COMMIT; the camera now also waits for the firmware
   to finish the previous tracker event, tracking.py trk_frames). Rerun (runK, scripts/run_sim.sh --quick --ideal-pll --gif-frames=6):
   TEST PASSED - 34 [PASS] 0 [FAIL] in the UART 0 report, 58 transcript lines in true order,
   pedestrian tracked in all 6 frames with the dashed box on frames 2-6, gif-output written.
   The migration plan is complete.
