# video_processor: SV changes pending from the Python baseline

The design is being baselined on the Python models first (`make pysim`, `pysim/`; each IP's model is in its
`model/` folder next to `src/`, e.g. `ip/ai/npu/model/npu_model.py`, found through `scripts/build.f`); the SystemVerilog is
updated only when the Python behaviour is accepted. Every hardware change the Python models already
implement, and the RTL does not yet, is listed here. Register maps (`src/include/*_regs.json`) are the
specification: where a JSON already describes the change, `regmap_gen.py` regenerates the register block
and only the logic behind it needs writing.

| # | Block (RTL) | Change | Spec / model | Why |
|---|-------------|--------|--------------|-----|
| 1 | `ip/cpu/py_core` (`py_core_pkg.sv`, `py_core.sv`) | **Done 2026-10-20 (py_core 2.0.0, tb/python against the model).** New opcode `WAIT_IRQ` = 0x3E: the core stops until `irq_i` is high, whether interrupts are enabled or not; an interrupt pending at the boundary after `IRQ_ENABLE` must be taken before the next instruction. `pyc.py` builtin `wait_irq()`. | `py_core_model.py`, `ip/cpu/py_core/tools/pyc.py` | Firmware waits on interrupts instead of polling |
| 2 | `ip/cpu/py_soc` (`py_sysctl.sv`) | **py_sysctl done 2026-10-20 (TIMER_STATUS a CMD register, tb/python against the model; the intc source 16 wiring follows with py_soc).** Timer compare: `TIMER_CMP` (0x2C, RW), `TIMER_CTRL` (0x30, [0] IRQ_EN), `TIMER_STATUS` (0x34, W1C [0] REACHED, set when `CYCLES - TIMER_CMP < 2**31`, cleared by a `TIMER_CMP` write); `timer_irq_o`. | `py_sysctl_regs.json`, `py_sysctl_model.py` | Timeouts and timed waits sleep on it |
| 3 | `ip/cpu/py_soc` (`py_soc.sv`) | `irq_src` widened to 17 (intc `NUM_IRQ` 17): source 16 = SYSCTL timer. | `py_soc_model.py` Soc.irq_src | Room for the timer |
| 4 | `ip/peripherals/i2c_master` | **i2c_master done 2026-10-20 (irq_o, tb/python against the model; the py_soc OR follows with py_soc); DIV reset meets UM10204 tLOW.** `IRQ_EN` (0x24, [0] DONE) and `irq_o` = DONE & IRQ_EN; in `py_soc.sv` OR'ed with the I2C data port's `irq_o` onto `irq_src[2 + n]`. | `i2c_master_regs.json`, `i2c_master_model.py` | Transfer completion as an interrupt |
| 5 | `src/video_processor.sv` | intc source 15 = OR of frame_counter `irq_o[4:2]` (vision_system in / out, tracker), through a `bit_sync` like sources 13 / 14 (today 15 is the spare `ext_irq_i`). | `model/video_processor_model.py` irq_lines | The event report sleeps until a frame event |
| 6 | `src/video_processor.sv`, `video_processor_map_pkg.sv` | `NTRK` 4 -> 5 object_tracker detectors (aircraft added). | `sw/video_regs.py` NDET, `model/video_processor_model.py` NTRK | Air transportation class |
| 7 | `ip/video/symbol_overlay` | Object style bits `TICKS` [6], `TRIANGLE` [7], `CORNERS` [15]; `OBJ_LABEL` (0x260 + 4 i, 4 ASCII characters under the symbol on a darkened backdrop); `CTRL.LABEL_SCALE` [2:1]; lowercase glyphs in `overlay_font_pkg.sv` (regenerate with `scripts/make_font.py`). `NOBJ` 16. | `symbol_overlay_regs.json`, `symbol_overlay_model.py` SymbolOverlay | Tracking symbols and p / g / a labels |
| 8 | `ip/video/feature_detect` | **Done 2026-10-21 (feature_detect 2.0.0, tb/python against the model).** Sky profile: `SKY_CFG` (0x44: [3:0] SHIFT column groups of 2**SHIFT pixels, [15:8] Y_MIN), `SKY[0..31]` (0x80, RO): per column group, the lines from the top down to the first pixel that has an edge or luma below Y_MIN (one counter and a "still sky" bit per group). | `feature_detect_regs.json`, `feature_detect_model.py` | Aircraft: the first object below open sky |
| 9 | `ip/video/object_tracker` | **Done 2026-10-21 (object_tracker 2.0.0, tb/python against the model).** `CTRL.SKIN_LUT` [15] and `SKIN_LUT[0..31]` (0x160): in colour mode the chroma test is a 32 x 32 bit table (Cb 96..159, Cr 112..175 in 2 x 2 cells) instead of the Cb / Cr ranges; Y_RANGE still applies. | `object_tracker_regs.json`, `object_tracker_model.py` | Faces: the learned skin table (`python-prototype/train_skin.py`) |
| 10 | `src/video_processor.sv`, `video_processor_map_pkg.sv` | Two paths after vision_system: display = a second blur_sharpen (`FLT_DISP`, window 0x1_8600) -> symbol_overlay -> output; analysis = blur_sharpen (0x1_8200) -> feature_detect, object_trackers only. | `model/video_processor_model.py` process, `sw/video_regs.py` FLT_DISP | Picture quality and detection filtering chosen independently |
| 11 | `src/video_processor.sv` (`CPU_CODE_AW`) | py_core code memory 14 -> 15 (32 KB): the firmware with the detection is over 16 KB once the reports grow. | `pysim/sim.py` (`--code-aw 15`), `py_core_model.py` | Room for the firmware |
| 12 | `ip/ai/npu` (new IP) | INT8 NPU: frame writer (RGB888 to DDR), command processor (64-byte layer descriptors from DDR), 32 x 32 MAC array (INT32 accumulation, per-channel requantisation, activation LUT), MAXPOOL / ADD / UPSAMPLE / COPY / INPUT (letterbox) / DECODE (detection list) operations, DMA to DDR; registers `npu_regs.json` (window 0x1_A000). The arithmetic is defined bit-exactly by `npu_model.py`; programs come from `ip/ai/npu/scripts/npu_compiler.py` (YOLOv8n: 79 descriptors, 1.09 GMAC, about 1.43 M clocks per frame). | `npu_regs.json`, `npu_model.py`, `model/video_processor_model.py` | Learned detection of 80 object classes |
| 13 | `src/video_processor.sv` | A DDR memory (controller + AXI interconnect) shared by the NPU (master) and the CPU (a window at 0x1000_0000); the NPU's frame writer takes the vision_system output; frame_counter channel 4 marks the NPU's run done when the NPU is on. | `model/video_processor_model.py`, `py_soc_model.py` (DDR window), `pysim/sim.py` (timing) | Frame buffer, program, tensors, detections |
| 14 | `ip/cpu/py_core` (py_core v2) | **Done 2026-10-20 (py_core 2.0.0; the v2 sizes are parameters, set by py_soc).** `BINARY_MUL` 0x17, `BINARY_FLOORDIV` 0x1E, `BINARY_MOD` 0x1F (Python semantics, trap 9 on a zero divisor), 256 globals, 32 locals and frames, a 64-word operand stack; pyc.py `--core 2`. | `py_core_model.py` (`PyCore.v2`), `ip/cpu/py_core/tools/pyc.py` | Tracking arithmetic (Kalman, IoU, NMS) |
| 15 | `ip/cpu/py_soc` | 64 KB data RAM at 0x4_0000 (the firmware's arrays: tracks, detections, IoU table) and the DDR window at 0x1000_0000 on the CPU's bus. | `py_soc_model.py` | Firmware data beyond 256 globals |
| 16 | `ip/video/symbol_overlay` | `NOBJ` up to 32: a second object bank (`OBJ2_CTRL / X / Y / COLOR` at 0x2A0 + 16 i, `OBJ2_LABEL` at 0x3A0 + 4 i) for objects 16-31, in the free space of the 1 KB window. | `symbol_overlay_regs.json`, `symbol_overlay_model.py` (obj_key) | 32 tracked targets |
| 17 | `ip/ai/npu`, `src/video_processor.sv` | NPU at a 960 x 960 input (9.84 GMAC per frame): a 64 x 64 MAC array (4096 per clock, about 2.4 M clocks per frame); DDR 128 MB; camera frames up to 960 x 720 through the pipeline (line buffers, frame buffer, overlay) instead of 320 x 240. | `npu_model.py` (PE), `model/video_processor_model.py` (DDR_BYTES), `pysim/run_pysim.py` (--fit, --n) | Distant objects: twice the detections at 640, more at 960 |
| 18 | `ip/ai/npu`, `src/video_processor.sv` | Native resolution: camera frames up to 1920 x 1080 (1080 x 1920 portrait); a rectangular NPU input (INPUT word 7: height << 16 \| width; the frame size rounded up to multiples of 32, e.g. 1920 x 1088: 19.2 GMAC, about 4.7 M clocks per frame on the 64 x 64 array); DDR 256 MB; the program header gives the input width and height. | `npu_model.py`, `ip/ai/npu/scripts/npu_compiler.py` (shape_for, calibrate), `sw/bytetrack.py` (npu_setup) | Inputs at their native resolution |
| 19 | `ip/ai/npu` | INPUT scales bilinearly (8-bit weights, centres aligned, as `scaler_bilinear`; `npu.bilinear()`); DECODE writes candidates to a buffer (`CAND_MAX` 2048); a new NMS operation (8): same-class IoU 0.45, cross-class 0.7, the survivors ordered by box area (foreground first), the first `DET_MAX` to the detection list (a sort unit and an IoU comparator). | `npu_model.py` (_op6, _op7, _op8), `ip/ai/npu/scripts/npu_compiler.py` | Foreground priority, no duplicates across classes, better small-image scaling |
| 20 | `ip/ai/npu`, `ip/video/symbol_overlay` | NMS containment test (word 15: a same-class box covering 80 % of the smaller one is suppressed); the overlay's TICKS 2 x LINE_W long (the firmware scales symbols, lines, dashes, labels and texts with the frame size); the detector is YOLOv8s (73 GMAC per frame at 1920 x 1088: about 18 M clocks on the 64 x 64 array; weights 11 MB). | `npu_model.py`, `model/video_processor_model.py`, `sw/overlay.py` (symbol_scale) | Larger, better detector; readable symbols at every resolution |
| 21 | `ip/ai/npu` | A second letterbox register bank `LB2_STEP / LB2_OFFSET / LB2_SIZE / LB2_INV` (0x58-0x64) and descriptor flag `BANK2` (word 0 bit 8) selecting it in INPUT and DECODE; DECODE keeps appending to the candidate buffer across both passes of a program, one NMS at the end. Programs for inputs over 960 wide run the network twice: native, then at about 640 (1920 x 1088 + 640 x 384: 81.5 GMAC, +12 %); weights shared. | `npu_regs.json`, `npu_model.py` (FLAG_BANK2, geom2), `ip/ai/npu/scripts/npu_compiler.py` (shape2_for, emit) | A detector trained at 640 splits an object filling a 1920-wide frame into part boxes (duplicates); the low-resolution pass sees it whole |
| 22 | `ip/video/symbol_overlay` | Smooth text: `CTRL.FONT` [3] (`symbol_overlay_regs.json` 1.11): labels and texts at 2x / 4x / 8x from anti-aliased font ROMs (`src/include/overlay_font_aa_s{2,4,8}.mem`, 4-bit coverage, 95 glyphs of 8 x 12, 16 x 24, 32 x 48: about 96 KB in all) blended with the video, out = (video x (15 - a) + colour x a) / 15 (a multiply-add per channel; the divide by 15 exactly as (x + 7) x 4370 >> 16 for every x in range); 1x keeps the 3 x 5 font; TXT_CTRL.SCALE 3 (8x) documented. Regenerate the ROMs with `scripts/make_aa_font.py`. | `symbol_overlay_regs.json`, `symbol_overlay_model.py` (draw_text) | Labels and texts readable instead of enlarged 3 x 5 blocks |

Firmware-side changes (no RTL): every polling loop replaced by interrupt waits (`sw/video_init.py`
`wait_bit`, `pause`, `sleep_until`), the vision_system reciprocal wait removed (its FSM already holds the
frame), constant-size symbols, labels, tracks confirmed after 3 frames, foreground-only sizes, the
largest blobs first, the aircraft tracked first with its sky test, people from the motion bit, faces from
the skin table and drawn instead of the person's body; with the NPU (sw/bytetrack.py): the NPU driver,
NMS, a ByteTrack-type tracker (steady-state Kalman, two-stage association), groups P / G / A / O, duplicate
tracks of one object merged, labels up to 32 per group, the tracking end test longer than an NPU frame.

Library fixes found by the model comparisons (2026-10-20): `ip/scripts/regmap_gen.py` reads stored registers
back at their declared width (bits above read 0) and names the unused address bits; each register block is
regenerated when its IP is updated (`regmap_gen.py --check` lists the blocks still generated by the old
version). `ip/shared/pymodel/regs.py` follows the generated RTL: DECERR at and above MAP_WORDS, VERSION / DATE
from the block's stamps. intc 1.1.0: one latency for edge and level sources (2 clocks to PENDING, 3 to
VECTOR / irq_o).


