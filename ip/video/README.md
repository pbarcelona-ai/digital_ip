# Video: MIPI CSI-2 camera to HDMI, DVI, LVDS, MIPI DSI and MIPI CSI-2

Camera input, image signal processing and display output IP, with
`video_pipeline` integrating them with the library's `scaler_bilinear` into a
complete camera-to-monitor path. Every block uses the library's AXI4-Stream
video convention (`tuser` = start of frame, `tlast` = end of line, component 0
in the low bits; RGB pixels are `{B, G, R}`) and can be used on its own.

## Pipeline

```
 camera ──D-PHY──► [vendor D-PHY RX] ──PPI bytes──┐
                                                  ▼   byte clock
                                             csi2_rx  (lane deskew, header ECC, CRC-16, VC/DT filter)
                                                  │
                                       axis_async_bridge (library)          ──── clock crossing ────
                                                  ▼   pixel clock
                                          csi2_raw_unpack   RAW8 / RAW10 / RAW12 → 1 pixel per clock
                                                  ▼
  Bayer domain              ┌─────────── isp_blc_wb ─────────── black level, white balance gains
  (RAW10)                   │              isp_dpc              hot / dead pixel correction (5x5)
                            └──────────── isp_demosaic ───────── bilinear 3x3 → RGB 10-bit
                                                  ▼
  RGB 10-bit linear                          isp_ccm  ──tap──► isp_stats (AE / AWB sums, clipping)
                                                  ▼
                                             isp_gamma          10 → 8 bit programmable curve
                                                  ▼
  RGB / YCbCr 8-bit                          isp_csc            RGB → YCbCr 4:4:4 BT.601 / BT.709
                                                  ▼
                              ┌──────── scaler_bilinear (library, line-buffer mode) ────────┐
                              └──────────────────── or bypass ──────────────────────────────┘
                                                  ▼
          vid_timing_gen ──de/hs/vs──►  axis_to_video   FIFO, frame lock, underflow recovery,
          (genlock to camera)                 │         colour-bar test pattern
                                              │ timed video (same for every output)
          ┌──────────────────┬────────────────┼──────────────────┬──────────────────┐
          ▼                  ▼                ▼                  ▼                  │
       hdmi_tx            lvds_tx          dsi_tx             csi2_tx              │
   DVI / HDMI, AVI     OpenLDI 7:1,      video mode,        FS / lines / FE,       │
   InfoFrame           VESA / JEIDA,     VSS / HSS +        RGB888 or YUV422       │
          │            24/18 bpp,        RGB888 packets,          │                │
          │            single / dual     DCS init commands        │                │
          ▼                  ▼                ▼                  ▼
   tmds_serializer   lvds_serializer   mipi_tx_engine ──► D-PHY TX (vendor) ──► panel / SoC
          ▼                  ▼          (shared: line buffer, ECC, CRC, EoTp, lanes)
     HDMI monitor       LVDS panel
```

Each function has a bypass bit in `video_pipeline` (`BYPASS` register,
applied at the next frame start):

| Bit | Function | Output when bypassed |
|---|---|---|
| 0 | black level | raw value |
| 1 | white balance | unscaled value |
| 2 | defect correction | raw centre pixel |
| 3 | demosaic | raw value on R, G and B (grey) |
| 4 | colour matrix | input RGB |
| 5 | gamma | linear, input >> 2 |
| 6 | colour space conversion | RGB (reset default) |
| 7 | scaler | stream routed around the scaler (reset default) |

`CTRL.TPG` replaces the whole pipeline output with colour bars, and
`CTRL[1]` selects HDMI or DVI signalling.

## Choosing the interfaces

`video_pipeline/src/configuration.sv` (the first file in
`video_pipeline/scripts/build.f`) has one `define per external interface:

```systemverilog
`define VP_CSI2_RX    // MIPI CSI-2 camera input
`define VP_HDMI       // HDMI / DVI output
`define VP_LVDS       // LVDS panel output
`define VP_DSI        // MIPI DSI panel output
`define VP_CSI2_TX    // MIPI CSI-2 output to a processor
```

Comment one out to exclude that interface: its ports, logic and clock
inputs (`byte_clk` for the camera, `tx_byte_clk` when neither MIPI
transmitter is built) are removed from `video_pipeline` and its status
registers read as 0. `BUILD_CFG` (0x0FC) reports what was built, so
software can check. Compiling `video_pipeline.sv` without the configuration
file stops elaboration with an error. Without the camera input the
pipeline has no video source, but every output can still show the test
pattern. The `video_pipeline` testbench follows the same `define`s
(`+quick` runs only its output scenario, for trying configurations).

## Blocks

