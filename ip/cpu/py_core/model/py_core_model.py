"""py_core instruction-set simulator (Python model of ip/cpu/py_core/src/py_core.sv).

Executes the bytecode pyc.py writes (<out>.code.hex, <out>.const.hex) exactly as the hardware does:
tagged 34-bit values (small ints with bit 0 = 1, None / False / True as immediates), the opcode map of
py_core_pkg.sv, the trap causes, one level of interrupts (entry at an instruction boundary when the
level input is high, interrupts are enabled, a vector is set, no handler runs and a frame is free) and
the same stack / frame / local / global limits (RETURN_FROM_IRQ with fewer operands than at entry is
TRAP_STACK; code addresses, operand bytes included, wrap at 2**CODE_AW). mem32 loads and stores go to a
bus object (read(addr) -> (data, ok), write(addr, data) -> ok); an error answer is TRAP_BUS.

Clock cycles follow the core's state machine: fetch 1, opcode 1, one per operand byte, execute 1,
LOAD_CONST + 1, and a mem32 access + the bus latency (bus.latency, cycles; the access acts at the end), or
with bus.timing(addr, write) -> (effect, response): the core raises VALID 3 clocks after the instruction
starts (clock V), the access acts (bus.read / bus.write) in V + effect and the next instruction starts the
clock after the response handshake in V + response (py_soc: py_axil_xbar_model). py_core v2 (py_core.sv 2.0.0,
PyCore.v2()): WAIT_IRQ 0x3E stops the core until its interrupt input is high, whether interrupts are
enabled or not (the model jumps from one hardware event to the next until then); BINARY_MUL 0x17,
BINARY_FLOORDIV 0x1E, BINARY_MOD 0x1F (Python semantics, a zero divisor traps with cause 9; 2 and 32 extra
clocks); 256 globals, 32 locals and frames, a 64-word stack. The simulator calls `tick(cycles)` on the bus
after every instruction so the hardware models advance in step. tb/python compares this model with the RTL
instruction for instruction and clock for clock.
"""

# value tags
NONE, FALSE, TRUE = 0x2, 0x6, 0xA
VW = 34
MASK = (1 << VW) - 1
SMALL_MIN, SMALL_MAX = -(1 << 32), (1 << 32) - 1

OP = dict(NOP=0x00, LOAD_SMALL=0x01, LOAD_CONST=0x02, LOAD_FAST=0x03, STORE_FAST=0x04, POP_TOP=0x05,
          DUP_TOP=0x06, LOAD_NONE=0x07, LOAD_GLOBAL=0x08, STORE_GLOBAL=0x09, LOAD_TRUE=0x0A, LOAD_FALSE=0x0B,
          BINARY_ADD=0x10, BINARY_SUB=0x11, BINARY_AND=0x12, BINARY_OR=0x13, BINARY_XOR=0x14,
          BINARY_LSHIFT=0x15, BINARY_RSHIFT=0x16, COMPARE_LT=0x18, COMPARE_EQ=0x19, COMPARE_NE=0x1A,
          COMPARE_GT=0x1B, COMPARE_LE=0x1C, COMPARE_GE=0x1D, JUMP=0x20, POP_JUMP_IF_FALSE=0x21,
          POP_JUMP_IF_TRUE=0x22, MEM32_LOAD=0x30, MEM32_STORE=0x31, SET_IRQ_VECTOR=0x38, IRQ_ENABLE=0x39,
          IRQ_DISABLE=0x3A, RETURN_FROM_IRQ=0x3B, CALL=0x3C, RETURN=0x3D, WAIT_IRQ=0x3E, RETURN_VALUE=0x3F,
          BINARY_MUL=0x17, BINARY_FLOORDIV=0x1E, BINARY_MOD=0x1F)                  # the last three: py_core v2
NARGS = {OP[k]: 1 for k in ("LOAD_SMALL", "LOAD_CONST", "LOAD_FAST", "STORE_FAST", "LOAD_GLOBAL", "STORE_GLOBAL")}
NARGS.update({OP[k]: 2 for k in ("JUMP", "POP_JUMP_IF_FALSE", "POP_JUMP_IF_TRUE", "SET_IRQ_VECTOR", "CALL")})

TRAPS = {1: "ILLEGAL", 2: "TYPE", 3: "OVERFLOW", 4: "STACK", 5: "BUS", 6: "INDEX", 7: "IRQ_STATE", 8: "FRAME",
         9: "DIV0", 15: "WAIT_FOREVER"}      # 9: py_core v2 zero divisor; 15: model only, WAIT_IRQ with no
                                               # hardware event left to wake it


