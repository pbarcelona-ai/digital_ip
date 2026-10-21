"""cocotb system test of py_soc against its model: py_soc_model Soc (the peripherals' models, the crossbar's
decode and timing: py_axil_xbar_model), py_boot_model and py_core_model PyCore, clock for clock.

Cases (PYSOC_CASE; the firmware compiled by run_python.py with pyc.py --core 2 --code-aw 15, PYSOC_FW its
output prefix, the flash image loaded by the wrapper from +FLASH):
  selftest  tb/programs/selftest.py, every peripheral (the SystemVerilog testbench's firmware): from the boot
            to the watchdog reset of its last stage; GPIO2 pins 0 and 31 rise 50 and 350 clocks after the
            firmware sets stage 2;
  bus       tb/programs/soc_bus.py: the EXT window, the data RAM, external edge interrupts with wait_irq()
            (ext_irq_i pulses from 100 clocks after stage 1, the last on two sources at once), the SYSCTL
            timer, then TRAP_BUS on an unmapped address.
The model runs first, on a board wired as py_soc_cocotb_top.sv's: the boot from flash (every bus access of
py_boot), then the core from the clock after done_o, one instruction at a time, until the watchdog reset,
the end of the program or PYSOC_MAX_CLOCKS; the stimulus times found in the model run go to the RTL as a
schedule. Clock 0 is the first clock after the system reset (u_soc.sys_rst_n high).
Compared: the clock done_o rises (and the loaded code / constants against the pyc output), the start clock
and address of every instruction (an interrupt entry starts one clock later, at the handler), every mem32
read (address, data) and write (address, data) of the core, the first clock of the watchdog reset, the end
(trap cause and address), the firmware's globals (the RTL's against the model's, and the expected results).
Environment: PYSOC_CASE, PYSOC_FW, PYSOC_MAX_CLOCKS (default 400000)."""
from __future__ import annotations

import collections
import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

IP = Path(__file__).resolve().parents[2]
LIB = IP.parents[1]
sys.path.insert(0, str(LIB / "shared" / "tb" / "python"))
from cocotb_lib import model_path                                 # noqa: E402

model_path(IP / "model", LIB / "cpu" / "py_core" / "model", LIB / "shared" / "model",
           *(LIB / p / "model" for p in ("peripherals/gpio", "peripherals/i2c_master", "peripherals/intc",
                                         "peripherals/spi_flash_ctrl", "peripherals/spi_master",
                                         "peripherals/uart", "timing/watchdog")))
import py_core_model as pm                                        # noqa: E402
from event_sim import Sim                                         # noqa: E402
from py_soc_model import Soc                                      # noqa: E402

CASES = {"selftest": {}, "bus": {}}
CASE = os.environ.get("PYSOC_CASE", "selftest")
FW = os.environ.get("PYSOC_FW", "")
MAX_CLOCKS = int(os.environ.get("PYSOC_MAX_CLOCKS", "400000"))
S_OP = 2                                                          # py_core state_e: S_IDLE, S_FETCH, S_OP, ...
CFG = dict(uart_baud=(2_000_000, 2_000_000), i2c_hz=(2_000_000, 2_000_000), spi_hz=(10_000_000, 10_000_000),
           gpio_loopback=(False, False, False), uart_cross=True, nclk=1, clk_en_rst=1, clkgen=False,
           ext_en=True, ddr_en=True, port_depth=16, boot_addr=0, flash_clkdiv=3, code_aw=15)


class I2cTarget:
    """i2c_bfm: 256 bytes; the first written byte is the pointer, reads are sequential from it."""

    def __init__(self, init=()):
        self.mem = bytearray(256)
        self.mem[:len(init)] = bytes(init)
        self.ptr = 0

    def write(self, data):
        if data:
            self.ptr = data[0]
            for b in data[1:]:
                self.mem[self.ptr] = b
                self.ptr = (self.ptr + 1) & 0xFF

    def read(self, n):
        out = []
        for _ in range(n):
            out.append(self.mem[self.ptr])
            self.ptr = (self.ptr + 1) & 0xFF
        return out


