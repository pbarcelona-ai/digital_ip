"""frame_store_if model (Python model of ip/shared/src/interfaces/frame_store_if.sv): a double-buffered
DDR-backed frame store with on-chip row cache.

The store holds two frames (buffers 0 and 1). The writer fills one buffer while the reader reads from
the other. At frame boundaries the buffers swap. The row cache keeps recently-read source rows
on-chip (the correction mapping is locally smooth, so consecutive output pixels read nearby source rows).

Write port: sequential raster writes (wr_en, wr_addr, wr_data, wr_buf_sel)
Read port: four-address reads for interpolation (rd_en, rd_addr0..3, rd_buf_sel -> rd_data0..3, rd_valid)
Buffer management: swap_buf pulse swaps write/read buffers
Cache control: cache_flush flushes the row cache
"""

from collections import OrderedDict


class FrameStoreModel:
    """Python model of frame_store_if: double-buffered frame store with row cache."""

    def __init__(self, pix_w=24, addr_w=20, cache_lines=8, cache_line_w=11,
                 frame_width=1920, frame_height=1080):
        self.pix_w = pix_w
        self.addr_w = addr_w
        self.cache_lines = cache_lines
        self.cache_line_w = cache_line_w
        self.frame_width = frame_width
        self.frame_height = frame_height
        self.frame_size = frame_width * frame_height

        # Two frame buffers (simulated as dicts for sparse storage)
        self.buffers = [{}, {}]
        self.wr_buf = 0   # buffer being written
        self.rd_buf = 1   # buffer being read

        # Row cache: LRU cache of (buf, row) -> list of pixels for that row
        # row is y coordinate, cache stores the entire row
        self.cache = OrderedDict()  # (buf, row) -> [pixels...]
        self.cache_valid = set()    # set of (buf, row) that are valid in cache

        # State
        self.wr_ready = True
        self.rd_ready = True
        self.rd_valid = False
        self.rd_data = [0, 0, 0, 0]
        self.store_idle = True
        self.wr_fill = 0  # 0: empty, 1: partial, 2: full, 3: overflow
        self.rd_fill = 0
        self.buf_swapped = False
        self.cache_flushed = False

        # Pending operations
        self.pending_wr = None
        self.pending_rd = None

    def _addr_to_xy(self, addr):
        """Convert linear address to (x, y) coordinates."""
        y = addr // self.frame_width
        x = addr % self.frame_width
        return x, y

    def _xy_to_addr(self, x, y):
        """Convert (x, y) coordinates to linear address."""
        return y * self.frame_width + x

    def _get_row_from_buffer(self, buf, row):
        """Get a full row from the buffer (for cache fill)."""
        if row >= self.frame_height:
            return [0] * self.frame_width
        row_data = []
        base_addr = row * self.frame_width
        for x in range(self.frame_width):
            addr = base_addr + x
            row_data.append(self.buffers[buf].get(addr, 0))
        return row_data

    def _cache_get(self, buf, row):
        """Get a row from cache, or fill from buffer if not present."""
        key = (buf, row)
        if key in self.cache:
            # Move to end (most recently used)
            self.cache.move_to_end(key)
            return self.cache[key]
        # Cache miss: fill from buffer
        row_data = self._get_row_from_buffer(buf, row)
        self.cache[key] = row_data
        self.cache_valid.add(key)
        # Evict oldest if cache full
        while len(self.cache) > self.cache_lines:
            oldest_key, _ = self.cache.popitem(last=False)
            self.cache_valid.discard(oldest_key)
        return row_data

    def _cache_invalidate(self, buf=None):
        """Invalidate cache entries for a buffer, or all if buf is None."""
        if buf is None:
            self.cache.clear()
            self.cache_valid.clear()
        else:
            to_remove = [k for k in self.cache if k[0] == buf]
            for k in to_remove:
                del self.cache[k]
                self.cache_valid.discard(k)

    def write_pixel(self, buf, addr, data):
        """Write a pixel to the buffer."""
        if buf not in (0, 1):
            return False
        if addr >= self.frame_size:
            return False
        self.buffers[buf][addr] = data & ((1 << self.pix_w) - 1)
        # Invalidate cache for this buffer/row if present
        x, y = self._addr_to_xy(addr)
        key = (buf, y)
        if key in self.cache:
            # Update cache in place
            self.cache[key][x] = data & ((1 << self.pix_w) - 1)
            self.cache.move_to_end(key)
        return True

    def read_pixels(self, buf, addr0, addr1, addr2, addr3):
        """Read four pixels from the buffer (using cache)."""
        if buf not in (0, 1):
            return [0, 0, 0, 0]
        results = []
        for addr in (addr0, addr1, addr2, addr3):
            if addr >= self.frame_size:
                results.append(0)
                continue
            x, y = self._addr_to_xy(addr)
            row_data = self._cache_get(buf, y)
            if x < len(row_data):
                results.append(row_data[x])
            else:
                results.append(0)
        return results

    def swap_buffers(self):
        """Swap write and read buffers."""
        self.wr_buf, self.rd_buf = self.rd_buf, self.wr_buf
        # Invalidate cache for the new read buffer (it will be refilled on demand)
        self._cache_invalidate(self.rd_buf)
        self.buf_swapped = True

    def flush_cache(self):
        """Flush the row cache."""
        self._cache_invalidate()
        self.cache_flushed = True

    def cycle(self, inputs):
        """One clock cycle of the frame store model.

        inputs: dict with keys:
          wr_en, wr_addr, wr_data, wr_buf_sel, wr_frame_done
          rd_en, rd_addr0, rd_addr1, rd_addr2, rd_addr3, rd_buf_sel
          swap_buf, cache_flush
        """
        # Reset outputs
        self.wr_ready = True
        self.rd_ready = True
        self.rd_valid = False
        self.buf_swapped = False
        self.cache_flushed = False

        # Handle write
        if inputs.get('wr_en', False):
            buf = inputs.get('wr_buf_sel', 0) & 1
            addr = inputs.get('wr_addr', 0)
            data = inputs.get('wr_data', 0)
            self.write_pixel(buf, addr, data)

            if inputs.get('wr_frame_done', False):
                self.wr_fill = 2  # full
                # Frame done: could trigger buffer swap here or wait for swap_buf
            else:
                self.wr_fill = 1  # partial

        # Handle read
        if inputs.get('rd_en', False):
            buf = inputs.get('rd_buf_sel', 0) & 1
            addr0 = inputs.get('rd_addr0', 0)
            addr1 = inputs.get('rd_addr1', 0)
            addr2 = inputs.get('rd_addr2', 0)
            addr3 = inputs.get('rd_addr3', 0)
            self.rd_data = self.read_pixels(buf, addr0, addr1, addr2, addr3)
            self.rd_valid = True
            self.rd_fill = 1  # partial

        # Handle buffer swap
        if inputs.get('swap_buf', False):
            self.swap_buffers()

        # Handle cache flush
        if inputs.get('cache_flush', False):
            self.flush_cache()

        # Update store_idle
        self.store_idle = not (inputs.get('wr_en', False) or inputs.get('rd_en', False) or
                               inputs.get('swap_buf', False) or inputs.get('cache_flush', False))

        return {
            'wr_ready': self.wr_ready,
            'rd_ready': self.rd_ready,
            'rd_valid': self.rd_valid,
            'rd_data0': self.rd_data[0],
            'rd_data1': self.rd_data[1],
            'rd_data2': self.rd_data[2],
            'rd_data3': self.rd_data[3],
            'buf_swapped': self.buf_swapped,
            'cache_flushed': self.cache_flushed,
            'store_idle': self.store_idle,
            'wr_fill': self.wr_fill,
            'rd_fill': self.rd_fill,
        }

    def reset(self):
        """Reset the model."""
        self.buffers = [{}, {}]
        self.wr_buf = 0
        self.rd_buf = 1
        self.cache.clear()
        self.cache_valid.clear()
        self.wr_ready = True
        self.rd_ready = True
        self.rd_valid = False
        self.rd_data = [0, 0, 0, 0]
        self.store_idle = True
        self.wr_fill = 0
        self.rd_fill = 0
        self.buf_swapped = False
        self.cache_flushed = False