<!-- Industry reference check of py_core: copied into docs/py_core_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - py_core (2026-10-16)
// Sources:
//   [1] Python Software Foundation, "dis - Disassembler for Python bytecode",
//   https://docs.python.org/3/library/dis.html (CPython stack machine; bytecode is a CPython
//   detail that changes between versions)
// Published algorithm / equations:
//   CPython executes bytecode on a stack machine (LOAD_FAST / STORE_FAST locals, LOAD_CONST,
//   BINARY_OP, COMPARE_OP, jumps, CALL / RETURN_VALUE); the bytecode format is a CPython
//   implementation detail that changes between Python versions.
// Comparison with this IP (section 6):
//   Matches the execution model: operand stack, per-frame locals, globals, constant pool, call
//   / return with a return stack, traps for what the fast path cannot do (heap objects,
//   bigints, RecursionError on too deep calls). Differs: the opcode set is the library's own
//   (py_core_pkg), not CPython bytecode of a given Python version, and ints are 33-bit (CPython
//   ints are unbounded; overflow must trap).
// TODO(REF-PY_CORE-1) [LOW] Opcode set is not CPython bytecode. Prompt: in ip/cpu/py_core,
//   document in the py_core_pkg header which CPython version's dis opcodes each py_core opcode
//   corresponds to (name, stack effect, argument), and state in the py_core.sv header that the
//   compiler front end translates CPython bytecode of that version; add a testbench test that
//   runs a program compiled from Python source through that translation.
// TODO(REF-PY_CORE-2) [LOW] Small-int overflow. Prompt: in ip/cpu/py_core/src/py_core.sv, make
//   every arithmetic opcode whose exact result does not fit 33 bits raise the bigint trap
//   (CPython semantics: no wrap-around); add a test for ADD / MUL / LSHIFT overflow.
```
