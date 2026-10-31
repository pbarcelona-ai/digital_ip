<!-- Industry reference check of ddr_frame_store: copied into docs/ddr_frame_store_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - ddr_frame_store (2026-10-26, version 2.0.0)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification" (IHI 0022, issue H), https://developer.arm.com/documentation/ihi0022
//   - A3.3.1 handshakes (a master must not wait for READY before VALID; AW and W may be presented
//   together), A3.4 INCR bursts, sizes, the 4 KB boundary rule, write strobes (A3.4.3)
//   [2] AMD/Xilinx, "AXI Video Direct Memory Access (VDMA)" PG020 - frame buffers in external memory,
//   multiple buffers (park / circular), the writer and reader on separate buffers (no tearing)
//   [3] J. L. Hennessy, D. A. Patterson, "Computer Architecture: A Quantitative Approach", 6th ed.,
//   appendix B - direct-mapped caches (index / tag / valid, line fills on a miss)
// Published algorithm / equations:
//   Double-buffered frame store: the writer fills one buffer while the reader reads the other, the
//   buffers swap at frame boundaries once the written frame is complete [2]; a read path with random
//   access uses a cache of lines (index = line mod sets, tag = line / sets) loaded by burst reads [3];
//   AXI writes as full-width words with byte strobes for the bytes written [1].
// Comparison with this IP (section 6):
//   Matches: two buffers chosen per access (the sequencer swaps them, as VDMA's circular mode with two
//   frames), writes gathered into full-width words with per-slot strobes, single-beat INCR writes,
//   line fills as one INCR burst of LINE_PIX / PPB beats aligned to the line, so a fill never
//   crosses 4 KB (LINE_PIX <= 1024, 4 KB of 32-bit slots, checked at elaboration),
//   AW and W presented together (legal [1]); direct-mapped cache with tags over the whole slot
//   address (both buffers share it without aliasing); the four taps of a request read in one clock
//   from four copies of the cache RAM (a multi-ported cache by replication [3]), so the reader keeps
//   up with a pixel per clock while its lines are cached.
//   Simplifications (deliberate): one outstanding read burst (the lookups wait for its line); the cache
//   does not snoop writes (the sequencer flushes it at a frame swap, documented); responses not
//   checked (the buffers are configured inside the memory); 32-bit pixel slots (no 24-bit packing:
//   simpler addressing at 33 % more memory, which the architecture study does not constrain).
// Result: in line with the reference; no TODO.
```