class Trap(Exception):
    """The core stopped (trap_o): cause number, pc and opcode of the instruction."""

    def __init__(self, cause, pc, op):
        super().__init__(f"TRAP_{TRAPS.get(cause, cause)} at pc 0x{pc:04X} (opcode 0x{op:02X})")
        self.cause, self.pc, self.op = cause, pc, op


def small(v):
    """Tagged word of a small int."""
    return ((v << 1) | 1) & MASK


def is_small(t):
    return t & 1


def value(t):
    """Signed value of a small-int tagged word."""
    v = t >> 1
    return v - (1 << 33) if v & (1 << 32) else v


def load_hex(path):
    """Words of a $readmemh file (one per line, '//' comments and '@' addresses ignored)."""
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("//")[0].strip()
            if line and not line.startswith("@"):
                out.append(int(line, 16))
    return out


class PyCore:
    """The core. bus: read(addr) -> (data32, ok), write(addr, data32) -> ok, tick(cycles), irq() -> bool,
    latency (cycles per access) or timing(addr, write) -> (effect, response) clocks from VALID."""

    @classmethod
    def v2(cls, code, consts, bus, code_aw=15):
        """py_core v2: 64-word stack, 32 frames, 32 locals, 256 globals."""
        return cls(code, consts, bus, stack_depth=64, n_frames=32, n_locals=32, n_globals=256, code_aw=code_aw)

    def __init__(self, code, consts, bus, stack_depth=32, n_frames=16, n_locals=16, n_globals=32, code_aw=15):
        size = 1 << code_aw
        if len(code) > size:
            raise ValueError(f"py_core: {len(code)} code bytes do not fit CODE_AW = {code_aw}")
        full = bytes(code) + bytes(size - len(code))
        self.code = full + full[:3]                                  # operand bytes past the end wrap to 0
        self.consts = list(consts) + [0] * (256 - len(consts))
        self.bus = bus
        self.SD, self.NF, self.NL, self.NG = stack_depth, n_frames, n_locals, n_globals
        self.code_mask = (1 << code_aw) - 1
        self.reset()

    def reset(self):
        self.pc = 0
        self.stk = []
        self.locals = [NONE] * (self.NF * self.NL)
        self.rstk = [0] * self.NF
        self.fp = 0
        self.globals = [NONE] * self.NG
        self.ie = self.in_irq = self.vec_set = False
        self.irq_vec = 0
        self.saved_sp = 0
        self.irq_fp = 0
        self.done = False
        self.result = NONE
        self.cycles = 0
        self.instructions = 0

    def global_value(self, idx):
        """Value of global idx (int, True / False / None)."""
        t = self.globals[idx]
        if is_small(t):
            return value(t)
        return {NONE: None, FALSE: False, TRUE: True}.get(t, t)

    def _trap(self, cause, ipc, op):
        self.pc = ipc
        raise Trap(cause, ipc, op)

    def run(self, max_instructions=None, until=None, check_every=256):
        """Execute until RETURN_VALUE (done), a trap (raises Trap), max_instructions, or until() is true
        (checked every check_every instructions, and at every hardware event while WAIT_IRQ sleeps: the
        testbench must see the program's state before the core wakes).

        Time: the cycles of each instruction are accumulated and handed to the bus (bus.tick) at every
        bus access and whenever the next hardware event is due (bus.budget(): cycles until then), so the
        hardware models see the same time as with a tick per instruction. Interrupts are sampled at
        instruction boundaries; the level can only change at a bus access or a hardware event, so it is
        re-read after those."""
        code, consts, bus = self.code, self.consts, self.bus
        timing = getattr(bus, "timing", None)
        stk, loc, glb = self.stk, self.locals, self.globals
        cmask, NL, NG, SD = self.code_mask, self.NL, self.NG, self.SD
        acc = 0
        budget = bus.budget()
        irq_now = bus.irq()
        n = 0
        limit = max_instructions if max_instructions is not None else -1
        next_check = check_every
        while not self.done:
            if n == limit:
                break
            if n >= next_check:
                next_check = n + check_every
                if until is not None:
                    if acc:
                        bus.tick(acc)
                        self.cycles += acc
                        acc = 0
                        budget = bus.budget()
                        irq_now = bus.irq()
                    if until():
                        break
            if irq_now and self.ie and self.vec_set and not self.in_irq and self.fp != self.NF - 1:
                self.rstk[self.fp] = self.pc
                self.saved_sp = len(stk)
                self.in_irq = True
                self.fp += 1
                self.irq_fp = self.fp
                self.pc = self.irq_vec
                acc += 1
            ipc = self.pc
            op = code[ipc]
            n += 1
            if op == 0x03:                                                     # LOAD_FAST
                arg = code[ipc + 1]
                self.pc = ipc + 2
                if len(stk) == SD:
                    self._trap(4, ipc, op)
                if arg >= NL:
                    self._trap(6, ipc, op)
                stk.append(loc[self.fp * NL + arg])
                acc += 4
            elif op == 0x08:                                                   # LOAD_GLOBAL
                arg = code[ipc + 1]
                self.pc = ipc + 2
                if len(stk) == SD:
                    self._trap(4, ipc, op)
                if arg >= NG:
                    self._trap(6, ipc, op)
                stk.append(glb[arg])
                acc += 4
            elif op == 0x01:                                                   # LOAD_SMALL
                arg = code[ipc + 1]
                self.pc = ipc + 2
                if len(stk) == SD:
                    self._trap(4, ipc, op)
                stk.append(((arg - 256 if arg & 0x80 else arg) << 1 | 1) & MASK)
                acc += 4
            elif op == 0x02:                                                   # LOAD_CONST
                arg = code[ipc + 1]
                self.pc = ipc + 2
                if len(stk) == SD:
                    self._trap(4, ipc, op)
                stk.append(consts[arg])
                acc += 5
            elif op == 0x04 or op == 0x09:                                     # STORE_FAST / STORE_GLOBAL
                arg = code[ipc + 1]
                self.pc = ipc + 2
                if not stk:
                    self._trap(4, ipc, op)
                if op == 0x04:
                    if arg >= NL:
                        self._trap(6, ipc, op)
                    loc[self.fp * NL + arg] = stk.pop()
                else:
                    if arg >= NG:
                        self._trap(6, ipc, op)
                    glb[arg] = stk.pop()
                acc += 4
            elif 0x10 <= op <= 0x1F:                                           # binary ops
                self.pc = ipc + 1
                acc += 3
                if len(stk) < 2:
                    self._trap(4, ipc, op)
                tb, ta = stk[-1], stk[-2]
                if not (tb & ta & 1):
                    self._trap(2, ipc, op)
                a = ta >> 1
                if a & 0x100000000:
                    a -= 0x200000000
                b = tb >> 1
                if b & 0x100000000:
                    b -= 0x200000000
                if 0x18 <= op <= 0x1D:
                    if op == 0x18:
                        r = a < b
                    elif op == 0x19:
                        r = a == b
                    elif op == 0x1A:
                        r = a != b
                    elif op == 0x1B:
                        r = a > b
                    elif op == 0x1C:
                        r = a <= b
                    else:
                        r = a >= b
                    stk.pop()
                    stk[-1] = TRUE if r else FALSE
                else:
                    if op == 0x10:
                        r = a + b
                    elif op == 0x11:
                        r = a - b
                    elif op == 0x12:
                        r = a & b
                    elif op == 0x13:
                        r = a | b
                    elif op == 0x14:
                        r = a ^ b
                    elif op >= 0x17:                                           # py_core v2: * // %
                        if op == 0x17:
                            r = a * b
                            acc += 2
                        else:
                            if b == 0:
                                self._trap(9, ipc, op)
                            r = a // b if op == 0x1E else a % b
                            acc += 32                                          # iterative divider
                    else:
                        if b < 0:
                            self._trap(3, ipc, op)
                        if op == 0x15:
                            if b > 32:
                                self._trap(3, ipc, op)
                            r = a << b
                        else:
                            r = a >> (b if b < 33 else 33)
                    if r < SMALL_MIN or r > SMALL_MAX:
                        self._trap(3, ipc, op)
                    stk.pop()
                    stk[-1] = (r << 1 | 1) & MASK
            elif op == 0x21 or op == 0x22:                                     # POP_JUMP_IF_FALSE / TRUE
                arg = code[ipc + 1] | (code[ipc + 2] << 8)
                self.pc = ipc + 3
                acc += 5
                if not stk:
                    self._trap(4, ipc, op)
                t = stk[-1]
                if t & 1:
                    truthy = (t >> 1) != 0
                elif t == TRUE or t == FALSE or t == NONE:
                    truthy = t == TRUE
                else:
                    self._trap(2, ipc, op)
                stk.pop()
                if truthy == (op == 0x22):
                    self.pc = arg & cmask
            elif op == 0x20:                                                   # JUMP
                self.pc = (code[ipc + 1] | (code[ipc + 2] << 8)) & cmask
                acc += 5
            elif op == 0x3C:                                                   # CALL
                arg = code[ipc + 1] | (code[ipc + 2] << 8)
                acc += 5
                if self.fp == self.NF - 1:
                    self._trap(4, ipc, op)
                self.rstk[self.fp] = ipc + 3
                self.fp += 1
                self.pc = arg & cmask
            elif op == 0x3D:                                                   # RETURN
                acc += 3
                if self.fp == 0 or (self.in_irq and self.fp == self.irq_fp):
                    self._trap(8, ipc, op)
                self.pc = self.rstk[self.fp - 1]
                self.fp -= 1
            elif op == 0x30 or op == 0x31:                                     # MEM32_LOAD / STORE
                self.pc = ipc + 1
                if op == 0x31:
                    if len(stk) < 2:
                        self._trap(4, ipc, op)
                    tv, ta = stk[-1], stk[-2]
                    if not (tv & ta & 1):
                        self._trap(2, ipc, op)
                    a, v = value(ta), value(tv)
                    if not (0 <= a <= 0xFFFFFFFF and -0x80000000 <= v <= 0xFFFFFFFF):
                        self._trap(3, ipc, op)
                else:
                    if not stk:
                        self._trap(4, ipc, op)
                    ta = stk[-1]
                    if not ta & 1:
                        self._trap(2, ipc, op)
                    a = value(ta)
                    if not 0 <= a <= 0xFFFFFFFF:
                        self._trap(3, ipc, op)
                if timing is None:                                             # acts at the end
                    pre, post = 3 + bus.latency, 0
                else:                                                          # VALID at + 3
                    eff, resp = timing(a, op == 0x31)
                    pre, post = 3 + eff, resp + 1 - eff
                acc += pre
                bus.tick(acc)
                self.cycles += acc
                acc = 0
                if op == 0x31:
                    if not bus.write(a, v & 0xFFFFFFFF):
                        self._trap(5, ipc, op)
                    del stk[-2:]
                else:
                    d, ok = bus.read(a)
                    if not ok:
                        self._trap(5, ipc, op)
                    stk[-1] = small(d & 0xFFFFFFFF)
                if post:                                                       # to the next instruction
                    bus.tick(post)
                    self.cycles += post
                budget = bus.budget()
                irq_now = bus.irq()
            elif op == 0x05:                                                   # POP_TOP
                self.pc = ipc + 1
                acc += 3
                if not stk:
                    self._trap(4, ipc, op)
                stk.pop()
            elif op == 0x06:                                                   # DUP_TOP
                self.pc = ipc + 1
                acc += 3
                if not stk or len(stk) == SD:
                    self._trap(4, ipc, op)
                stk.append(stk[-1])
            elif op == 0x07 or op == 0x0A or op == 0x0B:                       # LOAD_NONE / TRUE / FALSE
                self.pc = ipc + 1
                acc += 3
                if len(stk) == SD:
                    self._trap(4, ipc, op)
                stk.append(NONE if op == 0x07 else (TRUE if op == 0x0A else FALSE))
            elif op == 0x38:                                                   # SET_IRQ_VECTOR
                self.irq_vec = (code[ipc + 1] | (code[ipc + 2] << 8)) & cmask
                self.vec_set = True
                self.pc = ipc + 3
                acc += 5
            elif op == 0x39 or op == 0x3A:                                     # IRQ_ENABLE / DISABLE
                self.ie = op == 0x39
                self.pc = ipc + 1
                acc += 3
            elif op == 0x3B:                                                   # RETURN_FROM_IRQ
                acc += 3
                if not self.in_irq or self.fp != self.irq_fp:
                    self._trap(7, ipc, op)
                if len(stk) < self.saved_sp:                                   # popped below the entry depth
                    self._trap(4, ipc, op)
                self.pc = self.rstk[self.fp - 1]
                self.fp -= 1
                del stk[self.saved_sp:]
                self.in_irq = False
            elif op == 0x3E:                                                   # WAIT_IRQ
                self.pc = ipc + 1                                              # sleep until irq_i is high
                acc += 3
                bus.tick(acc)
                self.cycles += acc
                acc = 0
                while not bus.irq():
                    if until is not None and until():                          # the testbench acts on what
                        break                                                  # the program did so far
                    b = bus.budget()
                    if b >= 1 << 62:
                        self._trap(15, ipc, op)
                    bus.tick(b)                                                # to the next hardware event
                    self.cycles += b
                if not bus.irq():                                              # left for the testbench: the
                    self.pc = ipc                                              # WAIT_IRQ resumes at the next
                    break                                                      # run()
                budget = bus.budget()
                irq_now = True
            elif op == 0x3F:                                                   # RETURN_VALUE
                self.pc = ipc + 1
                acc += 3
                if not stk:
                    self._trap(4, ipc, op)
                self.result = stk.pop()
                self.done = True
            elif op == 0x00:
                self.pc = ipc + 1
                acc += 3
            else:
                self.pc = ipc + 1
                self._trap(1, ipc, op)
            self.pc &= cmask
            if acc >= budget:                                                  # a hardware event is due
                bus.tick(acc)
                self.cycles += acc
                acc = 0
                budget = bus.budget()
                irq_now = bus.irq()
        if acc:
            bus.tick(acc)
            self.cycles += acc
        self.instructions += n
