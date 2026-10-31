# NPU microarchitecture (design note, 2026-10-25)

The golden model is `model/npu_model.py` (transaction level: every operation's result in DDR is defined
bit-exactly; its clock count is an estimate). The RTL matches every operation's DDR result bit for bit;
its timing is its own (the CYCLES register reports the RTL's clocks). Sizes below come from the compiled
YOLOv8s programs (`build/pysim/npu_prog_yolov8s_*.npz`): CONV 1 x 1, 3 x 3 stride 1 and stride 2 (pad
1), MAXPOOL, ADD, UPSAMPLE, INPUT, DECODE (REG 16, NC 80), NMS; no COPY (implemented anyway);
cin x k x ceil64(win) <= 96 KB, 64 x cin x k x k <= 288 KB, cout <= 512, win <= 1920.

## Blocks

```
npu_top        register map (npu_regs.json, regmap_gen) + npu
npu            command processor, frame writer, the engines, one AXI4 master (256-bit, ddr_ctrl port)
  npu_dma      byte-addressed read / write streams on AXI4: read (addr, n) -> 32-byte chunks aligned to
               byte 0 of the request; write (addr, n) <- chunks, strobes for partial words; INCR bursts
               of up to 16 beats, never across 4 KB; one request at a time, reads and writes in order
  npu_cmd      fetches a 64-byte descriptor, starts the engine of its operation, next on done; END:
               done (IRQ_STATUS[0]); an unknown operation or a shape the model rejects: error
               (IRQ_STATUS[1]), the run stops
  npu_rowbuf   row buffer: rows of planar tensors (slot = (channel, tap row)), 512-bit words, two read
               ports; window unit: 64 lanes, lane i = byte at x0 * s + dx - pad + i * s of a slot,
               0 / invalid outside the row (CONV, MAXPOOL)
  mac_array    ip/math/mac_array: PE_P pixels x PE_O output channels, output stationary: acc[p][o] +=
               a[p] * w[o] (INT8 x INT8, INT32), cleared to the bias
  npu_conv     o-tiles of PE_O channels: weights of the tile into PE_O lane memories (each lane one
               output channel's cin x k x k bytes, 256-bit words, read at the same index by all lanes),
               bias / M / S of the tile; per output row the cin x k input rows into the row buffer; per
               strip of PE_P output pixels: acc = bias, for c, dy, dx: one MAC clock; requantisation
               q = clamp((acc * M + 2^(S-1)) >> S, -128, 127) (64-bit product), optional LUT; the strip
               written per output channel (PE_P contiguous bytes)
  npu_pool     MAXPOOL with the row buffer and window (padding never wins), 64 lanes
  npu_elt      ADD (32 lanes: (a * MA + b * MB + 2^(S-1)) >> S, 64-bit, clamped), UPSAMPLE x2 (row
               duplication), COPY
  npu_input    INPUT: per output row two frame rows (RGB888) buffered, bilinear as the model's
               bilinear() (8-bit weights, centre-aligned, (sum + 2^15) >> 16), >> 1, the letterbox with
               PAD around the picture; three plane rows written per output row
  npu_decode   per anchor row: the class rows (NC x w) streamed into best / class (first maximum), the
               box rows (4 REG x w) buffered; each anchor reaching THRESH: per side max, exp LUT
               weights, expectation ((sum e r) << 4) / sum e (sequential divider), the corners mapped
               to frame pixels, one 16-byte candidate (up to CAND_MAX), in anchor order
  npu_nms      candidates on chip; counting sort by score (stable: equal scores in index order);
               greedy suppression (same / other class IoU, same-class containment, 64-bit products);
               the kept ones ranked by (area, score, index) and the first DET_MAX written
  npu_fw       frame writer: the AXI4-Stream RGB888 frames (after vision_system) packed into DDR at
               FRAME_ADDR, FRAME_STRIDE per line; STATUS[1]; AUTO starts a run after a frame
```

## Contract (where the model's arithmetic needs a bound)

- CONV accumulator: INT32 (the model sums in int64; the compiler keeps |acc| < 2^26). M, S: int32 per
  channel, 1 <= S <= 62. ADD: MA, MB as unsigned 32-bit words (as the model reads them), 1 <= S <= 62.
- A layer must fit the buffers (row buffer RB_BYTES, weight lanes WL_BYTES, candidates CAND_MAX);
  otherwise the run stops with the error flag (the model has no such limit: none of the compiled
  programs exceeds them).

## Verification

Per engine a cocotb test against the model's operation (random tensors and parameters in a Python AXI
memory, then with ddr_ctrl / ddr_mem), small parameter sets (PE 8 x 8) and the full 64 x 64; then
whole programs on small inputs (detections equal), then a full frame in Verilator (sign-off).

## System-level comparison (decided 2026-10-26)

The system model schedules the NPU's "results ready" event from the model's clock estimate; the RTL's
timing differs. The system test therefore holds the input: the camera sends each frame only after the
firmware has committed the previous frame's result (trk_frames), in the SV testbench as in pysim, so no
frame arrives during a run and both process the same frames. Held equal: the UART transcript (time stamps
aside, up to the last tracker frame), the output frames outside the clock text, and every run's detection
list in DDR word for word (+PYSIM_DETS). The network is the small system-test detector of
scripts/make_tiny_model.py (YOLOv8 structure, width 1/16, 5 classes, 128 x 128: every operation, about
72 k clocks a run), since the full detector takes far too long in an event simulator; the RTL's equality
with the model on each operation is shown by tb/python/npu_ops_tb.py. A free-running throughput report
(pysim given the NPU's run length, frames skipped as the RTL does) is a possible later addition.
