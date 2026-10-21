"""cocotb tests of py_core against its golden model (ip/cpu/py_core/model/py_core_model.py).

Each test program runs on the model first, one instruction at a time, giving the expected start clock and
address of every instruction (an interrupt entry adds one clock before the handler's first instruction),
every completed bus read and write, and the end (RETURN_VALUE's result, or the trap's cause, address and
opcode). The RTL (py_core_cocotb_top) then runs the same program; at the middle of every clock the monitor
reads the core's state: an instruction started one clock before the core reaches S_OP. The testbench drives
irq_i from the same level schedule the model's bus reports (level of clock n during clock n).

Bus: with the wrapper's fixed slave timing (mem32 = 3 + 2 clocks, the model's bus.latency = 2) the
comparison is clock for clock; with random ready / response delays (rand_ready_i) it is instruction for
instruction (the same addresses, transactions and end), without interrupts.

Tests: pyc-compiled programs (programs/prog_v1.py, programs/prog_v2.py for the v2 configuration), then
constrained-random programs (every opcode, operands from a pool of corner values, forward branches, calls,
recursion to the depth limit, an interrupt handler, WAIT_IRQ, and deliberate faults for every trap cause).
Environment: PYCORE_CASE (v1 / v2: the parameters the runner built), PYCORE_N random programs per test
(default 150), PYCORE_SEED, PYCORE_CODE / PYCORE_CONST (the hex files the wrapper loads).
"""
from __future__ import annotations

import bisect
import collections
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP / "model"))
import py_core_model as pm                                     # noqa: E402

CASES = {
    "v1": dict(CODE_AW=13, CONST_AW=8, STACK_DEPTH=32, N_LOCALS=16, N_FRAMES=16, N_GLOBALS=32),
    "v2": dict(CODE_AW=15, CONST_AW=8, STACK_DEPTH=64, N_LOCALS=32, N_FRAMES=32, N_GLOBALS=256),
}
CASE = os.environ.get("PYCORE_CASE", "v1")
CFG = CASES[CASE]
N_RANDOM = int(os.environ.get("PYCORE_N", "150"))
SEED = int(os.environ.get("PYCORE_SEED", "20261020"))
S_OP = 2                                                       # py_core state_e: S_IDLE, S_FETCH, S_OP, ...
BAD_ADDR = 0xBAD0
LATENCY = 2                                                    # the wrapper's fixed slave timing
HORIZON = 1 << 20                                              # interrupt schedule length, clocks
OP = pm.OP
TRAP_NAMES = pm.TRAPS
STATS = collections.Counter()


# ======================================================================= the model's bus

class Bus:
    """The wrapper's slave as the model sees it: a 4096-word RAM (address bits [13:2]), an error at
    BAD_ADDR, and the interrupt level as a schedule of (clock, level) changes."""

    latency = LATENCY

    def __init__(self, sched):
        self.now = 0
        self.ram = {}
        self.times = [t for t, _ in sched]
        self.levels = [lv for _, lv in sched]
        self.writes, self.reads = [], []

    def level(self, t):
        k = bisect.bisect_right(self.times, t) - 1
        return self.levels[k] if k >= 0 else 0

    def tick(self, c):
        self.now += c

    def irq(self):
        return bool(self.level(self.now))

    def budget(self):
        k = bisect.bisect_right(self.times, self.now)
        return self.times[k] - self.now if k < len(self.times) else 1 << 62

    def read(self, a):
        if a == BAD_ADDR:
            return 0, False
        d = self.ram.get((a >> 2) & 4095, 0)
        self.reads.append((a, d))
        return d, True

    def write(self, a, d):
        if a == BAD_ADDR:
            return False
        self.ram[(a >> 2) & 4095] = d
        self.writes.append((a, d))
        return True


def run_model(code, consts, sched, max_instr=200_000):
    """(trace [(start clock, address)], writes, reads, end) of the program on the model."""
    bus = Bus(sched)
    core = pm.PyCore(code, consts, bus, stack_depth=CFG["STACK_DEPTH"], n_frames=CFG["N_FRAMES"],
                     n_locals=CFG["N_LOCALS"], n_globals=CFG["N_GLOBALS"], code_aw=CFG["CODE_AW"])
    trace, end = [], None
    while not core.done and len(trace) < max_instr:
        before = core.cycles
        take = (bus.level(before) and core.ie and core.vec_set and not core.in_irq and core.fp != core.NF - 1)
        trace.append((before + (1 if take else 0), core.irq_vec if take else core.pc))
        STATS["model_irq_entries"] += bool(take)
        STATS[f"op_{core.code[core.irq_vec if take else core.pc]:02X}"] += 1
        try:
            core.run(max_instructions=1)
        except pm.Trap as t:
            end = ("trap", t.cause, t.pc, t.op)
            break
    if end is None:
        end = ("done", core.result) if core.done else ("limit",)
    STATS[f"end_{TRAP_NAMES.get(end[1], 'done') if end[0] == 'trap' else end[0]}"] += 1
    return trace, bus.writes, bus.reads, end


