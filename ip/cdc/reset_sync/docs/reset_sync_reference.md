<!-- Industry reference check of reset_sync: copied into docs/reset_sync_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - reset_sync (2026-10-16)
// Sources:
//   [1] C. E. Cummings, D. Mills, S. Golson, "Asynchronous & Synchronous Reset Design
//   Techniques - Part Deux", SNUG Boston 2003,
//   https://docenti.ing.unipi.it/~a011468/didattica/SE/Ppt/CummingsSNUG2003Boston_Resets.pdf
// Published algorithm / equations:
//   Cummings / Mills / Golson 2003 section 7: reset synchroniser - the asynchronous reset
//   asserts the flops at once and is released synchronously through (at least) two flip-flops
//   with D tied to the inactive level, so every downstream flop leaves reset in the same clock;
//   no metastability issue on assertion (section 7.1).
// Comparison with this IP (section 6):
//   Matches: ASYNC_ASSERT = 1 is exactly that circuit (STAGES flops, async_reg). ASYNC_ASSERT =
//   0 (both edges synchronous, request through a two-flop synchroniser) is an extension for
//   designs that need a fully synchronous reset; the paper's circuit remains the default.
// Result: in line with the reference; no TODO.
```
