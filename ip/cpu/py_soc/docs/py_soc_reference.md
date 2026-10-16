<!-- Industry reference check of py_soc: copied into docs/py_soc_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - py_soc (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
//   [2] Python Software Foundation, "dis - Disassembler for Python bytecode",
//   https://docs.python.org/3/library/dis.html (CPython stack machine; bytecode is a CPython
//   detail that changes between versions)
// Published algorithm / equations:
//   SoC integration: one AXI4-Lite master, an address decoder with a DECERR default slave,
//   memory-mapped peripherals with OKAY / SLVERR responses (see each peripheral's reference).
// Comparison with this IP (section 6):
//   Matches: AXI4-Lite crossbar with DECERR for unmapped addresses, peripheral references as
//   listed in their own prompts. CPU differences: see py_core (TODO REF-PY_CORE-1 / -2).
// Result: in line with the reference; no TODO.
```