# ======================================================================= the RTL

def write_hex(code, consts):
    """The memories' files, full length (the wrapper loads them over the previous program)."""
    code = list(code) + [0] * ((1 << CFG["CODE_AW"]) - len(code))
    consts = list(consts) + [0] * ((1 << CFG["CONST_AW"]) - len(consts))
    with open(os.environ["PYCORE_CODE"], "w", encoding="ascii") as fh:
        fh.write("".join(f"{b:02x}\n" for b in code))
    with open(os.environ["PYCORE_CONST"], "w", encoding="ascii") as fh:
        fh.write("".join(f"{c:09x}\n" for c in consts))


async def run_rtl(dut, code, consts, sched, rand_ready, max_cycles):
    """The same program on the RTL: (trace, writes, reads, end)."""
    write_hex(code, consts)
    bus = Bus(sched)
    dut.start_i.value = 0
    dut.resume_i.value = 0
    dut.resume_pc_i.value = 0
    dut.irq_i.value = 0
    dut.rand_ready_i.value = int(rand_ready)
    dut.rst_n.value = 0
    dut.load_i.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.load_i.value = 1
    await FallingEdge(dut.clk)
    dut.load_i.value = 0
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)
    dut.start_i.value = 1                                    # sampled at the next rising edge: clock 0 starts
    await RisingEdge(dut.clk)
    trace, writes, reads, end = [], [], [], None
    n = 0
    core = dut.u_core
    while n < max_cycles:
        await FallingEdge(dut.clk)                           # the middle of clock n
        dut.start_i.value = 0
        dut.irq_i.value = bus.level(n) if not rand_ready else 0
        if int(core.st.value) == S_OP:
            trace.append((n - 1, int(core.ipc.value)))
        if dut.wr_fire_o.value:
            writes.append((int(dut.wr_addr_o.value), int(dut.wr_data_o.value)))
        if dut.rd_fire_o.value:
            reads.append((int(dut.rd_addr_o.value), int(dut.rd_data_o.value)))
        if dut.trap_o.value:
            end = ("trap", int(dut.trap_cause_o.value), int(dut.trap_pc_o.value), int(dut.trap_op_o.value))
            break
        if dut.done_o.value:
            end = ("done", int(dut.result_o.value))
            break
        n += 1
    return trace, writes, reads, end or ("limit",)


async def compare(dut, name, code, consts, sched, rand_ready=False):
    """Model and RTL on one program; raises AssertionError with the first difference."""
    m_trace, m_w, m_r, m_end = run_model(code, consts, sched if not rand_ready else [(0, 0)])
    if m_end == ("limit",):
        raise AssertionError(f"{name}: the model did not finish (generator error)")
    max_cycles = (m_trace[-1][0] if m_trace else 0) * (8 if rand_ready else 1) + 2000
    r_trace, r_w, r_r, r_end = await run_rtl(dut, code, consts, sched, rand_ready, max_cycles)
    if rand_ready:                                           # instruction for instruction, without clocks
        m_seq, r_seq = [a for _, a in m_trace], [a for _, a in r_trace]
    else:
        m_seq, r_seq = m_trace, r_trace
    if m_seq != r_seq:
        k = next((i for i, (x, y) in enumerate(zip(m_seq, r_seq)) if x != y), min(len(m_seq), len(r_seq)))
        raise AssertionError(f"{name}: instruction {k} differs: model {m_seq[k:k + 3]} rtl {r_seq[k:k + 3]} "
                             f"(lengths {len(m_seq)} / {len(r_seq)})")
    assert m_w == r_w, f"{name}: writes differ: model {m_w[:8]} rtl {r_w[:8]}"
    assert m_r == r_r, f"{name}: reads differ: model {m_r[:8]} rtl {r_r[:8]}"
    assert m_end == r_end, f"{name}: end differs: model {m_end} rtl {r_end}"
    STATS["programs"] += 1
    STATS["instructions"] += len(m_trace)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await RisingEdge(dut.clk)


