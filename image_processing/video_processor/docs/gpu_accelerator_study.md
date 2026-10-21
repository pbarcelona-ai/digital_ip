# video_processor: GPU / accelerator study for search and tracking (2026-10-19)

## Why the current system falls short

The present detectors are hand-tuned features (luma / colour ranges, motion bit, edges, a sky profile)
grouped into blobs, with a shape test per class in firmware. They cannot tell a car from a plane, a face
from a beige wall, or a pedestrian from a lamp post reliably, and they cannot track arbitrary objects.
Modern detection and tracking use learned models: a CNN detector (YOLO-class) finds objects of any trained
class in every frame, and a tracker (Kalman prediction + association, optionally appearance embeddings)
keeps identities. That needs roughly 1-10 GOPs per frame (YOLOv8n is about 8.7 GFLOPs at 640 x 640, about
1.6 GFLOPs at 320 x 240); at 30 fps that is 50-300 GOPS. py_core (200 MHz, about 10 M bytecodes/s, no
multiply) is four to five orders of magnitude short. A dedicated accelerator is required.

## 1-2. Repositories evaluated

| Repository | What it is | Pros | Cons | Compiler |
|---|---|---|---|---|
| [Vortex](https://github.com/vortexgpgpu/vortex) (Georgia Tech) | Full-stack RISC-V SIMT GPGPU (RV32/64 IMAF(D)C), configurable cores / warps / threads, L1-L3 caches, FPU, texture, ray tracing, tensor cores (WGMMA, 2:4 sparsity); simx C++ simulator, Verilator RTL sim, Xilinx / Altera FPGAs | Mature (about 6 k commits), Apache-2.0, real compiler and runtime, tensor cores for CNNs, cycle simulator to model against | Large (needs a big FPGA: Alveo / Arria 10 class), SystemVerilog with its own flow, general-purpose: less efficient per op than a dedicated CNN engine | Yes: VOLT (LLVM SIMT compiler), OpenCL 1.2 (POCL), HIP (chipStar), Vulkan (Mesa) |
| [VeriGPU](https://github.com/hughperkins/VeriGPU) | RISC-V-like GPU in SystemVerilog aimed at ASIC, BF16, ML focus | MIT, readable, single-source C++ example flow, timing / area metrics | Early: goals more than features, no performance data, HIP / PyTorch stack planned only; last push Nov 2024 | Partial: C++ example through its runtime; HIP planned |
| [tiny-gpu](https://github.com/adam-maj/tiny-gpu) | Educational GPU: 11-instruction ISA, 8-bit data, 256-word memories, lockstep threads | Small and very clear (under 15 files), cocotb tests, a good model of SIMT basics | Not usable for vision: no divergence, no pipelining, no shared memory, no floats, 8-bit address / data | None (hand-written assembly) |
| [Ventus](https://github.com/THU-DSP-LAB/ventus-gpgpu) (Tsinghua) | RISC-V vector GPGPU in Chisel, up to 16 SMs / 256 warps on FPGA | Active, OpenCL 2.0 stack (LLVM, Terapines), CTS pass rate above 85 % (project claim) | Chisel (not SV), Mulan PSL v2 licence, mostly Chinese documentation | Yes: LLVM OpenCL C |
| [Nyuzi](https://github.com/jbush001/NyuziProcessor) | Larrabee-style SIMD GPGPU, SystemVerilog | LLVM C/C++ compiler, emulator, tests | Stale (toolchain last updated 2022), wide-SIMD rather than SIMT | Yes: LLVM / Clang C/C++ |
| [HWAC TinyYOLO v2 object tracker](https://github.com/hwac-dl/hwac_object_tracker) | Fixed-function TinyYOLO v2 detector (FP16) on a PYNQ-Z1, DAC 2018 contest 5th of 65 | A complete detector in Verilog, Python driver on the ARM | Detection only (no tracking despite the name), FP16 (large), Vivado 2017.2, no licence stated, old model | None: network fixed in RTL; weights loaded by the PYNQ Python code |
| [CNN_YOLO_AI_accelerator](https://github.com/Haden-Min/CNN_YOLO_AI_accelerator) (and the older [HanPU-Code](https://github.com/HanPU-Code/CNN_YOLO_AI_accelerator) version) | INT8 YOLOv3-tiny convolution engine (28 x 28 tile, INT32 accumulate, requantise) on a PYNQ-Z2 | INT8 (the right precision), BatchNorm folding and quantisation tools, Python golden model, timing closed at 100 MHz | One verified conv layer so far: activation / pooling / full network not chained; serial input channels; no licence stated | None: offline weight converter (Darknet parse, fold, quantise) |
| [Verilog Generator of Neural Net Digit Detector](https://github.com/ZFTurbo/Verilog-Generator-of-Neural-Net-Digit-Detector-for-FPGA) | Python flow: train a small CNN in Keras, choose fixed-point widths, generate Verilog; camera to display on DE0-Nano | Apache-2.0, a model-to-RTL generator (fixed point, bit-width search, parallel conv blocks), full camera pipeline | Digits only, old stack (TF 1.4, Python 3.5), network hard-wired into RTL | The generator itself (Keras weights to Verilog) |
| Others worth knowing: [NVDLA](https://nvdla.org/) (NVIDIA conv / pooling / activation engine, BSD compiler, RTL static since 2018), Gemmini (Berkeley systolic array, Chisel, ONNX runtime), FINN / hls4ml (dataflow CNNs by HLS) | | | | |

Takeaways: only Vortex (and Ventus) are real GPUs with compilers; the YOLO repositories are fixed-function
CNN engines (partial or old); tiny-gpu and VeriGPU are references, not usable engines.

## 3. Does a dedicated GPU improve the system?

Yes for capability, but what improves tracking is a learned detector plus a proper tracker, and the hardware
that runs a CNN best is a tensor / systolic engine (NPU), not a SIMT GPU. A SIMT GPU helps with everything
irregular around it (optical flow, correlation trackers, NMS, Kalman / association for many targets,
pre-processing), and Vortex has tensor cores too. Recommended split:
- NPU (INT8 systolic array, DMA, layer descriptors): the detector backbone / head, appearance embeddings.
- Optional SIMT GPU (Vortex-class) or a vector unit: flow, correlation, post-processing.
- CPU (upgraded): tracker logic, control, report.

## 4. Can a custom design be done instead?

Yes. The architectures are well documented (TPU / Gemmini systolic arrays, NVDLA conv core, SIMT as in
Vortex / tiny-gpu). A custom INT8 NPU sized for YOLOv8n-class models (for example 32 x 32 MACs at 200 MHz =
about 400 GOPS peak) is a tractable research design and fits this library's style (register map by JSON,
streaming DMA). A full SIMT GPU from scratch is a much larger effort; adopting Vortex for that role is better.

## 5. Compilers for the GPUs identified

Vortex: yes (LLVM VOLT, OpenCL 1.2 through POCL, HIP through chipStar). Ventus: yes (LLVM OpenCL 2.0).
Nyuzi: yes (LLVM C/C++). VeriGPU: partial (C++ example, HIP planned). tiny-gpu: no. The YOLO / digit
repositories and NVDLA are not programmable processors: their "compiler" is a model converter (weights,
quantisation, layer configuration).

## 6. Compiling the Python code for a custom design

Two paths, both in the spirit of pyc.py:
- NPU (no kernel code): a model compiler in Python. ultralytics exports the model (PyTorch, ONNX); our
  converter folds BatchNorm, quantises to INT8 per channel, tiles each layer for the array and writes a
  command stream (layer descriptors + weights) to memory. The firmware (pyc-compiled Python) only starts
  jobs and reads results, exactly like the present register programming.
- SIMT kernels: extend pyc.py with a kernel mode: a function marked as a kernel (Python subset, thread / block
  index builtins, arrays) compiled to the SIMT ISA (or, with Vortex, emitted as OpenCL C for its LLVM
  compiler). Host Python launches kernels through registers.

## 7. System improvements for searching / tracking any object

1. Detector: a learned, class-rich model (YOLOv8n / v11n on COCO's 80 classes, or an open-vocabulary model
   such as YOLO-World for "any object"), run on tiles or at higher resolution for small, distant targets;
   a class-agnostic motion / objectness path for unknown moving objects; stationary objects come from the
   detector, not from motion.
2. Tracker: Kalman filter (position, velocity, scale), global association (Hungarian, IoU + distance),
   ByteTrack's second pass with low-confidence detections, appearance embeddings (ReID) to keep identities
   through occlusion, a tentative / confirmed / lost / re-identified life cycle; per-class or single
   class-agnostic tracking.
3. Single-object tracking on demand: a correlation or Siamese tracker (KCF / CSRT / SiamRPN-class) for a
   user-selected object of any kind, moving or stationary.
4. Camera-motion compensation: global motion from feature matches (ORB + RANSAC homography or dense optical
   flow) instead of the column / row profile shift.
5. Input quality: full-colour frames at higher resolution (the testbench's GIF palette and 320 x 240 fit
   remove colour and detail detectors need), ISP denoise, display and analysis paths kept separate.
6. Memory: a frame buffer in DDR (DMA) so the accelerator reads whole frames / tiles; today's blocks only
   stream with line buffers.
7. CPU: py_core has no multiply / divide, 32 globals and no arrays; tracking maths needs a stronger CPU
   (RISC-V with M / F extensions running compiled or MicroPython code) or a much richer py_core.
8. Evaluation: annotated ground truth and standard metrics (MOTA, IDF1, HOTA); use ultralytics' tracker
   (ByteTrack / BoT-SORT) on the same videos as a reference to score each hardware change automatically.

## 8. Modelling the selected design in Python

Yes, and it keeps the Python-only approach: pysim/npu.py (register map JSON, DMA, INT8 MAC array with
cycle counts, layer descriptors), a model compiler (ultralytics model -> INT8 command stream), results
checked against the float model; the firmware and tracker extended in Python; a Vortex-like SIMT model only
if a GPGPU role is kept. Then the same register maps drive the SystemVerilog later.

## 9. The repositories named

Covered in the table: VeriGPU (reference, early), tiny-gpu (teaching reference), HWAC TinyYOLO v2
(detector-only, FP16, old), Verilog Generator of Neural Net Digit Detector (generator approach worth reusing),
CNN_YOLO_AI_accelerator (INT8 conv tile, early). None alone delivers detection plus tracking; together they
give a reference set for a custom INT8 NPU, and Vortex covers the general GPU role.

## 10. Other items

- Python environment: torch 2.2.2 is built for NumPy 1.x but NumPy 2.4.6 is installed (ultralytics imports
  with warnings, tensor <-> array conversion may fail): install numpy<2 or a newer torch.
- Model weights download from the internet on first use (yolov8n.pt, about 6 MB).
- Licences: Ultralytics code and weights are AGPL-3.0 (fine for research; a product needs a commercial licence
  or an Apache-licensed model such as YOLOX / RT-DETR / NanoDet); Vortex Apache-2.0; VeriGPU MIT; Ventus
  Mulan PSL v2; HWAC and CNN_YOLO_AI_accelerator state no licence.
- Target FPGA / ASIC: Vortex-class GPUs need a large FPGA; an INT8 NPU plus CPU fits mid-range parts.
- Latency budget: detection plus tracking within one frame time at the chosen frame rate.
