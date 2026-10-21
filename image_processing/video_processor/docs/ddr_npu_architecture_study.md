# video_processor: DDR, frame buffers and NPU architecture study (2026-10-20)

Decisions taken (user, 2026-10-20): Python models move next to their RTL in `model/` folders; unit
verification with cocotb against those models; no target device yet; the NPU's 64 x 64 MAC array becomes
a reusable component; a reusable DDR controller on a generic DDR memory, with an `ifdef` place for a
vendor controller; frames held in DDR in ping-pong buffers; the amount of external DDR is not a
constraint. This note gives the numbers behind the DDR architecture and the NPU verification plan.

## 1. Measured NPU demand (Python model, YOLOv8s, 1920 x 1088 + 640 x 384 passes, 81.5 GMAC per frame)

Per frame the NPU moves **474 MB** through DDR: convolutions 390 MB (weights 11 MB once per pass, the
rest activations), ADD 37 MB, UPSAMPLE 17 MB, INPUT 19 MB (the frame, both passes), DECODE 7 MB.

Frame time against the NPU's DDR port width (`npu.BUS_BYTES`, bytes per NPU clock; clocks from the model,
frame rate at an assumed 250 MHz NPU clock; the per-interface rates in section 2 are measured the same way):

| NPU port | Bandwidth at 250 MHz | Clocks per frame | Frame rate | vs. unlimited |
|---|---|---|---|---|
| 8 B (64-bit AXI) | 2 GB/s | 60.3 M | 4.1 fps | 2.8 x slower |
| 16 B (128-bit, today's model) | 4 GB/s | 35.5 M | 7.0 fps | 1.66 x |
| 32 B (256-bit) | 8 GB/s | 26.1 M | 9.6 fps | 1.22 x |
| 64 B (512-bit) | 16 GB/s | 23.0 M | 10.9 fps | 1.07 x |
| unlimited | - | 21.4 M | 11.7 fps | 1 |

The NPU becomes compute-bound above about 32 bytes per clock: doubling to 64 B buys 13 %, unlimited
bandwidth 22 %. **A 256-bit NPU port and about 8 GB/s of DDR for the NPU is the sweet spot.** (The model
treats DDR as a flat byte array at a fixed rate; real DDR loses 20-35 % to row misses, refresh and
read / write turnaround, hence the controller efficiency figures below.)

Video traffic, 1920 x 1080 RGB888 (6.2 MB per frame):

| Stream | Rate |
|---|---|
| camera frames into the ping-pong buffers (30 fps) | 0.19 GB/s write |
| NPU reads of the frame (part of its 474 MB) | - |
| display from DDR, if the display path is later moved to a frame buffer (60 Hz) | 0.37 GB/s read |
| CPU (firmware, detections, DDR window) | < 0.01 GB/s |

## 2. One DDR controller or several

Usable bandwidth of common interfaces (peak x 0.7 for a mixed read / write, multi-stream load):

| Interface | Peak | Usable |
|---|---|---|
| DDR3-1600 x16 | 3.2 GB/s | 2.2 GB/s |
| DDR4-2400 x32 | 9.6 GB/s | 6.7 GB/s |
| DDR4-2400 x64 | 19.2 GB/s | 13.4 GB/s |
| DDR4-3200 x64 | 25.6 GB/s | 17.9 GB/s |

**A. One controller, shared** (camera writer, NPU, CPU, later the display reader on one multi-port AXI
interconnect):
- x64 DDR4-2400: 13.4 GB/s for 8 GB/s NPU + 0.6 GB/s video: about 35 % headroom; NPU at 9.6 fps.
- x32 DDR4-2400: about 6.1 GB/s left for the NPU (25 B per clock): 8.8 fps.
- x16 DDR3-1600: about 1.6 GB/s left (7 B per clock): 3.7 fps.
- For: one PHY and one set of pins, the least logic and power, one address space (the NPU reads frames
  where the writer put them, the CPU sees everything through its window), the simplest board.
- Against: the NPU's long bursts delay the video streams, so video ports need priority (QoS) and FIFOs
  sized for the worst NPU burst latency; mixing streams costs DDR efficiency (bank conflicts,
  turnarounds); one ceiling for everything.

**B. Two controllers, by traffic class**: DDR0 for video (camera writer, ping-pong buffers, display),
CPU and detections; DDR1 for the NPU (weights, activations). The NPU's INPUT operation reads the frame
from DDR0 (19 MB per frame) through a second interconnect port.
- x32 DDR4-2400 each: the NPU alone on 6.7 GB/s (27 B per clock): 9.0 fps (vs. 8.8 shared); video isolated.
- x64 each with a 512-bit NPU port: up to 10.9 fps.
- For: real-time video can never be starved by the NPU (no QoS tuning, small FIFOs); each controller
  sees a simpler access pattern (better efficiency); more total bandwidth on narrow interfaces.
- Against: a second PHY and pin set (about 80-120 I/O per x32 DDR4 channel), a second controller (vendor
  controllers are typically 10-20 k LUTs each), more power, two memory regions (no extra copies needed:
  region-mapped, not interleaved).

**C. More than two (e.g. NPU weights and activations on separate channels)**: past about 16 GB/s for the
NPU there is little to gain (section 1: 10.9 to 11.7 fps at most); only worth it for a much larger array
or a faster clock.

**Recommendation.** Build the interconnect and the controller so the count is a parameter
(`NUM_DDR` = 1 or 2, region-mapped), with the NPU on a 256-bit port and video ports at high priority.
Default **one controller**: with any x64-class DDR4 interface it carries the whole load with about 35 %
headroom, at the lowest cost. Choose **two** when the target's DDR interfaces are x32 or narrower, or when
the display moves to a DDR frame buffer (a real-time reader with a hard underflow deadline). With no target
device yet, the controller model (step 2 below) will let us measure the efficiency loss of the shared
case on the real streams, not the 0.7 estimate.

## 3. Ping-pong frame buffers

The frame writer (vision_system output, RGB888) gets two buffers in DDR (`FB_ADDR0`, `FB_ADDR1`, one
stride). It writes buffer W; at each frame end:
- if the reader (the NPU) is idle: the buffers swap, the NPU starts on the frame just completed
  (`AUTO`), the writer continues into the other buffer;
- if the NPU is busy: the writer keeps W (the frame is dropped for detection, counted in a status
  register); the buffer being read is never written, so there is no tearing.

Cost of ping-pong with an NPU slower than the camera: a finished NPU waits for the next frame end
(16.7 ms on average at 30 fps). At 104 ms per NPU frame the runs start on every 4th camera frame (7.5
detection runs a second instead of 9.6). A third buffer (`NBUF` = 3, triple buffering) removes the wait:
the NPU restarts at once on the newest complete frame. Proposal: ping-pong as the default, `NBUF` a
parameter (2 or 3) of the frame writer, so the choice costs one more buffer address and no redesign.

A DDR frame buffer also allows a later option: delay the displayed video by the NPU's latency so the
symbols are drawn on the frame they were detected in (today they are drawn on a later frame, at the
tracker's predicted position).

## 4. Reusable DDR controller

```
ip/memory/ddr_ctrl/
  src/ddr_ctrl.sv          AXI4 slave ports (multi-port arbiter with QoS) -> scheduler
                           `ifdef DDR_CTRL_VENDOR
                             ddr_ctrl_vendor u_vendor (...)   // place holder: the vendor's controller
                                                              // + PHY, same AXI ports and status
                           `else
                             generic: per-bank state machines, open-page policy, refresh, timing
                             parameters (tRCD, tRP, tCL, tWR, tRFC, tREFI, ...), a DFI-style command
                             interface to the PHY
                           `endif
  src/ddr_ctrl_vendor.sv   the place holder (ports only, `ifdef DDR_CTRL_VENDOR`)
  src/include/ddr_ctrl_regs.json   status / statistics registers (row hits, refresh, per-port bytes)
  model/ddr_ctrl_model.py  transaction-level model with bank / row timing (bandwidth and latency)
  tb/                      cocotb tests against the model
ip/memory/ddr_mem/         the generic DDR memory: a behavioural SDRAM (banks, rows, timings, refresh
                           check) behind the DFI-style interface, for simulation; its Python model
```

A DDR PHY cannot be generic (I/O cells, calibration and clocking are device-specific), so the generic
build ends at the DFI-style interface, which the generic memory model answers in simulation; a vendor
build replaces controller and PHY under `DDR_CTRL_VENDOR`. Library blocks to reuse: `memory_arbiter`
(port arbitration), `dma_engine` / `axis_dma` (burst engines for the frame writer and the NPU DMA),
`axi_checkers` (protocol checks in the testbenches).

The 64 x 64 MAC array becomes `ip/math/mac_array` (parameters ROWS, COLS, operand and accumulator
widths; INT8 x INT8 -> INT32 for the NPU), with its own model and tests, instantiated by the NPU. The
NPU's arithmetic does not depend on the array size (only its timing does), so a small array gives
bit-identical results.

## 5. NPU verification, and RTL simulation speed

The NPU is verified like every other IP in the library (directed and random tests in its testbench,
assertions, coverage, lint, synthesis check, code review and requirements check), with cocotb comparing
the RTL with `npu_model.py` bit for bit:
1. every operation alone (CONV 1x1 / 3x3, stride 1 / 2, every padding; MAXPOOL; ADD; UPSAMPLE; COPY;
   INPUT with both letterbox banks; DECODE; NMS), random shapes, weights and quantisation, at the edges
   of every range (saturation, zero padding, odd sizes, CAND_MAX, DET_MAX);
2. descriptor sequences, errors (bad operation -> IRQ ERROR), DMA bursts and back-pressure, interrupts;
3. the whole YOLOv8s program on small inputs (e.g. 64 x 64 and 160 x 96: well under a second of
   simulated time) against the model, and the two-pass program;
4. the same tests with a small array (e.g. 8 x 8) and with 64 x 64: identical results;
5. a full 1920 x 1088 frame as a sign-off test (below).

**Why a full frame is slow in RTL simulation, and when it is feasible.** One frame is 21-35 M NPU clocks;
each clock evaluates 4,096 multiply-accumulates plus the DMA, the DDR controller and the memory model.
- Icarus Verilog (the library's default simulator) evaluates events one by one: a design this size runs
  at roughly 100-1,000 clocks per second, so one frame takes **10-100 hours**. Not practical, and the
  reason the earlier answer called it infeasible.
- Verilator compiles the RTL to C++: an array like this typically runs at roughly 10-100 k clocks per
  second, so one frame takes **about 6 minutes to 1 hour**. That is feasible, provided the testbench
  does not run Python on every clock (cocotb loads the program and frame into the DDR memory model,
  starts the NPU, waits for the interrupt and compares the detection list and tensors with the model;
  the DDR memory model itself is in SystemVerilog / C++).
- The Python model is fast (about 20 seconds per frame) because numpy does each operation as whole-array
  arithmetic; the RTL must model every clock.

So the full-size NPU **can** be run in RTL simulation with Verilator, as a long sign-off test (a few
frames, overnight), while the per-operation and small-input tests give the coverage. These speeds are
estimates; the first SV step measures them on the actual array.

## 6. Order of work

1. (Python, after run 8) Models into `model/` folders next to their RTL, loaded through `build.f`;
   pysim output identical to run 8.
2. (Python) Models of the new blocks: `ddr_ctrl` (bank / row timing), `ddr_mem`, `mac_array`,
   ping-pong frame writer (`NBUF`), NPU on the controller model; re-measure section 1 / 2 with real DDR
   efficiency; cocotb tests written against the models.
3. (SV, when the user starts SV work) py_core, py_soc, i2c, intc; then symbol_overlay, feature_detect,
   object_tracker, blur_sharpen paths; `mac_array`, `ddr_mem`, `ddr_ctrl`; the NPU; the design top.

## 7. Approved (user, 2026-10-20)

- This document and the order of work (section 6) are approved, including section 5 (NPU verification:
  per-operation and small-input tests for coverage, full frames in Verilator as the sign-off).
- Every Python model and its SystemVerilog module shall match exactly, starting at the lowest level of
  the hierarchy: each module's cocotb tests compare the RTL with its model bit for bit (and cycle for
  cycle where the model defines timing) before its parent is built on it.
- The DMA engines, the DDR controller and the generic DDR memory are SystemVerilog (the memory model may
  use C++ through Verilator where needed for speed) and match their Python models exactly, like every
  other module.
- Every SystemVerilog file created or updated shall end its review with no issues found (CLAUDE.md
  review guidelines).
- When the complete video_processor is updated, the review adds a design-level clock-domain-crossing
  analysis (every crossing between the camera, pixel, CPU, NPU and DDR clocks listed with its
  synchroniser and checked).

## 8. Decisions during the SV work (user, 2026-10-20)

- Transaction-level models stay as they are (pysim identical to run 8); each block's cocotb test compares
  the RTL with its model bit for bit and clock for clock with the RTL's fixed latencies applied (input
  synchronisers, registered outputs), and the model's header states those latencies.
- Besides the short frames that give coverage, one full-size image runs through the complete SV design and
  its testbench and is verified against the Python baseline.
- (2026-10-21) vision_system's frame store moves to the DDR: the on-chip store (four replicated banks sized for
  720 x 720) cannot hold a 1920 x 1080 frame, and holding input until the previous frame has left halves the
  frame rate. The store becomes a DDR client of the shared controller: frames written double-buffered (input
  never waits for the output), source pixels read through an on-chip cache of the source rows the correction
  needs (the mapping is locally smooth). vision_system's logic is verified against its exact model behind a
  frame-store interface first; the DDR-backed store (Python model, then SV) follows with ddr_ctrl / ddr_mem.