def pulses(rng, first, period, width_max, until=HORIZON):
    """An interrupt schedule: pulses of 1..width_max clocks every period clocks (jittered)."""
    sched, t = [(0, 0)], first
    while t < until:
        w = rng.randint(1, width_max)
        sched += [(t, 1), (t + w, 0)]
        t += w + rng.randint(period // 2, period)
    return sched


# ======================================================================= pyc programs

def pyc_program(src, core):
    tools = IP / "tools" / "pyc.py"
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "prog")
        subprocess.run([sys.executable, str(tools), str(src), "-o", out, "--core", str(core),
                        "--code-aw", str(CFG["CODE_AW"])], check=True, capture_output=True, text=True)
        return pm.load_hex(out + ".code.hex"), pm.load_hex(out + ".const.hex")


@cocotb.test()
async def test_pyc_programs(dut):
    """pyc-compiled programs: v1 (shifts, calls, interrupts) and, on the v2 configuration, * // %."""
    await start_clock(dut)
    rng = random.Random(SEED)
    progs = [("prog_v1", 1)] + ([("prog_v2", 2)] if CASE == "v2" else [])
    for name, core in progs:
        code, consts = pyc_program(Path(__file__).parent / "programs" / f"{name}.py", core)
        for k in range(3):                                   # three interrupt timings (wait_irq needs them:
            await compare(dut, f"{name}/{k}", code, consts,  # fixed slave timing only)
                          pulses(rng, rng.randint(50, 900), 1200, 6))
    dut._log.info("pyc programs: %s", dict(STATS))


# ======================================================================= random programs

CONST_POOL = [0, 1, -1, 2, -2, 3, 7, -7, 100, -100, 12345678, -12345678, (1 << 31) - 1, -(1 << 31), 1 << 31,
              (1 << 32) - 1, -(1 << 32), (1 << 16) + 3, 65535]
ADDRS = [0x100, 0x104, 0x200, 0x3FFC, 0x4000, 0xFFFC, BAD_ADDR]


