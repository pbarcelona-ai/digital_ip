<!-- Industry reference check of intc: copied into docs/intc_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - intc (2026-10-16)
// Sources:
//   [1] RISC-V, "Platform-Level Interrupt Controller Specification" v1.0.0,
//   https://github.com/riscv/riscv-plic-spec - priorities, threshold, claim / complete
// Published algorithm / equations:
//   RISC-V PLIC: per-source priority, per-target threshold, a claim read that returns the
//   highest-priority pending ID (0 = none) and marks it in service, a complete write that re-
//   enables it; gateways turn edge / level sources into requests.
// Comparison with this IP (section 6):
//   Partly matches: per-source enable, edge or level, polarity, software set, edge sources
//   latched and cleared by W1C, a vector register (id + valid). Differs from the PLIC model:
//   fixed lowest-index priority (no programmable priorities or threshold) and no claim /
//   complete (software clears edge pending bits itself; a level source stays pending until the
//   device drops it).
// TODO(REF-INTC-1) [LOW] Priority model. Prompt: in ip/peripherals/intc, either document in the
//   intc.sv header that the controller deliberately uses fixed lowest-index priority without
//   claim / complete (and why: one CPU, small NUM_IRQ), or add PRIORITY[i] (3 bits) and
//   THRESHOLD registers to intc_regs.json, select the highest priority (lowest index on a tie)
//   above THRESHOLD in the vector encoder, regenerate the register files with regmap_gen.py and
//   add tests for priority order and threshold masking.
```