py_soc integration DONE (2026-10-20): intc 17 sources (16 = SYSCTL timer), I2C source = data port OR done
interrupt, py_core v2 defaults, 64 KB data RAM at 0x4_0000 (py_data_ram), DDR window at 0x1000_0000
(m_ddr_axil, DDR_EN). Found by Yosys: uart.sv's pin port renamed `pins` (sv2v dropped the TX driver), the
stream links' tuser driven. Models: py_axil_xbar_model (decode and access timing), py_boot_model, clock-exact
intc_model, exact interrupt inputs in py_soc_model. cocotb tb/python/py_soc_tb.py compares py_soc clock for
clock from the boot (selftest, bus). Open for the design top: video_processor.sv still uses pre-refactor
port names (2 errors) and CODE_AW 14 / DDR_EN 0.

symbol_overlay 2.0 DONE (2026-10-21): the model is the exact definition (see its header) and the RTL matches it
frame for frame (tb/python): 32 objects in two banks, rectangle dashes / corners / ticks, filled, crosshair, exact
integer ellipse rings (circle and oval), integer triangles, labels, texts with the 5-digit frame number, 3 x 5 and
smooth fonts (FONT_DIR: the design must pass the ROM directory), layers of lowest index. The register map's bank-1
and text arrays no longer overlap. Open: track_ref.sv (old drawing rules) in the object_tracker and video_processor
testbenches.