class Gen:
    """A constrained-random program: main (ends with RETURN_VALUE), functions f0..fN (call only later
    ones, or themselves for a recursion to the depth limit; end with RETURN) and an interrupt handler
    (ends with RETURN_FROM_IRQ). Locals are read only where they are surely assigned in the frame."""

    def __init__(self, rng, irqs, faults):
        self.rng, self.irqs, self.faults = rng, irqs, faults
        self.consts = [pm.small(v) for v in CONST_POOL] + [pm.small(a) for a in ADDRS] + [0x2000, pm.NONE]
        self.c_val = list(range(len(CONST_POOL)))
        self.c_addr = list(range(len(CONST_POOL), len(CONST_POOL) + len(ADDRS)))
        self.c_heap = len(self.consts) - 2
        self.nfunc = rng.randint(0, 4)
        self.recursive = rng.random() < 0.1

    def value(self):
        """A constant-pool index: mostly small values, sometimes the 32-bit corner values."""
        return self.rng.choice(self.c_val[:11] if self.rng.random() < 0.75 else self.c_val)

    def address(self):
        """A constant-pool index of a mem32 address: the error address rarely."""
        return self.c_addr[-1] if self.rng.random() < 0.04 else self.rng.choice(self.c_addr[:-1])

    def block(self, kind, idx, n_ops):
        """Items of one block: ("op", byte), ("op1", byte, arg), ("op2", byte, label), ("label", name).
        A type stack ("i" small int, "o" other) keeps most operations valid; faults are injected on
        purpose (rarely), so programs run long and still reach every trap."""
        r, out = self.rng, []
        ts, assigned, pending = [], set(), []                # types on the stack; surely assigned locals
        assigned_t = {}                                      # the type stored in each assigned local
        nl, ng = CFG["N_LOCALS"], min(CFG["N_GLOBALS"], 64)

        def emit(items, pops, pushes=()):
            out.extend(items)
            del ts[len(ts) - min(pops, len(ts)):]
            ts.extend(pushes)

        def place(lab, snap):
            """A branch target: the fall-through path brought to the jump's stack depth first."""
            d = len(ts) - len(snap)
            emit([("op", OP["POP_TOP"])] * max(d, 0) + [("op1", OP["LOAD_SMALL"], 1)] * max(-d, 0), max(d, 0))
            out.append(("label", lab))
            ts[:] = snap

        for i in range(n_ops):
            for lab, snap in [p for p in pending if r.random() < 0.3]:
                pending.remove((lab, snap))
                place(lab, snap)
            x = r.random()
            if self.faults and x < 0.015:                     # a fault, on purpose
                f = r.choice(["illegal", "lidx", "gidx", "heap", "none", "pop", "rfi", "ret"])
                if f == "illegal":
                    emit([("op", r.choice([0x0C, 0x23, 0x32, 0x40, 0x7F, 0xFF]))], 0)
                elif f == "lidx" and nl < 256:
                    emit([("op1", OP["LOAD_FAST"], r.randint(nl, 255))], 0, "o")
                elif f == "gidx" and CFG["N_GLOBALS"] < 256:
                    emit([("op1", OP["STORE_GLOBAL"], r.randint(CFG["N_GLOBALS"], 255))], 1)
                elif f == "heap":
                    emit([("op1", OP["LOAD_CONST"], self.c_heap)], 0, "o")
                elif f == "none":
                    emit([("op", OP["LOAD_NONE"])], 0, "o")
                elif f == "rfi" and kind != "h":
                    emit([("op", OP["RETURN_FROM_IRQ"])], 0)      # outside a handler: TRAP_IRQ_STATE
                elif f == "ret" and kind == "m":
                    emit([("op", OP["RETURN"])], 0)               # no caller: TRAP_FRAME
                elif f == "pop":
                    emit([("op", OP["POP_TOP"])] * (len(ts) + 1), len(ts) + 1)
                continue
            full = len(ts) >= CFG["STACK_DEPTH"] - 4
            if ts and ts[-1] == "o":                         # a bool / None on top: branch on it or drop it
                if x < 0.6:
                    lab = f"{kind}{idx}_L{i}"
                    emit([("op2", r.choice([OP["POP_JUMP_IF_FALSE"], OP["POP_JUMP_IF_TRUE"]]), lab)], 1)
                    pending.append((lab, list(ts)))
                elif x < 0.8:
                    emit([("op1", OP["STORE_GLOBAL"], r.randrange(ng))], 1)
                else:
                    emit([("op", OP["POP_TOP"])], 1)
            elif len(ts) >= 2 and ts[-2:] == ["i", "i"] and (full or x < 0.32):   # binary / compare
                o = r.choice(range(0x10, 0x20))
                emit([("op", o)], 2, "o" if 0x18 <= o <= 0x1D else "i")
            elif full:
                emit([("op", OP["POP_TOP"])], 1)
            elif x < 0.55 or not ts:                         # push a value
                y = r.random()
                if y < 0.40:
                    emit([("op1", OP["LOAD_SMALL"], r.randint(0, 255))], 0, "i")
                elif y < 0.75:
                    emit([("op1", OP["LOAD_CONST"], self.value())], 0, "i")
                elif y < 0.85 and assigned:
                    li = r.choice(sorted(assigned))
                    emit([("op1", OP["LOAD_FAST"], li)], 0, assigned_t[li])
                elif y < 0.92 and ts:
                    emit([("op", OP["DUP_TOP"])], 0, ts[-1])
                elif y < 0.96:
                    emit([("op", r.choice([OP["LOAD_TRUE"], OP["LOAD_FALSE"]]))], 0, "o")
                else:
                    emit([("op1", OP["LOAD_GLOBAL"], r.randrange(ng))], 0, "o")   # may be None: types unknown
            elif x < 0.63:                                   # store to a local / global
                if r.random() < 0.7:
                    li = r.randrange(nl)
                    t = ts[-1]
                    emit([("op1", OP["STORE_FAST"], li)], 1)
                    if not pending:
                        assigned.add(li)
                        assigned_t[li] = t
                else:
                    emit([("op1", OP["STORE_GLOBAL"], r.randrange(ng))], 1)
            elif x < 0.71:                                   # mem32 store / load
                if r.random() < 0.55:
                    emit([("op1", OP["LOAD_CONST"], self.address()),
                          ("op1", OP["LOAD_SMALL"], r.randint(0, 255)), ("op", OP["MEM32_STORE"])], 0)
                else:
                    emit([("op1", OP["LOAD_CONST"], self.address()), ("op", OP["MEM32_LOAD"])], 0, "i")
            elif x < 0.74:
                lab = f"{kind}{idx}_J{i}"
                emit([("op2", OP["JUMP"], lab)], 0)
                pending.append((lab, list(ts)))
            elif x < 0.80 and (kind != "h" or self.nfunc):   # a call (functions push one value)
                lo = idx + 1 if kind == "f" else 0
                if kind == "f" and self.recursive and idx == self.nfunc - 1:
                    lo = idx                                 # recursion to the depth limit
                if lo < self.nfunc:
                    emit([("op2", OP["CALL"], f"f{r.randint(lo, self.nfunc - 1)}")], 0, "i")
            elif x < 0.84:
                emit([("op", OP["POP_TOP"])], 1)
            elif x < 0.87 and kind == "m":                   # interrupt control
                y = r.random()
                if y < 0.4 and self.irqs:
                    emit([("op2", OP["SET_IRQ_VECTOR"], "h0")], 0)
                elif y < 0.7:
                    emit([("op", OP["IRQ_ENABLE"])], 0)
                elif y < 0.85 and self.irqs:
                    emit([("op", OP["WAIT_IRQ"])], 0)
                else:
                    emit([("op", OP["IRQ_DISABLE"])], 0)
            else:
                emit([("op", OP["NOP"])], 0)
        for lab, snap in reversed(pending):
            place(lab, snap)
        if kind == "m":
            if self.irqs and r.random() < 0.7:
                out = [("op2", OP["SET_IRQ_VECTOR"], "h0"), ("op", OP["IRQ_ENABLE"])] + out
            out += [("op1", OP["LOAD_SMALL"], r.randint(0, 255)), ("op", OP["RETURN_VALUE"])]
        elif kind == "f":                                    # leave one value: the caller sees one push
            out += [("op", OP["POP_TOP"])] * len(ts) + [("op1", OP["LOAD_SMALL"], idx), ("op", OP["RETURN"])]
        else:                                                # the handler leaves the stack as it found it
            out += [("op", OP["POP_TOP"])] * len(ts) + [("op", OP["RETURN_FROM_IRQ"])]
        return out

    def program(self):
        r = self.rng
        blocks = [("m0", self.block("m", 0, r.randint(20, 90)))]
        blocks += [(f"f{i}", self.block("f", i, r.randint(5, 30))) for i in range(self.nfunc)]
        blocks += [("h0", self.block("h", 0, r.randint(3, 15)))]
        labels, code, fix = {}, bytearray(), []
        for name, items in blocks:
            labels[name] = len(code)
            for it in items:
                if it[0] == "label":
                    labels[it[1]] = len(code)
                elif it[0] == "op":
                    code.append(it[1])
                elif it[0] == "op1":
                    code += bytes([it[1], it[2] & 0xFF])
                else:
                    code.append(it[1])
                    fix.append((len(code), it[2]))
                    code += b"\0\0"
        for at, lab in fix:
            a = labels[lab] if isinstance(lab, str) else lab
            code[at], code[at + 1] = a & 0xFF, a >> 8
        return list(code), self.consts


