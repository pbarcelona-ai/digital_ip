# object_tracker

Object search / measurement for target detection and tracking. Watches an AXI4-Stream video (24-bit pixels, tuser = start of frame, tlast = end of line) without touching it: a passive tap on the accepted beats (tvalid & tready). Per frame it finds the pixels of the object inside a search window and reports their bounding box; the CPU runs the tracking loop (search the whole frame, then a window around the predicted position) and draws the result with symbol_overlay. One instance is one detector (one object class: its pixel test and run widths); a design detecting several classes instantiates one per class. Version 2.0.0 (the SKIN_LUT table, the 4-stage pipeline). - Pixel {B, G, R} (R in [7:0]): luma Y = (R + 2 G + B) / 4, chroma Cb = 128 + (B - Y) / 2, Cr = 128 + (R - Y) / 2, saturation S = |Cb - 128| + |Cr - 128|. These are shift-add approximations, not BT.601 (ITU-R BT.601-7: Y = 0.299 R + 0.587 G + 0.114 B, Cb = 128 + 0.564 (B - Y), Cr = 128 + 0.713 (R - Y)); a BT.601 range converts approximately to Cb = 128 + 0.89 (Cb601 - 128), Cr = 128 + 0.70 (Cr601 - 128). SKIN_LUT is learned in this space (python-prototype/train_skin.py). - Object pixel, inside the window (WIN_X / WIN_Y, inclusive; taken at the frame start) and CTRL.MODE = 0 (luma): Y < THRESH (CTRL.POL = 1, dark object on a light scene) or Y > THRESH (POL = 0); CTRL.MODE = 1 (colour): Y, Cb and Cr inside Y_RANGE, CB_RANGE and CR_RANGE (min / max inclusive) and S >= SAT_MIN (e.g. skin tone for faces, saturated paint for cars); with CTRL.SKIN_LUT the chroma test is the learned table instead: Y inside Y_RANGE and bit (Cb - 96) >> 1 of word (Cr - 112) >> 1 of SKIN_LUT set (both indices 0..31, else not an object pixel). - Run filter: a horizontal run of object pixels counts, when it ends (the next pixel is not an object pixel, or the end of the line), if it is at least MIN pixels long (RUN.MIN_W, or CTRL.MIN_RUN when RUN.MIN_W = 0; 0 or 1: every pixel) and, with RUN.MAX_W != 0, at most MAX_W long: isolated pixels, thin lines and objects wider than the class are ignored. The run's whole length is judged, also where it crosses the window's edge (a bus reaching into a car's window is still a bus-length run, not a car-length one); its pixels inside the window then add to COUNT, the sums and the box. - Features: feat_i carries feature_detect's bits of the beat ([0] edge, [1] motion). The object pixel test has two terms: term A is the luma / colour test above combined with the motion bit (CTRL.FEAT_A: the test, test OR motion, test AND motion, motion only), judged with RUN; term B (CTRL.TERM_B) is the edge bit, judged with RUN_B. Each term has its own run filter; both terms' counted runs add to COUNT, the box and the sums (term A's first when both close on the same pixel). - Blobs: the counted runs are also grouped into up to NBLOB separate objects per frame (one pass, no frame store). Grouping is by box proximity, not pixel connectivity: a run joins the blob whose box it touches (its columns within BLOB_CFG.GAP of the box's, its line at most GAP_Y + 1 below the box's last line: a car's roof and body, apart where its windows break the paint, are one object with GAP_Y as tall as the windows); a run touching several blobs joins them into one; a run touching none starts a new blob in a free slot. A blob no run has reached for GAP_Y + 1 lines is closed; a closed blob of fewer than BLOB_CFG.KEEP pixels is dropped (its slot reused), so small clutter does not use up the slots. With every slot taken, a new run is not grouped (BLOB_LOST counts it). With TERM_B, term A's runs use slots 0 .. NBLOB/2 - 1 and term B's the others, so a painted bus never joins the edges of the buildings behind it. At the end of the frame BLOB_X / BLOB_Y / BLOB_N[i] hold blob i (BLOB_N = 0: no blob, or one of fewer than KEEP pixels). BLOB_X / BLOB_Y of an empty slot read 0. - At the end of the frame (the tlast of line FRAME_SIZE height - 1) COUNT, BOX_X, BOX_Y and the sums are latched, FRAMES increments and done_o pulses for one clock. COUNT = 0: nothing found (the box then reads x0 > x1). - The configuration is read as the pixels pass (up to 2 clocks after the beat), except the window (taken at the frame start): change it between frames (after done_o, before the next frame). FRAME_SIZE must be the frame's size. Golden model: ip/video/object_tracker/model/object_tracker_model.py (frame exact, tb/python); in video_processor the tap is feature_detect's forwarded stream (m_axis with feat_o). - SCRATCH[0..27]: plain read / write words for the CPU (the tracking state of this detector: the firmware keeps one set per tracked object of the class). Registers on the cfg_* / sts_* ports; object_tracker_top.sv is the block with its AXI4-Lite register map (src/include/object_tracker_regs.sv): ID "OTRK" / VERSION / DATE at 0x00-0x08, CTRL 0x18, FRAME_SIZE 0x1C, THRESH 0x20, WIN_X 0x24, WIN_Y 0x28, FRAMES 0x2C, COUNT 0x30, BOX_X 0x34, BOX_Y 0x38, SUM_X 0x3C, SUM_Y 0x40, STATUS 0x44, RUN 0x48, Y_RANGE 0x4C, CB_RANGE 0x50, CR_RANGE 0x54, SAT_MIN 0x58, BLOB_CFG 0x5C, SCRATCH 0x60 + 4 i (28 words), RUN_B 0xD0, BLOB_X 0x100 + 4 i, BLOB_Y 0x120 + 4 i, BLOB_N 0x140 + 4 i (i < NBLOB = 8); ADDR_W = 9. Clock - clk (pixel clock). Reset - synchronous active low rst_n. Pipeline - stage 0 the accepted beat (position, window, object bits), stage 1 the run filters and the window clip, stage 2 the blobs (term A and term B side by side on their slots) and the sum products, stage 3 the accumulators. Latency - BLOB_* latched 3 clocks, COUNT / BOX / sums, FRAMES and done_o 4 clocks after the last pixel of the frame.

object_tracker is an IP of the FPGA Cores 4 U digital IP library.

## Directory structure

| Path | Contents |
|------|----------|
| `src/` | RTL (`include/`: the register map files) |
| `tb/` | self-checking testbench, tests in `tb/tests/` |
| `scripts/` | file lists (`build.f`) and flow scripts |
| `docs/` | diagrams, prompt, register table, web page |

<!-- readme:begin (generated by ip/scripts/gen_readmes.py; edits here are overwritten) -->
## Make targets

```
Targets: test (or sim), list-tests, cov, wave, yosys (or synth), docs, diagrams, diagram-check, clean
  make list-tests     name and description of each test available to run
  make test [VCD=1]   simulate; VCD=1 also dumps the testbench VCD (build/sim/<ip>/<tb>.vcd)
  make cov            simulate with Verilator code coverage (build/coverage/<ip>/summary.txt)
  make wave           simulate with the VCD dump and open it in the Surfer waveform viewer
```

## Tests

| Testbench | Test | Description |
|-----------|------|-------------|
| `object_tracker_tb` | `test_registers` | control registers read back, reset results (COUNT 0, empty box) |
| `object_tracker_tb` | `test_dark_object` | A dark rectangle on a light scene: exact box, count and sums (whole-frame window) |
| `object_tracker_tb` | `test_bright_object` | CTRL.POL = 0: a bright object on a dark scene |
| `object_tracker_tb` | `test_window` | Window smaller than the object (box clipped to it); a window written in the middle of a frame applies from the next frame |
| `object_tracker_tb` | `test_run_filter` | Single-pixel specks and a 1-pixel-wide line are ignored with MIN_RUN 2 and counted with MIN_RUN 0 / 1; MIN_RUN 15 with runs of 14, 15 and 16 pixels |
| `object_tracker_tb` | `test_empty` | No object: COUNT 0, box x min > x max |
| `object_tracker_tb` | `test_disable` | CTRL.ENABLE = 0: no frame measured, no done_o |
| `object_tracker_tb` | `test_status` | STATUS[0] during a frame, STATUS[1] for a whole-frame window, STATUS[31:16] = FRAMES |
| `object_tracker_tb` | `test_random` | 24 random scenes, thresholds, polarities, run lengths and windows with random stalls |
| `object_tracker_tb` | `test_id_block` | ID "OTRK", VERSION ("d.dd") and DATE (BCD mm/dd/yyyy) at the base address, read only (SLVERR); the rest of the map from 0x10 |
| `object_tracker_tb` | `test_colour` | CTRL.MODE = 1: a skin-tone patch (face) and a saturated red patch (car paint) on a grey scene; each colour range picks only its own patch, SAT_MIN rejects the grey; reset ranges read back |
| `object_tracker_tb` | `test_run_band` | RUN.MIN_W / MAX_W: of runs 6, 12 and 30 pixels wide, a band keeps only those inside it (a run is judged when it ends, at a non-object pixel or the end of the line, by its whole length: a run longer than MAX_W reaching into the window is not counted) |
| `object_tracker_tb` | `test_scratch` | SCRATCH[0..27] read back what was written, each its own word |
| `object_tracker_tb` | `test_blobs` | Three dark objects, specks and a U shape: one blob each, small ones dropped (KEEP), the U joined into one, GAP, GAP_Y; more objects than slots (BLOB_LOST); random scenes and BLOB_CFG against the model |
| `object_tracker_tb` | `test_random_colour` | 16 random colour scenes and settings with stalls |
| `object_tracker_tb` | `test_terms` | Two terms (feat_i = the pixel's LSBs): CTRL.FEAT_A 0-3 (test, test or motion, test and motion, motion), CTRL.TERM_B with RUN_B (edges, own blob slots), RUN_B read back, random features and settings with stalls |

## Registers

- [register map](docs/object_tracker_regs.md): ID / VERSION / DATE at 0x00-0x08, the registers from 0x10; source [`object_tracker_regs.json`](src/include/object_tracker_regs.json) (edit it and run `python3 ../../scripts/regmap_gen.py src/include/object_tracker_regs.json`), generated [`object_tracker_regs.sv`](src/include/object_tracker_regs.sv), [`object_tracker_regs.xml`](src/include/object_tracker_regs.xml), [`object_tracker_regs.h`](src/include/object_tracker_regs.h)

## Prompt

- [object_tracker_prompt.md](docs/object_tracker_prompt.md): the prompt that regenerates this block, reverse-engineered from its sources (`python3 ../../scripts/make_ip_prompts.py --only object_tracker`)
<!-- readme:end -->

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG.

### RTL hierarchy

[![RTL hierarchy of `object_tracker`](docs/block_diagram.svg)](docs/block_diagram.svg)

### Data flow

[![Data flow of `object_tracker`](docs/object_tracker_dataflow.svg)](docs/object_tracker_dataflow.svg)
<!-- diagrams:end -->