feature_detect 2.0 DONE (2026-10-21): the model is the exact definition (configuration at the frame start,
RESTART / FRAME_SIZE writes at the next frame start, AUTO_SHIFT uses the search that ended two frames before, the
sky profile) and the RTL matches it pixel for pixel (tb/python, 4 x 4 and 8 x 8 cells): a pipelined tap (m_axis
2 clocks later with feat_o), registered (block RAM) reads, counted cell addresses. Found by Yosys: the two
background banks were LUT RAM (one read register for both); now 220 RAMB36 at 2048 x 1152 with 4 x 4 cells.
Open for the design top: FEAT_CELL_LOG2 (8 x 8 cells need about a quarter of that), the trackers on
feature_detect's m_axis / feat_o, feature_ref.sv (old semantics) in the video_processor testbench.

object_tracker 2.0 DONE (2026-10-21): SKIN_LUT, empty blob slots read 0, and a 4-stage pipeline (the per-pixel
chain was one clock: luma -> test -> runs -> clip -> products -> blobs); results unchanged, done_o 4 clocks after
the frame's last pixel; frame exact against the model (tb/python, back-to-back frames included). About 22k LUTs
per detector at NBLOB 8 (5 detectors in the design).

isp_window, conv2d_core, blur_sharpen DONE (2026-10-21): isp_window and conv2d_core have beat-exact models
(model/isp_window_model.py, Conv2dCore in conv2d_core_model.py; drops, restarts, both BORDER rules) and
tb/python comparisons; blur_sharpen's model takes the RTL parameters and STATUS's mode of the last frame that
entered; its register block was regenerated (coefficients read back as COEF_W bits). Rules documented in the
headers: conv2d_core's coef_i held from a frame's start until frame_o; blur_sharpen frames of at least 14
pixels. 150 DSP48 per blur_sharpen at N 5 (two in the design).