async def random_programs(dut, rand_ready):
    await start_clock(dut)
    rng = random.Random(SEED + (1 if rand_ready else 0) + (100 if CASE == "v2" else 0))
    for k in range(N_RANDOM):
        g = Gen(rng, irqs=not rand_ready, faults=True)
        code, consts = g.program()
        sched = pulses(rng, rng.randint(5, 300), rng.randint(100, 600), 8) if not rand_ready else [(0, 0)]
        await compare(dut, f"random{'_bp' if rand_ready else ''}/{k}", code, consts, sched, rand_ready)
    dut._log.info("random programs (%s): %s", "backpressure" if rand_ready else "fixed timing", dict(STATS))


@cocotb.test()
async def test_random_fixed_timing(dut):
    """Constrained-random programs with interrupts, clock for clock against the model."""
    await random_programs(dut, rand_ready=False)


@cocotb.test()
async def test_random_backpressure(dut):
    """Constrained-random programs without interrupts, random AXI ready / response delays."""
    await random_programs(dut, rand_ready=True)


@cocotb.test()
async def test_coverage(dut):
    """Every opcode executed and every trap cause reached by the tests above (they run first)."""
    await start_clock(dut)
    ops = {int(k[3:], 16) for k in STATS if k.startswith("op_")}
    missing = sorted(set(OP.values()) - ops)
    assert not missing, f"opcodes never executed: {[hex(o) for o in missing]}"
    ends = {k[4:] for k in STATS if k.startswith("end_")}
    want = {"done", "ILLEGAL", "TYPE", "OVERFLOW", "STACK", "BUS", "INDEX", "IRQ_STATE", "FRAME", "DIV0"}
    assert want <= ends, f"ends never reached: {sorted(want - ends)}"
    assert STATS["model_irq_entries"] > 0, "no interrupt was taken"
    dut._log.info("coverage: %d programs, %d instructions, ends %s", STATS["programs"], STATS["instructions"],
                  sorted(ends))