| IP | Function | Notes |
|---|---|---|
| `csi2_rx` | CSI-2 protocol layer | 1/2/4 lanes; deskew up to 7 byte clocks; ECC single-bit correction, multi-bit drop; CRC-16 check; FS/FE; one packet per HS burst |
| `csi2_raw_unpack` | packed payload → pixels | RAW8/10/12, any lane count, aligned to `OUT_W` |
| `isp_window` | N×N window generator | line buffers in block RAM; `BORDER` clamp or mirror (reflect-101, keeps Bayer phase); restarts on an early SOF |
| `isp_blc_wb` | black level + white balance | per-CFA-colour offsets, Q4.8 gains, any Bayer pattern |
| `isp_dpc` | defective pixel correction | 8 same-colour neighbours, threshold, correction pulse |
| `isp_demosaic` | Bayer → RGB | bilinear, exact on linear ramps inside the frame |
| `isp_ccm` | 3×3 colour matrix | signed Q5.10, offsets, clamping; 9 DSP multipliers |
| `isp_gamma` | tone curve | one 1024-entry table for R, G, B, written at run time |
| `isp_csc` | RGB → YCbCr 4:4:4 | BT.601 / BT.709 limited range |
| `isp_stats` | AE / AWB statistics | per-frame sums, pixel and clip counts |
| `vid_timing_gen` | display timing | any progressive mode; CEA vsync alignment; genlock |
| `axis_to_video` | stream → timed video | frame lock, underflow → black + resync, test pattern |
| `tmds_encoder` | TMDS channel coder | DVI 8b/10b with DC balance, control, TERC4, guard bands |
| `hdmi_tx` | DVI / HDMI link layer | HDMI preambles, guard bands, AVI InfoFrame with BCH ECC |
| `tmds_serializer` | generic 10:1 serializer | phase-independent load; use vendor OSERDES at 1080p |
| `lvds_tx` | LVDS panel (OpenLDI 7:1) | VESA / JEIDA 24 bpp, 18 bpp; single or dual link (odd / even pixels) |
| `lvds_serializer` | generic 7:1 serializer | single (7x) and dual (3.5x pixel clock) link rates |
| `dsi_tx` | MIPI DSI host, video mode | sync events (VSS / HSS) + RGB888 0x3E, optional EoTp, 1/2/4 lanes; DCS short / long commands in HS for panel init |
| `csi2_tx` | MIPI CSI-2 transmitter | the output looks like a camera: FS / FE with frame numbers, RGB888 (0x24) or YUV422 8-bit (0x1E), 1/2/4 lanes |
| `mipi_tx_engine`, `mipi_line_buf` | shared by `dsi_tx` / `csi2_tx` | packet engine (ECC, CRC, EoTp, lane distribution, bursts that never pause) and dual-clock ping-pong line buffer; tested through those two |
| `video_pipeline` | everything above | AXI4-Lite register map in the source header |

Shared testbench models in `video_tb_lib/`: `csi2_lane_driver` (D-PHY lanes
with skew, filler bytes, CSI-2 packet builder), `hdmi_sink_model`
(independent TMDS decoder that checks HDMI framing and InfoFrames) and
`dsi_rx_model` (DSI packet decoder with ECC / checksum checks and a timed
packet log), `axis_frame_bfm` (frame driver / monitor with random gaps and
back-pressure) and `conv2d_ref` (convolution reference model).

## Spatial filters: blur and sharpen

```
              blur_sharpen
              ┌─────────────────────────────────────────────────────┐
  AXI4-Stream │  conv2d_core (stage 1)      conv2d_core (stage 2)   │ AXI4-Stream
  ───────────►│  isp_window + N×N MAC  ──►  isp_window + N×N MAC    ├──────────►
              │        ▲ kernel                  ▲ kernel           │
              │        └── MODE selects blur / sharpen / identity ──┤◄── AXI4-Lite
              └─────────────────────────────────────────────────────┘
```

| IP | Function |
|----|----------|
| `conv2d_core` | N×N (3 or 5) convolution for C components: `isp_window` + 4-stage multiply-accumulate, signed `COEF_W`-bit kernel, `out = clamp((Σ k·p + round) >>> shift)`; the kernel is taken per frame and the latency does not depend on it |
| `conv2d_filter` | `conv2d_core` + AXI4-Lite (FRAME_SIZE, SHIFT, K[i]); any kernel, applied from the next frame |
| `blur_filter` | `conv2d_filter` with a binomial (Gaussian) reset kernel, [1 4 6 4 1]² / 256 |
| `sharpen_filter` | `conv2d_filter` with an unsharp-mask reset kernel, (1 + a)·I − a·blur |
| `blur_sharpen` | two `conv2d_core` stages always in line; MODE 0 blur, 1 sharpen, 2 sharpen→blur, 3 blur→sharpen, 4 pass-through. An unused stage runs the identity kernel, so latency and throughput are the same in every mode; blur and sharpen kernels are programmable banks |