class Window:
    """The wrapper's behavioral AXI4-Lite memory: 256 words, index {offset[hi], offset[8:2]}."""

    def __init__(self, hi):
        self.hi, self.mem = hi, [0] * 256

    def _i(self, off):
        return (off >> self.hi & 1) << 7 | (off >> 2 & 0x7F)

    def read(self, off):
        return self.mem[self._i(off)], 0

    def write(self, off, d):
        self.mem[self._i(off)] = d & 0xFFFFFFFF
        return 0

    def word(self, off):
        return self.read(off)[0]

    def set_word(self, off, d):
        self.write(off, d)


class Board:
    """py_soc_cocotb_top's board: GPIO0 outputs on the GPIO0 and GPIO1 inputs, GPIO2 and ext_irq_i from
    schedules."""

    def __init__(self):
        self.soc = None
        self.g2 = [(0, 0)]                                        # (clock, GPIO2 levels)
        self.ext = [(0, 0)]                                       # (clock, ext_irq_i)
        self.i2c = ({0x50: I2cTarget()}, {0x51: I2cTarget([0x11, 0x22, 0x33, 0x44])})

    def gpio0_in(self, out, drive):
        return self.soc.gpio0.out

    def gpio1_in(self, out, drive):
        return self.soc.gpio0.out

    def gpio0_out(self, v):
        self.soc.gpio1.sample()                                   # the same clock on the GPIO1 inputs

    def gpio2_in(self, out, drive):
        return self.at(self.g2, self.soc.sim.now)

    @staticmethod
    def at(sched, n):
        v = 0
        for t, lv in sched:
            if t <= n:
                v = lv
        return v

    def stimulus(self, t):
        """The case's stimulus from clock t (the firmware reached its trigger stage then)."""
        soc = self.soc
        if CASE == "selftest":                                    # GPIO2 rising edges
            self.g2 += [(t + 50, 0x1), (t + 350, 0x8000_0001)]
            for c, _ in self.g2[1:]:
                soc.sim.at(c, soc.gpio2.sample)
        else:                                                     # ext_irq_i pulses, the last on two sources
            for k, (bits, width) in enumerate(((1, 3), (2, 3), (4, 3), (8, 3), (9, 4))):
                c = t + 100 + 400 * k
                self.ext += [(c, bits), (c + width, 0)]
            for c, _ in self.ext[1:]:
                soc.sim.at(c, lambda: None)                       # a model event: the sources re-evaluated

    def i2c_devices(self, n):
        return self.i2c[n]


def syms(prefix):
    out = {}
    with open(prefix + "_syms.svh", encoding="utf-8") as fh:
        for ln in fh:
            p = ln.split()
            if len(p) >= 5 and p[2].startswith("G_"):
                out[p[2][2:]] = int(p[4].rstrip(";"))
    return out


class BusLog:
    """The soc as the core's bus, logging its reads and writes."""

    def __init__(self, soc):
        self.soc, self.reads, self.writes = soc, [], []
        for k in ("tick", "irq", "budget", "timing"):
            setattr(self, k, getattr(soc, k))

    def read(self, a):
        d, ok = self.soc.read(a)
        if ok:
            self.reads.append((a, d))
        return d, ok

    def write(self, a, d):
        ok = self.soc.write(a, d)
        if ok:
            self.writes.append((a, d))
        return ok


