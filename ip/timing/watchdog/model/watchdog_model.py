"""watchdog model (Python model of ip/timing/watchdog/src/watchdog.sv), event driven with the RTL's clock timing.

Registers (watchdog_regs.json): CTRL [0] EN [1] WINDOW_EN [2] LOCK (a write is ignored once LOCK is set; reads
the state), TIMEOUT, PRESCALE (clocks per tick - 1), PRETIMEOUT (0: off), WINDOW_OPEN, KICK (0x5AFEC0DE restarts
the count, another value sets BAD_KEY), STATUS [0] PRETIMEOUT [1] EXPIRED [2] EARLY [3] BAD_KEY (W1C, a set in
the same clock wins), COUNT. irq = STATUS.PRETIMEOUT; reset_out: the system reset request, RESET_CYCLES clocks.

Clock behaviour (the state of clock t + 1 from clock t, the RTL's priorities):
  CTRL written in t (not locked): EN / WINDOW_EN / LOCK from t + 1; TIMEOUT / PRESCALE / PRETIMEOUT /
  WINDOW_OPEN take effect from t + 1 (latched copies, frozen while locked; the copy in the clock LOCK is
  written is still taken);
  the prescaler counts while enabled (zero in the clock EN rises and in each tick clock): a tick in clock c + 1
  when the count of clock c reaches PRESCALE;
  the count: disabled -> 0; else a good kick (not early) -> 0; else an early kick (window mode, count below
  WINDOW_OPEN) or an expiry (a tick with count >= TIMEOUT) -> 0 and the reset request from the next clock;
  else a tick -> count + 1;
  flags: written 1s clear, then PRETIMEOUT set by a tick while enabled with count >= PRETIMEOUT != 0, EXPIRED
  by an expiry (also while being disabled), EARLY by an early kick, BAD_KEY by another key, PRETIMEOUT cleared
  by a good kick.
The host (soc) provides sim (the event queue) and update_irq(); on_reset(t) is told when a reset request starts."""
from regs import RegMap, ip_regs

KEY = 0x5AFEC0DE
LATCHED = ("TIMEOUT", "PRESCALE", "PRETIMEOUT", "WINDOW_OPEN")


class Wdt:
    """watchdog.sv: registers, the latched timing, prescaler, count, flags and the reset request."""

    def __init__(self, soc, reset_cycles=16):
        self.soc, self.rc = soc, reset_cycles
        self.r = RegMap(ip_regs(__file__, "watchdog"))
        self.lat = {}                                    # the latched copies of the timing registers
        self.en = self.win = self.lock = False
        self.cnt = 0
        self.pre = self.exp = self.early = self.key = False
        self.z = None                                    # clock the prescaler count was zero (enabled)
        self.tick_at = None                              # next tick clock
        self.wr = {}                                     # register writes of the clock being processed
        self.due = set()                                 # clocks whose edge is scheduled
        self.reset_out = [(0, 0)]                        # reset request transitions (clock, level)
        self.on_reset = None
        self.r.sts = self._sts
        self.r.on_write = self._w
        for k in LATCHED:                                # the copies equal the registers from the first clock
            self.lat[k] = self.r.get(k)

    def _sts(self, name, i):
        if name == "STATUS":
            return int(self.pre) | int(self.exp) << 1 | int(self.early) << 2 | int(self.key) << 3
        if name == "COUNT":
            return self.cnt & 0xFFFFFFFF
        if name == "CTRL":
            return int(self.en) | int(self.win) << 1 | int(self.lock) << 2
        return 0

    def irq(self):
        return self.pre

    def reset_at(self, n):
        for t, v in reversed(self.reset_out):
            if t <= n:
                return v
        return 0

    # -- writes are processed at the clock's edge
    def _w(self, name, i, d):
        t = self.soc.sim.now
        self.wr.setdefault(t, {})[name] = d
        self._edge_due(t)

    def _edge_due(self, t):
        if t not in self.due:
            self.due.add(t)
            self.soc.sim.at(t + 1, lambda: self._edge(t))

    def _edge(self, t):
        """The edge after clock t: the state of clock t + 1."""
        self.due.discard(t)
        wr = self.wr.pop(t, {})
        tick = self.tick_at == t
        kick = wr.get("KICK")
        good, bad = kick == KEY, kick is not None and kick != KEY
        early = good and self.win and self.cnt < self.lat["WINDOW_OPEN"]
        ok = good and not early
        expire = tick and self.cnt >= self.lat["TIMEOUT"]
        cnt0 = self.cnt
        if not self.en:
            self.cnt = 0
        elif ok:
            self.cnt = 0
        elif early or expire:
            self.cnt = 0
            self._reset_pulse(t + 1)
        elif tick:
            self.cnt = cnt0 + 1
        st = wr.get("STATUS")
        if st is not None:
            self.pre = self.pre and not st & 1
            self.exp = self.exp and not st & 2
            self.early = self.early and not st & 4
            self.key = self.key and not st & 8
        if self.en and tick and cnt0 >= self.lat["PRETIMEOUT"] and self.lat["PRETIMEOUT"] != 0:
            self.pre = True
        self.exp |= expire
        self.early |= early
        self.key |= bad
        if ok:
            self.pre = False
        was_en, was_lock = self.en, self.lock
        if "CTRL" in wr and not was_lock:
            d = wr["CTRL"]
            self.en, self.win, self.lock = bool(d & 1), bool(d & 2), bool(d & 4)
        p_old = self.lat["PRESCALE"]
        if not was_lock:                                 # the copies of clock t (frozen once locked)
            for k in LATCHED:
                self.lat[k] = self.r.get(k)
        # the prescaler: a tick in clock c + 1 when the count of clock c (clocks since its zero clock z) reaches
        # the latched PRESCALE of clock c (p_old for clock t, the new copy from t + 1)
        p_new = self.lat["PRESCALE"]
        if was_en and not self.en:                       # disabled from t + 1: no tick after t, COUNT cleared
            self.z = self.tick_at = None                 # by the edge after t + 1
            self._edge_due(t + 1)
        elif self.en and not was_en:                     # enabled from t + 1: its count is zero then
            self.z = t + 1
            self.tick_at = self.z + p_new + 1
        elif self.en and tick:                           # the tick clock's count is zero
            self.z = t
            self.tick_at = t + 1 if p_old == 0 else max(t + 1, self.z + p_new) + 1
        elif self.en and p_new != p_old and self.tick_at is not None and self.tick_at > t + 1:
            self.tick_at = max(t + 1, self.z + p_new) + 1
        if self.tick_at is not None:
            self._edge_due(self.tick_at)
        self.soc.update_irq()

    def _reset_pulse(self, t):
        self.reset_out.append((t, 1))
        self.reset_out.append((t + self.rc, 0))
        if self.on_reset:
            self.on_reset(t)
