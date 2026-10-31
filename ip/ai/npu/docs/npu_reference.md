<!-- Industry reference check of npu: copied into docs/npu_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - npu (2026-10-26, updated for CONV 1.2.0)
// Sources:
//   [1] B. Jacob et al., "Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only
//   Inference", CVPR 2018 - INT8 x INT8 -> INT32 accumulation, per-channel requantisation by a fixed-point
//   multiplier M and a shift S, bias added in INT32
//   [2] N. P. Jouppi et al., "In-Datacenter Performance Analysis of a Tensor Processing Unit", ISCA 2017 -
//   large INT8 MAC arrays fed from on-chip buffers, weights and activations staged from DRAM
//   [3] AMD/Xilinx, "DPUCZDX8G for Zynq UltraScale+ MPSoCs", PG338 - a descriptor-driven CNN engine (conv,
//   pool, element-wise, upsample) with input / output channel and pixel parallelism, DMA to DDR
//   [4] Ultralytics YOLOv8 (2023), DFL head - box sides as the expectation of a softmax over REG bins;
//   A. Neubeck, L. Van Gool, "Efficient Non-Maximum Suppression", ICPR 2006 - greedy NMS by score
// Published algorithm / equations:
//   acc = sum(w x) + b (INT32); q = clamp(round(acc M / 2^S)) [1]; MAC array with on-chip buffering [2, 3];
//   DFL: d = sum(r softmax(v)_r), softmax via exp of (max - v); greedy NMS: visit by score, suppress
//   boxes whose IoU with a kept box exceeds a limit [4].
// Comparison with this IP (section 6):
//   Matches: INT8 / INT32 arithmetic and per-channel (M, S) requantisation with round-half-up ((acc M +
//   2^(S-1)) >> S; [1]'s rounding doubling multiply differs in rounding but the golden model defines this
//   one); an output-stationary PE_P x PE_O array (pixel x output-channel parallelism, as [3]) with weight
//   lanes and a row buffer; descriptor-driven operations on DDR; DFL decode with an exp LUT (the softmax
//   normalisation folded into the expectation's division) and the sigmoid score LUT; greedy NMS by score
//   with a same-class IoU limit, plus a cross-class limit and same-class containment (extensions of [4]:
//   one object seen as two classes, a part of a long object), the result ordered by area.
//   Simplifications (deliberate, the golden model's): one operation at a time, no layer fusion; CONV
//   overlaps its row loads (double-buffered row buffer, queued DMA reads) and output writes (output
//   buffer, posted writes) with the MACs, as the DMA engines of [2, 3] - about 14 M clocks of CONV for the
//   YOLOv8s program at 1920 x 1088 on the 64 x 64 array, within the model's estimate (CYCLES reports the
//   RTL's own); NMS sequential (O(n^2) compares, n <= CAND_MAX).
// Result: in line with the reference; no TODO.
```