def run_model(image, code, consts, g):
    """The boot and the program on the model: dict of the comparison items."""
    sim = Sim(100_000_000)
    board = Board()
    soc = Soc(sim, image, board, cfg=CFG)
    board.soc = soc
    soc.ext, soc.ddr = Window(15), Window(25)
    for i in range(4):
        soc.set_ext_irq(i, lambda i=i: board.at(board.ext, sim.now) >> i & 1)
    wdt_at = []
    soc.wdt.on_reset = wdt_at.append
    assert soc.boot(), f"model boot failed: code {soc.boot_ldr.err_code}"
    boot_at = soc.boot_ldr.at
    assert soc.boot_code == bytes(code), "boot: code differs from the pyc output"
    assert soc.boot_consts == list(consts), "boot: constants differ from the pyc output"
    sim.advance(1)                                                # the core starts in the clock after done_o
    t0 = sim.now
    bus = BusLog(soc)
    core = pm.PyCore.v2(soc.boot_code, soc.boot_consts, bus, code_aw=15)
    trace, end, stage2 = [], None, None
    irqs = [(0, 0)]                                               # (clock, interrupt sources) changes
    src = lambda: soc.irq_in(sim.now)                             # noqa: E731
    while sim.now < MAX_CLOCKS:
        if wdt_at and sim.now >= wdt_at[0]:
            break
        v = src()
        if v != irqs[-1][1]:
            irqs.append((sim.now, v))
        take = soc.irq() and core.ie and core.vec_set and not core.in_irq and core.fp != core.NF - 1
        trace.append((sim.now + int(take), core.irq_vec if take else core.pc))
        try:
            core.run(max_instructions=1)
        except pm.Trap as t:
            end = ("trap", t.cause, t.pc)
            break
        if core.done:
            end = ("done", core.result)
            break
        if stage2 is None and core.global_value(g["stage"]) == TRIGGER[CASE]:
            stage2 = sim.now
            board.stimulus(stage2)
    w = wdt_at[0] if wdt_at else None
    trace = [x for x in trace if w is None or x[0] < w]           # instructions started before the reset
    glb = {k: core.global_value(i) for k, i in g.items()}
    return dict(boot_at=boot_at, t0=t0, trace=trace, reads=bus.reads, writes=bus.writes, wdt=w, end=end,
                g2=board.g2, ext=board.ext, irqs=irqs, globals=glb, i2c0=bytes(board.i2c[0][0x50].mem), code=core.code)


async def run_rtl(dut, g2, ext, limit):
    """The RTL from reset until the watchdog reset (or limit clocks after the system reset)."""
    dut.rst_n.value = 0
    dut.gpio2_i.value = 0
    dut.ext_irq_i.value = 0
    for _ in range(5):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    soc, core = dut.u_soc, dut.u_soc.u_core
    while not int(soc.sys_rst_n.value):
        await FallingEdge(dut.clk)
    trace, reads, writes, irqs = [], [], [], [(0, 0)]
    boot_at = wdt = end = None
    sched = sorted([(t, "gpio2_i", v) for t, v in g2[1:]] + [(t, "ext_irq_i", v) for t, v in ext[1:]])
    m = soc.u_core_m_axil                                         # the core's bus (py_soc's interface)
    n = 0
    while n < limit:                                              # the middle of clock n
        while sched and sched[0][0] <= n:
            _, sig, v = sched.pop(0)
            getattr(dut, sig).value = v
        await Timer(1, unit="ns")
        if boot_at is None and int(dut.boot_done_o.value):
            boot_at = n
        if int(core.st.value) == S_OP:
            trace.append((n - 1, int(core.ipc.value)))
        v = int(soc.irq_src.value)
        if v != irqs[-1][1]:
            irqs.append((n, v))
        if int(m.rvalid.value) and int(m.rready.value) and int(m.rresp.value) == 0:
            reads.append((int(m.araddr.value), int(m.rdata.value)))
        if int(m.bvalid.value) and int(m.bready.value) and int(m.bresp.value) == 0:
            writes.append((int(m.awaddr.value), int(m.wdata.value)))
        if int(dut.wdt_reset_o.value):
            wdt = n
            break
        if int(dut.trap_o.value):
            end = ("trap", int(dut.trap_cause_o.value), int(core.trap_pc_o.value))
            break
        if int(dut.done_o.value):
            end = ("done", int(core.result_o.value))
            break
        await FallingEdge(dut.clk)
        n += 1
    return dict(boot_at=boot_at, trace=trace, reads=reads, writes=writes, wdt=wdt, end=end, clocks=n, irqs=irqs,
                boot=(int(dut.boot_err_o.value), int(soc.boot_err_code_o.value), int(soc.u_boot.st.value)))


TRIGGER = {"selftest": 2, "bus": 1}                                # the stage that starts the stimulus
EXPECT = {
    "selftest": dict(stage=15, errors=0, u0_count=16, u0_sum=0x378, spi1_count=3, spi1_sum=0x6666, i2c1_count=4,
                     i2c1_sum=0xAA, gpio_bits=0x8000_0001, gpio_edges=2, flash_count=4, flash_word=0x3143_5950,
                     timer_hits=1, i2c0_done=1, cause=1),
    "bus": dict(stage=2, errors=0, ext_count=6, ext_bits=0xF000, timer_hits=1, vec_sum=97, squares=85344)}


def first_diff(a, b):
    k = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    return k, a[k:k + 3], b[k:k + 3]


