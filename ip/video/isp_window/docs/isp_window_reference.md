<!-- Industry reference check of isp_window: copied into docs/isp_window_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_window (2026-10-16)
// Sources:
//   [1] D. G. Bailey, "Design for Embedded Image Processing on FPGAs", Wiley-IEEE Press 2011
//   (2nd ed. 2023), ISBN 978-0-470-82849-6,
//   https://www.oreilly.com/library/view/-/9780470828496/ - stream processing, line buffers and
//   window caching, border handling, memory partitioning / banking
// Published algorithm / equations:
//   Streaming window filters (Bailey 2011 ch. 9): N-1 line buffers feed an N x N register
//   window, one output per clock; borders handled by replication (clamp) or mirroring;
//   reflect-101 (OpenCV BORDER_REFLECT_101) keeps the Bayer phase.
// Comparison with this IP (section 6):
//   Matches: N-1 line buffers, N x N window per pixel, clamp or reflect-101 borders, the extra
//   R rows / columns generated so a frame completes without the next one.
// Result: in line with the reference; no TODO.
```
