"""py_sysctl model (Python model of ip/cpu/py_soc/src/py_sysctl.sv): reset cause, boot status (boot done),
free-running CYCLES, SoC ID, CORE_RESET (releases the video core), CLK_EN (NCLK bits, reset value
CLK_EN_RST), CLK_STATUS [0] locked (1) [1] clock generator present (CLKGEN) and the timer compare (TIMER_CMP / TIMER_CTRL / TIMER_STATUS; interrupt source 16): one-shot,
armed by every TIMER_CMP write (which clears REACHED), REACHED set in the clock CYCLES equals TIMER_CMP, or the
clock after the write when it is already reached (CYCLES - TIMER_CMP < 2**31); TIMER_STATUS write 1 clears it
from the next clock (a set in that clock wins). CYCLES is the event queue's time (the RTL's counter counts
from the system reset). BOOT_STATUS comes from the host's boot_status (default 1: boot done).

The host (soc) provides sim (the event queue), core_reset(release), clk_en and update_irq()."""
from regs import RegMap, ip_regs


class SysCtl:
    """py_sysctl: registers, reset cause, cycle counter, core reset, timer compare."""

    def __init__(self, soc, nclk=4, clk_en_rst=0, clkgen=True):
        self.soc = soc
        self.r = RegMap(ip_regs(__file__, "py_sysctl"), {"NCLK": nclk, "CLK_EN_RST": clk_en_rst})
        self.clk_status = 1 | int(clkgen) << 1
        self.cause = 1
        self.timer_gen = 0                              # TIMER_CMP writes: a stale compare event is ignored
        self.reached = False                            # TIMER_STATUS.REACHED
        self.r.sts = self._sts
        self.r.on_write = self._w

    def _sts(self, name, i):
        return {"RESET_CAUSE": self.cause, "BOOT_STATUS": getattr(self.soc, "boot_status", 1),
                "CYCLES": self.soc.sim.now & 0xFFFFFFFF, "SOC_ID": 0x50590100, "CLK_STATUS": self.clk_status,
                "TIMER_STATUS": int(self.reached)}.get(name, 0)

    def _w(self, name, i, d):
        if name == "RESET_CAUSE":
            self.cause &= ~d
        elif name == "CORE_RESET":
            self.soc.core_reset(d & 1)
        elif name == "CLK_EN":
            self.soc.clk_en = d
        elif name == "TIMER_STATUS" and d & 1:          # write 1 to clear
            self.reached = False
        elif name == "TIMER_CMP":                       # a new compare value: REACHED cleared, armed
            self.reached = False
            self.timer_gen += 1
            g = self.timer_gen
            now = self.soc.sim.now
            if (now + 1 - d) & 0xFFFFFFFF < 1 << 31:    # already reached in the next clock: REACHED then
                at = now + 1
            else:                                       # the clock CYCLES equals TIMER_CMP
                at = now + ((d - now) & 0xFFFFFFFF)
            self.soc.sim.at(at, lambda: self._reached(g))
        self.soc.update_irq()

    def _reached(self, g):
        """CYCLES reached TIMER_CMP (wrap-safe: CYCLES - TIMER_CMP < 2**31)."""
        if g == self.timer_gen:
            self.reached = True
            self.timer_gen += 1                         # one-shot
            self.soc.update_irq()

    def timer_irq(self):
        return self.reached and bool(self.r.get("TIMER_CTRL") & 1)