@cocotb.test()
async def test_firmware_clock_exact(dut):
    """The case's firmware from the boot to its end: model and RTL clock for clock."""
    assert FW, "PYSOC_FW: the compiled firmware's prefix"
    with open(FW + ".flash.bin", "rb") as fh:
        image = fh.read()
    code, consts = pm.load_hex(FW + ".code.hex"), pm.load_hex(FW + ".const.hex")
    g = syms(FW)
    mo = run_model(image, code, consts, g)
    dut._log.info("model: boot done at %d, %d instructions, watchdog reset at %s, end %s", mo["boot_at"],
                  len(mo["trace"]), mo["wdt"], mo["end"])
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    limit = (mo["wdt"] or MAX_CLOCKS) + 200
    r = await run_rtl(dut, mo["g2"], mo["ext"], limit)
    assert r["boot_at"] == mo["boot_at"], (f"boot done: rtl clock {r['boot_at']} model {mo['boot_at']} (rtl "
                                           f"after {r['clocks']} clocks: err, code, state {r['boot']})")
    if r["trace"] != mo["trace"]:
        k, x, y = first_diff(mo["trace"], r["trace"])
        t = min(x[0][0] if x else 1 << 62, y[0][0] if y else 1 << 62)
        near = lambda q: [(c, hex(v)) for c, v in q if t - 3000 <= c <= t + 50]  # noqa: E731
        dut._log.error("interrupt sources near clock %d: model %s rtl %s", t, near(mo["irqs"]), near(r["irqs"]))
        ctx = lambda q: [(c, a, f"{mo['code'][a]:02X}") for c, a in q[max(0, k - 6):k + 3]]  # noqa: E731
        dut._log.error("instructions %d..: model %s", max(0, k - 6), ctx(mo["trace"]))
        dut._log.error("instructions %d..: rtl   %s", max(0, k - 6), ctx(r["trace"]))
        dut._log.error("last reads: model %s rtl %s", [(hex(a), hex(d)) for a, d in mo["reads"][-0:][:0]] or "",
                       "")
        raise AssertionError(f"instruction {k} differs: model {x} rtl {y} (lengths {len(mo['trace'])} / "
                             f"{len(r['trace'])})")
    for kind in ("reads", "writes"):
        mk, rk = mo[kind], r[kind]
        if mo["wdt"] is not None:                                 # an access in flight at the reset
            rk = rk[:len(mk)]
        if mk != rk:
            k, x, y = first_diff(mk, rk)
            raise AssertionError(f"{kind} {k} differ: model {[(hex(a), hex(d)) for a, d in x]} "
                                 f"rtl {[(hex(a), hex(d)) for a, d in y]}")
    assert r["wdt"] == mo["wdt"], f"watchdog reset: rtl clock {r['wdt']} model {mo['wdt']}"
    assert r["end"] == mo["end"], f"end: rtl {r['end']} model {mo['end']}"
    gl = mo["globals"]
    bad = {k: (gl.get(k), v) for k, v in EXPECT[CASE].items() if gl.get(k) != v}
    assert not bad, f"firmware results (model, expected): {bad}"
    if CASE == "selftest":
        assert gl["wdt_pre"] >= 3, f"watchdog pre-timeout interrupts {gl['wdt_pre']}"
        assert mo["i2c0"][16:18] == b"\xaa\x55", "I2C0 write in the target's memory"
        assert mo["wdt"] is not None, "the watchdog reset did not come"
    else:
        assert mo["end"] is not None and mo["end"][:2] == ("trap", 5), f"end {mo['end']}: TRAP_BUS expected"
    for k, i in g.items():                                       # the RTL's globals equal the model's
        if isinstance(gl[k], int) and not isinstance(gl[k], bool):
            v = int(dut.u_soc.u_core.globals[i].value)
            assert v == pm.small(gl[k]), f"global {k}: rtl {v:#x} model {pm.small(gl[k]):#x}"
    ops = collections.Counter(mo["code"][a] for _, a in mo["trace"])
    dut._log.info("compared: boot %d clocks, %d instructions (%d opcodes), %d reads, %d writes, watchdog reset "
                  "at clock %d", mo["boot_at"], len(mo["trace"]), len(ops), len(mo["reads"]), len(mo["writes"]),
                  mo["wdt"] or -1)