frame_counter DONE (2026-10-21): FrameCounterCore in frame_counter_model.py is the clock-exact definition (pending
stage, marker-order log, overflow on a full log or a replaced pending event, CLEAR with a marker gives 1); tb/python
compares it clock for clock (NCH 5 / 8 / 1). pysim keeps the event-level FrameCounter.

vision_system sub-blocks (2026-10-21): exact models and tb/python comparisons for mulq_s, fixed_recip, bilinear,
bicubic, frame_buffer, coord_gen and ext_frame_buffer; the RTL itself is unchanged (open review items: asynchronous
resets, -Wall lint) until the vision_system SV step.

ISP stages and video_pipeline DONE (2026-10-21): every ISP stage frame exact against its model (tb/python), and video_pipeline's ISP
exact from CSI-2 lanes to the insert point (a Python CSI-2 transmitter in tb/python). Model fixes the RTL showed: isp_stats
taps the linear RGB after the CCM (10-bit STAT_THR) and reports a frame when the next one starts; CSC BT.709 from CTRL[6];
DPC_CORR counts corrected pixels; the CFA pattern from CTRL[5:4] (pysim now passes none). video_pipeline 1.1.0: DSI / CSI-2
TX underflows counted in DSI_DROPS / CSITX_DROPS; the pipeline hierarchy lints clean (-Wall) in the design, IP-default and
test configurations. Open for the design top: the reset style of the clock-crossing blocks (asynchronous assertion) in the
CDC analysis.

vision_system 2.0.0 DONE (2026-10-21): model/vision_system_model.py is the exact definition and tb/python compares
every output beat (on-chip and SDRAM stores, Verilator and Icarus). RTL: BYPASS (0x38, reset 1; firmware must clear
it after programming a calibration), edge replication of every tap, m_axis back-pressure (credits), CTRL[0] soft
reset, synchronous resets, IMG_WIDTH / IMG_HEIGHT clamped into 1..MAX, saturating sums in coord_gen, free-running
SDRAM refresh schedule, beats outside a frame dropped. Model consequences for pysim: correct() with the v2 edge rule
and saturation; the pysim re-baseline must write BYPASS = 0 (sw/ vision_system setup). New library model:
ip/fifo/fallthrough_fifo (model + cocotb). Open: the DDR-backed frame store (section 8 of the architecture study).
