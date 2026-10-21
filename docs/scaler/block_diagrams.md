# Block diagrams

One diagram per image IP, generated from the RTL structure by `tools/docs/make_block_diagrams.py` (Graphviz sources next to each IP in `docs/block_diagram.dot`). Click a diagram to open the SVG at full size.

**Legend.** Blue: interface. Green: control. Amber: memory or table. Grey: datapath stage. Red: stage built around DSP48 multipliers. Solid arrows carry data; dashed arrows carry configuration or sequencing. Stage names (`A`, `B`, `W`, `M1`, ...) are those of the pipeline comments in each IP's source file.

**Common structure.** Every scaler is built from the same shared modules: `axil_regbus` (AXI4-Lite to register bus), `scaler_ctrl` (register map, stream capture, frame sequencing), `scaler_dda` (source coordinates), and `banked_framebuf` (a window read per clock). The IPs differ in the coordinate quantisation and, above all, in the pipelined datapath after the frame store.

| IP | What it is |
|---|---|
| [`scaler_nearest`](#scaler_nearest) | Point sampling: the frame store returns the source pixel closest to each output position, with no arithmetic on the pixel. |
| [`scaler_bilinear`](#scaler_bilinear) | 2x2 interpolation with weights computed in hardware from the sub-pixel phase; six pipeline stages, three of them multiplier stages. |
| [`scaler_edge_directed`](#scaler_edge_directed) | Bilinear with an edge decision: the 2x2 cell is split along the stronger diagonal so interpolation never crosses an edge. |
| [`scaler_polyphase`](#scaler_polyphase) | The separable FIR engine: vertical then horizontal pass with programmable coefficient tables, any even tap count from 2 to 16. |
| [`scaler_bicubic`](#scaler_bicubic) | scaler_polyphase with 4 taps: any Mitchell-Netravali cubic (Catmull-Rom, Mitchell, B-spline, Keys). |
| [`scaler_lanczos`](#scaler_lanczos) | scaler_polyphase with 6 taps and Lanczos-3 coefficients. |
| [`scaler_mip`](#scaler_mip) | Hardware mip pyramid, trilinear sampling and optional anisotropic probes: the engine behind trilinear and anisotropic. |
| [`scaler_trilinear`](#scaler_trilinear) | scaler_mip with one probe per pixel: blends the two mip levels around the requested level of detail. |
| [`scaler_anisotropic`](#scaler_anisotropic) | scaler_mip with up to 16 trilinear probes along the major axis of the pixel footprint. |
| [`sharpen_cas`](#sharpen_cas) | Line-buffered 3x3 sharpener after AMD FidelityFX CAS, about two lines of latency. |
| [`spatial_upscaler`](#spatial_upscaler) | Lanczos-3 scaler followed by the sharpener behind one AXI4-Lite port (an FSR 1-style pipeline). |

## scaler_nearest

Point sampling: the frame store returns the source pixel closest to each output position, with no arithmetic on the pixel. Details: [`scalers/scaler_nearest/README.md`](../../scalers/scaler_nearest/README.md).

[![scaler_nearest](../../scalers/scaler_nearest/docs/block_diagram.svg)](../../scalers/scaler_nearest/docs/block_diagram.svg)

## scaler_bilinear

2x2 interpolation with weights computed in hardware from the sub-pixel phase; six pipeline stages, three of them multiplier stages. Details: [`scalers/scaler_bilinear/README.md`](../../scalers/scaler_bilinear/README.md).

[![scaler_bilinear](../../scalers/scaler_bilinear/docs/block_diagram.svg)](../../scalers/scaler_bilinear/docs/block_diagram.svg)

## scaler_edge_directed

Bilinear with an edge decision: the 2x2 cell is split along the stronger diagonal so interpolation never crosses an edge. Details: [`scalers/scaler_edge_directed/README.md`](../../scalers/scaler_edge_directed/README.md).

[![scaler_edge_directed](../../scalers/scaler_edge_directed/docs/block_diagram.svg)](../../scalers/scaler_edge_directed/docs/block_diagram.svg)

## scaler_polyphase

The separable FIR engine: vertical then horizontal pass with programmable coefficient tables, any even tap count from 2 to 16. Details: [`scalers/scaler_polyphase/README.md`](../../scalers/scaler_polyphase/README.md).

[![scaler_polyphase](../../scalers/scaler_polyphase/docs/block_diagram.svg)](../../scalers/scaler_polyphase/docs/block_diagram.svg)

## scaler_bicubic

scaler_polyphase with 4 taps: any Mitchell-Netravali cubic (Catmull-Rom, Mitchell, B-spline, Keys). Details: [`scalers/scaler_bicubic/README.md`](../../scalers/scaler_bicubic/README.md).

[![scaler_bicubic](../../scalers/scaler_bicubic/docs/block_diagram.svg)](../../scalers/scaler_bicubic/docs/block_diagram.svg)

## scaler_lanczos

scaler_polyphase with 6 taps and Lanczos-3 coefficients. Details: [`scalers/scaler_lanczos/README.md`](../../scalers/scaler_lanczos/README.md).

[![scaler_lanczos](../../scalers/scaler_lanczos/docs/block_diagram.svg)](../../scalers/scaler_lanczos/docs/block_diagram.svg)

## scaler_mip

Hardware mip pyramid, trilinear sampling and optional anisotropic probes: the engine behind trilinear and anisotropic. Details: [`scalers/scaler_mip/README.md`](../../scalers/scaler_mip/README.md).

[![scaler_mip](../../scalers/scaler_mip/docs/block_diagram.svg)](../../scalers/scaler_mip/docs/block_diagram.svg)

## scaler_trilinear

scaler_mip with one probe per pixel: blends the two mip levels around the requested level of detail. Details: [`scalers/scaler_trilinear/README.md`](../../scalers/scaler_trilinear/README.md).

[![scaler_trilinear](../../scalers/scaler_trilinear/docs/block_diagram.svg)](../../scalers/scaler_trilinear/docs/block_diagram.svg)

## scaler_anisotropic

scaler_mip with up to 16 trilinear probes along the major axis of the pixel footprint. Details: [`scalers/scaler_anisotropic/README.md`](../../scalers/scaler_anisotropic/README.md).

[![scaler_anisotropic](../../scalers/scaler_anisotropic/docs/block_diagram.svg)](../../scalers/scaler_anisotropic/docs/block_diagram.svg)

## sharpen_cas

Line-buffered 3x3 sharpener after AMD FidelityFX CAS, about two lines of latency. Details: [`scalers/sharpen_cas/README.md`](../../scalers/sharpen_cas/README.md).

[![sharpen_cas](../../scalers/sharpen_cas/docs/block_diagram.svg)](../../scalers/sharpen_cas/docs/block_diagram.svg)

## spatial_upscaler

Lanczos-3 scaler followed by the sharpener behind one AXI4-Lite port (an FSR 1-style pipeline). Details: [`scalers/spatial_upscaler/README.md`](../../scalers/spatial_upscaler/README.md).

[![spatial_upscaler](../../scalers/spatial_upscaler/docs/block_diagram.svg)](../../scalers/spatial_upscaler/docs/block_diagram.svg)
