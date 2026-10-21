"""Event queue of the Python models (ip/shared/pymodel): time in clock cycles of one reference clock.

Models schedule their completions with `at(t, fn)` / `after(dt, fn)`; `advance(cycles)` runs the events that
fall due in time order (events at the same time in the order they were scheduled), calling `on_event` after
each one (the SoC re-evaluates its interrupt lines there).
"""
import heapq


class Sim:
    """Event queue in clock cycles at hz."""

    def __init__(self, hz=200_000_000):
        self.hz = hz
        self.now = 0
        self.q = []
        self.seq = 0
        self.on_event = None                            # called after every event (interrupt re-evaluation)

    def at(self, t, fn):
        self.seq += 1
        heapq.heappush(self.q, (t, self.seq, fn))

    def after(self, dt, fn):
        self.at(self.now + max(1, int(dt)), fn)

    def next_time(self):
        return self.q[0][0] if self.q else None

    def advance(self, cycles):
        end = self.now + cycles
        while self.q and self.q[0][0] <= end:
            t, _, fn = heapq.heappop(self.q)
            self.now = max(self.now, t)
            fn()
            if self.on_event:
                self.on_event()
        self.now = end

    def us(self):
        return self.now * 1_000_000 // self.hz