Kernels are defined in `conv2d_core/src/conv2d_pkg.sv`. Each stage uses
N·N·C multipliers (75 for 5×5 RGB) and N−1 line buffers.

## Running

```sh
make -C video/<ip> test          # one IP (or scripts/run_sim.sh <ip>)
scripts/run_all.sh sim           # whole library
```

## Design limits

- **No frame buffer.** The display is genlocked to the camera: vertical
  blanking stretches line by line until the next camera frame is ready. The
  display line time must be at least the camera line time (twice it for a
  2:1 vertical downscale). For independent frame rates put a DRAM frame
  buffer (`axis_dma`) in front of `axis_to_video`.
- **Reconfiguring while the camera streams** drops CSI data while the output
  is stopped; the pipeline recovers by itself within a few frames:
  `csi2_raw_unpack` realigns its byte groups on line and frame markers,
  `isp_window` restarts on an early start of frame, the scaler / bypass
  router closes frames the scaler can no longer finish (65536-clock
  watchdog), and `axis_to_video` drops leftover pixels during vertical
  blanking. Change the scaler's sizes only after clearing its
  `CTRL.ENABLE` and waiting for `STATUS.BUSY = 0`.
- **D-PHY** physical layer is not included (it is analog and vendor
  specific); `csi2_rx` expects lane-aligned PPI bytes after the sync byte,
  and `dsi_tx` / `csi2_tx` drive a PPI-style transmit interface
  (HS request, PHY ready, one byte per lane per byte clock).
- **DSI** runs in video mode with sync events and LP blanking; pixel
  packets trail their sync event by one line (the relative timing is
  exact). Commands are sent in HS mode while video is off; panels that need
  LP escape-mode commands need the PHY's escape path. Lines must fit the
  link: width x 3 / lanes byte clocks plus about 40 per line.
- **LVDS** dual link needs even horizontal timing values (pixel pairs start
  on even pixel clocks).
- **Serializer**: `tmds_serializer` is behavioural; at 1080p60
  (1.485 Gbit/s per lane) use the FPGA's OSERDES and TMDS output buffers.
- One CSI-2 packet per HS burst (typical for sensors).

## Synthesis

All IPs pass the library Yosys flow (`scripts/run_yosys.sh <ip>`, Xilinx
7-series). `video_pipeline` contains the scaler, so it carries a
`scripts/sv2v` marker and is converted with sv2v first, like the scaler
family. Default parameters (2 lanes, 2048-pixel lines, scaler, all five
outputs): about 16,300 LUTs, 21 RAMB18 + 12 RAMB36, 19 DSP48E1. Without
the MIPI transmitters the pipeline is about 7,200 LUTs: each `dsi_tx` /
`csi2_tx` costs several thousand LUTs, almost all in `mipi_tx_engine`'s
80-byte queue (up to six bytes written per clock at any position). A
narrower queue fed in fixed-size words would cut this substantially and is
the main optimisation left; `lvds_tx` is about 60 LUTs.

## Verification status

Every IP has a self-checking testbench (iverilog) with random flow control
and a reference model, and passes. The `video_pipeline` system test streams
CSI-2 frames from a camera model into the pipeline and decodes the TMDS
output with an independent HDMI sink model; every output pixel matches a
bit-exact model of the chain for: full ISP in RGB and YCbCr BT.709 (HDMI),
everything bypassed (DVI), a mixed bypass mask, the scaler at 1:1 and 2:1,
the test pattern, and a camera header error, with recovery after each
reconfiguration. Fault injection was used to confirm the
testbenches catch real errors. The CSI-2 CRC matches both CRC examples of the
specification. The shared CSI-2 / DSI header ECC reproduces the ECC byte of
the DSI End of Transmission packet (08 0F 0F 01). The transmitters are
verified by loopback: `csi2_tx` into the verified `csi2_rx`, `dsi_tx` into
`dsi_rx_model`, `lvds_tx` against an independently written bit-position
table. Not yet verified against external references: the HDMI data-island
BCH code and TERC4 / guard-band tables, the DSI and CSI-2 pixel byte
orders and the OpenLDI bit tables are implemented from the specifications
and checked only against this library's own models, so confirm them on a real sensor and monitor
(or an HDMI analyser) before relying on HDMI mode; DVI mode uses only the
standard 8b/10b and control codes.
