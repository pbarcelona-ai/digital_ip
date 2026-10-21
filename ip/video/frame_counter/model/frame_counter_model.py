"""frame_counter model (Python model of ip/video/frame_counter/src/frame_counter_top.sv): NCH channels of
frame markers; per channel a COUNT (32 bits; CLEAR bits reset them), a STATUS bit (W1C; a marker wins over a
clear in the same clock) and, with EV_EN, an entry in the EVQ-deep event log (EVENT: [31] valid, [30] overflow,
[26:24] channel, [23:0] the channel's count after the marker; EVENT_TIME its timestamp; EVENT_POP [0] pops,
[1] clears the overflow); TIME a counter of TS_DIV-clock ticks; irq_o[ch] = STATUS[ch] & IRQ_EN[ch].

FrameCounterCore is the clock-exact definition of the logic (frame_counter.sv, the registers on its cfg_* /
sts_* ports): per clock the counts after the clock are n = CLEAR & mask ? (marker ? 1 : 0) : count + marker; a
marker of an EV_EN channel becomes that channel's pending event (count n, the TIME of this clock; a pending event
still waiting is lost and sets the overflow); each clock the oldest pending event (lowest timestamp, lowest
channel on a tie) moves into the log, or is lost with the overflow set when the log is full and not popped in
that clock; a POP with an empty log does nothing.

FrameCounter is the event-level form pysim uses (sim is the event queue, its time in microseconds = TS_DIV
clock MHz; update_irq() is called when an interrupt may change): markers never coincide within one clock there,
so each marker goes straight into the log, and an entry appears one clock earlier than in the RTL."""
from regs import RegMap, ip_regs

LOG_DEPTH = 128                # EVQ of video_processor


class FrameCounterCore:
    """frame_counter.sv clock for clock: clock(inputs) -> the outputs during the clock, then the edge."""

    def __init__(self, nch=2, evq=64, ts_div=1):
        self.nch, self.evq, self.ts_div = nch, evq, ts_div
        self.count = [0] * nch
        self.ts = self.div = 0
        self.pend = [False] * nch
        self.pend_cnt = [0] * nch
        self.pend_ts = [0] * nch
        self.q = []                                     # the log, oldest first: (channel, count, time)
        self.ovf = False

    def clock(self, eof=0, irq_en=0, ev_en=0, status=0, clear_wr=0, clear_mask=0, pop_wr=0, pop_data=0):
        """One clock: eof the marker bits, the register values / write pulses as on the cfg_* ports."""
        m = (1 << self.nch) - 1
        head = self.q[0] if self.q else None
        out = dict(irq=status & irq_en & m, status_set=eof & m, time=self.ts,
                   count=list(self.count), ovf=int(self.ovf),
                   event=((1 << 31) | (int(self.ovf) << 30) | (head[0] << 24) | head[1]) if head
                   else int(self.ovf) << 30,
                   event_time=head[2] if head else 0)
        n_count = []
        for i in range(self.nch):
            e = eof >> i & 1
            if clear_wr and clear_mask >> i & 1:
                n_count.append(1 if e else 0)
            else:
                n_count.append((self.count[i] + e) & 0xFFFFFFFF)
        push, pch = False, 0
        for i in range(self.nch):                      # the oldest pending event (lowest channel on a tie)
            if self.pend[i] and (not push or self.pend_ts[i] < self.pend_ts[pch]):
                push, pch = True, i
        pop = bool(pop_wr and pop_data & 1 and self.q)
        ovf = self.ovf
        if pop_wr and pop_data & 2:
            ovf = False
        q = self.q[1:] if pop else list(self.q)
        if push:
            if len(self.q) < self.evq or pop:
                q.append((pch, self.pend_cnt[pch], self.pend_ts[pch]))
            else:
                ovf = True                              # log full: the event is lost
        pend, pcnt, pts = list(self.pend), list(self.pend_cnt), list(self.pend_ts)
        for i in range(self.nch):
            if eof >> i & 1 and ev_en >> i & 1:
                if self.pend[i] and not (push and pch == i):
                    ovf = True                          # the previous one was not yet queued
                pend[i], pcnt[i], pts[i] = True, n_count[i] & 0xFFFFFF, self.ts
            elif push and pch == i:
                pend[i] = False
        if self.div == self.ts_div - 1:
            self.div, self.ts = 0, (self.ts + 1) & 0xFFFFFFFF
        else:
            self.div += 1
        self.count, self.q, self.ovf = n_count, q, ovf
        self.pend, self.pend_cnt, self.pend_ts = pend, pcnt, pts
        return out


class FrameCounter:
    """frame_counter (event level, pysim): registers, per-channel counts, the event log; marker(ch)."""

    def __init__(self, sim, update_irq, nch=5, evq=LOG_DEPTH):
        self.sim, self.update_irq, self.nch, self.evq = sim, update_irq, nch, evq
        self.r = RegMap(ip_regs(__file__, "frame_counter"), {"NCH": nch})
        self.count = [0] * nch
        self.log = []
        self.ovf = False
        self.r.sts = self._sts
        self.r.on_write = self._w

    def _sts(self, n, i):
        if n == "COUNT":
            return self.count[i]
        if n == "EVENT":
            if not self.log:
                return int(self.ovf) << 30
            ch, cnt, _ = self.log[0]
            return (1 << 31) | (int(self.ovf) << 30) | (ch << 24) | (cnt & 0xFFFFFF)
        if n == "EVENT_TIME":
            return self.log[0][2] if self.log else 0
        if n == "TIME":
            return self.sim.us() & 0xFFFFFFFF
        return 0

    def _w(self, n, i, d):
        if n == "CLEAR":
            for c in range(self.nch):
                if d >> c & 1:
                    self.count[c] = 0
        elif n == "EVENT_POP":
            if d & 1 and self.log:
                self.log.pop(0)
            if d & 2:
                self.ovf = False
        self.update_irq()

    def marker(self, ch):
        """A frame marker on channel ch."""
        self.count[ch] = (self.count[ch] + 1) & 0xFFFFFFFF
        self.r.hw_set("STATUS", 1 << ch)
        if self.r.get("EV_EN") >> ch & 1:
            if len(self.log) < self.evq:
                self.log.append((ch, self.count[ch] & 0xFFFFFF, self.sim.us() & 0xFFFFFFFF))
            else:
                self.ovf = True
        self.update_irq()

    def irq(self, ch):
        """irq_o[ch]: STATUS & IRQ_EN."""
        return (self.r.get("STATUS") & self.r.get("IRQ_EN")) >> ch & 1
