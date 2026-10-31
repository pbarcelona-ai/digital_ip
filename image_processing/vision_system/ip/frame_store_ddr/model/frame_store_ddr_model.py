"""frame_store_ddr model (Python model of image_processing/vision_system/ip/frame_store_ddr/src/frame_store_ddr.sv):
double-buffered DDR-backed frame store with on-chip row cache for vision_system.
Cycle-exact model matching the RTL's write/read FSMs, AXI4 interface to DDR controller,
and DDR controller state machine with timing parameters.

The store uses ddr_ctrl (AXI4 multi-port) and ddr_mem (DFI memory model) to store frames
in external DDR. Two frame buffers in DDR (ping-pong): the writer fills one while the reader
reads from the other. At frame boundaries the buffers swap. An on-chip row cache keeps
recently-accessed source rows (the correction mapping is locally smooth).

Write port: sequential raster writes (wr_en, wr_addr, wr_data)
Read port: four-address reads for bilinear/bicubic interpolation
(rd_en, rd_addr0..3 -> rd_data0..3, rd_valid)

Parameters: PIX_W, ADDR_W, frame dimensions, DDR parameters, cache size.
"""

import sys
from pathlib import Path

# Add the ddr_ctrl model path
digital_ip_root = Path(__file__).resolve().parents[5]
ddr_ctrl_model_path = digital_ip_root / "ip" / "memory" / "ddr_ctrl" / "model"
if str(ddr_ctrl_model_path) not in sys.path:
    sys.path.insert(0, str(ddr_ctrl_model_path))
from ddr_ctrl_model import DdrCtrl  # noqa: E402

# FSM state constants - must match RTL exactly
WR_IDLE = 0
WR_BURST = 1
WR_WAIT_BRESP = 2

RD_IDLE = 0
RD_ISSUE = 1
RD_WAIT = 2


class FrameStoreDdrModel:
    """Cycle-exact Python model of frame_store_ddr.

    Returns registered outputs assigned at THIS clock edge (based on current state)
    to match testbench reading DUT outputs after clock edge.
    """

    def __init__(self, pix_w=24, addr_w=20, frame_width=64, frame_height=64,
                 cache_lines=4, cache_line_w=6,
                 ddr_data_w=64, ddr_addr_w=16, ddr_id_w=2, ddr_bank_w=2,
                 ddr_row_w=8, ddr_col_w=4,
                 ddr_t_rcd=2, ddr_t_rp=2, ddr_t_ras=4, ddr_t_cl=2,
                 ddr_t_wr=2, ddr_t_rtp=1, ddr_t_wtr=1, ddr_t_rrd=1,
                 ddr_t_rfc=8, ddr_t_refi=64, ddr_priority=0,
                 ddr_rq_depth=4, ddr_bq_depth=2,
                 ddr_mem_words=1 << 12, ddr_ref_max=9 * 64):
        self.pix_w = pix_w
        self.addr_w = addr_w
        self.frame_width = frame_width
        self.frame_height = frame_height
        self.frame_size = frame_width * frame_height
        self.cache_lines = cache_lines
        self.cache_line_w = cache_line_w
        self.ddr_data_w = ddr_data_w
        self.ddr_addr_w = ddr_addr_w
        self.ddr_id_w = ddr_id_w
        self.ddr_bank_w = ddr_bank_w
        self.ddr_row_w = ddr_row_w
        self.ddr_col_w = ddr_col_w
        self.ddr_t_rcd = ddr_t_rcd
        self.ddr_t_rp = ddr_t_rp
        self.ddr_t_ras = ddr_t_ras
        self.ddr_t_cl = ddr_t_cl
        self.ddr_t_wr = ddr_t_wr
        self.ddr_t_rtp = ddr_t_rtp
        self.ddr_t_wtr = ddr_t_wtr
        self.ddr_t_rrd = ddr_t_rrd
        self.ddr_t_rfc = ddr_t_rfc
        self.ddr_t_refi = ddr_t_refi
        self.ddr_priority = ddr_priority
        self.ddr_rq_depth = ddr_rq_depth
        self.ddr_bq_depth = ddr_bq_depth
        self.ddr_mem_words = ddr_mem_words
        self.ddr_ref_max = ddr_ref_max

        self.pix_per_word = ddr_data_w // pix_w
        self.pix_w_bytes = pix_w // 8
        self.bytes_per_word = ddr_data_w // 8
        self.off = (ddr_data_w // 8).bit_length() - 1
        self.frame_words = (self.frame_size + self.pix_per_word - 1) // self.pix_per_word
        self.frame_bytes = self.frame_words * self.bytes_per_word
        self.row_data_w = frame_width * pix_w

        # DDR controller model (golden model from ddr_ctrl IP)
        self.ddr_ctrl = DdrCtrl(
            nports=2,
            data_w=ddr_data_w, addr_w=ddr_addr_w, id_w=ddr_id_w, bank_w=ddr_bank_w,
            row_w=ddr_row_w, col_w=ddr_col_w,
            t_rcd=ddr_t_rcd, t_rp=ddr_t_rp, t_ras=ddr_t_ras, t_cl=ddr_t_cl,
            t_wr=ddr_t_wr, t_rtp=ddr_t_rtp, t_wtr=ddr_t_wtr, t_rrd=ddr_t_rrd,
            t_rfc=ddr_t_rfc, t_refi=ddr_t_refi, priority=ddr_priority,
            rq_depth=ddr_rq_depth, bq_depth=ddr_bq_depth
        )

        # Registered state (s) - matches RTL flops, values AFTER clock edge
        self.s = {
            # Write FSM
            'wr_state': WR_IDLE,
            'wr_addr_next': 0,
            'wr_pixel_count': 0,
            'wr_pack_cnt': 0,
            'wr_pack_data': 0,
            'wr_pack_strb': 0,
            'wr_burst_active': False,
            'wr_burst_len': 0,
            'wr_burst_addr': 0,
            'wr_ready': True,    # After reset, WR_IDLE -> wr_ready=1
            'wr_fill': 0,

            # Read FSM
            'rd_state': RD_IDLE,
            'rd_addr_idx': 0,
            'rd_resp_idx': 0,
            'rd_issued': 0,      # Track issued requests separately from completed
            'rd_completed': 0,   # Track completed responses
            'rd_valid': False,
            'rd_data': [0, 0, 0, 0],
            'rd_ready': True,    # After reset, RD_IDLE -> rd_ready=1
            'rd_fill': 0,
            'rd_pixel_count': 0,
            'rd_addrs': [0, 0, 0, 0],
            'rd_buf_q_latched': 1,

            # Buffer management (internal, not external selectors)
            'wr_buf': 0,
            'rd_buf': 1,
            'buf0_base_bytes': 0,
            'buf1_base_bytes': 0,

            # Cache
            'cache_valid': [],
            'cache_row_base_addr': [],
            'cache_buf_sel': [],
            'cache_row_data': [],

            # Previous DDR output
            'prev_ddr_out': None,

            # Outputs (pulses)
            'buf_swapped': False,
            'cache_flushed': False,
        }

        self.reset()

    def _get_ddr_base(self, buf):
        return self.s['buf0_base_bytes'] if buf == 0 else self.s['buf1_base_bytes']

    def cycle(self, inputs):
        """One clock cycle: compute registered outputs for THIS clock edge from
        current state and inputs, update state to next, return those outputs.

        Key insight: RTL always_ff blocks assign registered outputs based on
        CURRENT state (pre-clock). After clock edge N, DUT registered outputs
        = f(state_{N-1}). Model's self.s holds state_{N-1} at start of cycle().
        So we compute registered outputs from s, return them, THEN update s to
        next state."""
        s = self.s

        # Extract inputs
        wr_en = inputs.get('wr_en', 0)
        wr_addr = inputs.get('wr_addr', 0)
        wr_data = inputs.get('wr_data', 0)
        wr_buf_sel = inputs.get('wr_buf_sel', 0)  # Not used in RTL, internal tracking
        wr_frame_done = inputs.get('wr_frame_done', 0)
        rd_en = inputs.get('rd_en', 0)
        rd_addr0 = inputs.get('rd_addr0', 0)
        rd_addr1 = inputs.get('rd_addr1', 0)
        rd_addr2 = inputs.get('rd_addr2', 0)
        rd_addr3 = inputs.get('rd_addr3', 0)
        rd_buf_sel = inputs.get('rd_buf_sel', 0)  # Not used in RTL, internal tracking
        swap_buf = inputs.get('swap_buf', False)
        cache_flush = inputs.get('cache_flush', False)

        # Prepare AXI4 inputs for DDR controller (based on CURRENT state s)
        awvalid = [False, False]
        awaddr = [0, 0]
        awlen = [0, 0]
        awsize = [0, 0]
        awburst = [0, 0]
        awid = [0, 0]
        wvalid = [False, False]
        wdata = [0, 0]
        wstrb = [0, 0]
        wlast = [False, False]
        bready = [True, True]
        arvalid = [False, False]
        araddr = [0, 0]
        arlen = [0, 0]
        arsize = [0, 0]
        arburst = [0, 0]
        arid = [0, 0]
        rready = [True, True]

        # Write FSM combinational outputs (based on s) - for DDR controller
        if s['wr_state'] == WR_BURST:
            if s['wr_burst_active']:
                awvalid[0] = True
                awaddr[0] = s['wr_burst_addr']
                awlen[0] = s['wr_burst_len']
                awsize[0] = self.off
                awburst[0] = 1
                awid[0] = 0
                wvalid[0] = True
                wdata[0] = s['wr_pack_data']
                wstrb[0] = s['wr_pack_strb']
                wlast[0] = True

        # Read FSM combinational outputs (based on s) - for DDR controller
        if s['rd_state'] == RD_ISSUE:
            rd_buf_base = self._get_ddr_base(s['rd_buf'])
            addr = s['rd_addrs'][s['rd_addr_idx']]
            word_addr = (rd_buf_base // self.bytes_per_word) + (addr // self.pix_per_word)
            byte_addr = word_addr * self.bytes_per_word
            arvalid[1] = True
            araddr[1] = byte_addr
            arlen[1] = 0
            arsize[1] = self.off
            arburst[1] = 1
            arid[1] = s['rd_addr_idx']  # Use index as ID to track responses

        if s['rd_state'] == RD_WAIT:
            rready[1] = True

        # Build DdrCtrl input dictionary
        i = {
            'arvalid': arvalid,
            'araddr': araddr,
            'arlen': arlen,
            'arsize': arsize,
            'arburst': arburst,
            'arid': arid,
            'awvalid': awvalid,
            'awaddr': awaddr,
            'awlen': awlen,
            'awsize': awsize,
            'awburst': awburst,
            'awid': awid,
            'wvalid': wvalid,
            'wdata': wdata,
            'wstrb': wstrb,
            'rready': rready,
            'bready': bready,
        }

        # ===== RUN DDR CONTROLLER =====
        ddr_out = self.ddr_ctrl.cycle(i)

        # ===== COMPUTE REGISTERED OUTPUTS FOR THIS CLOCK EDGE =====
        # These match what DUT shows AFTER this clock edge (registered at this
        # clock edge based on state s and current inputs). The testbench samples
        # at FallingEdge AFTER the RisingEdge where these are registered.

        # wr_ready: registered based on wr_state (in WR_IDLE -> 1)
        wr_ready_out = (s['wr_state'] == WR_IDLE)

        # wr_fill: in WR_IDLE -> 1, otherwise holds
        wr_fill_out = 1 if s['wr_state'] == WR_IDLE else s['wr_fill']

        # rd_ready: in RD_IDLE -> 1
        rd_ready_out = (s['rd_state'] == RD_IDLE)

        # rd_fill: in RD_IDLE -> 1 if rd_en else 0; in RD_ISSUE/RD_WAIT -> 2
        if s['rd_state'] == RD_IDLE:
            rd_fill_out = 1 if rd_en else 0
        elif s['rd_state'] in (RD_ISSUE, RD_WAIT):
            rd_fill_out = 2
        else:
            rd_fill_out = s['rd_fill']

        # rd_valid: registered when in RD_WAIT, all 4 responses received
        rd_valid_out = (s['rd_state'] == RD_WAIT and s['rd_completed'] == 0b1111 and ddr_out['rvalid'][1])

        # rd_data: registered when rvalid comes back
        rd_data_out = list(s['rd_data'])
        if s['rd_state'] == RD_WAIT and ddr_out['rvalid'][1]:
            # Extract RID to determine which response this is
            rid_port1 = ddr_out['rid'][1] if len(ddr_out['rid']) > 1 else 0
            resp_idx = rid_port1 & 0x3  # Lower 2 bits
            addr = s['rd_addrs'][resp_idx]
            pixel_in_word = (addr % self.pix_per_word)
            rd_data_out[resp_idx] = (ddr_out['rdata'][1] >> (pixel_in_word * self.pix_w)) & ((1 << self.pix_w) - 1)

        # buf_swapped: registered pulse whenever swap_buf is asserted
        buf_swapped_out = swap_buf

        # cache_flushed: registered pulse when cache_flush asserted (and not swap_buf)
        cache_flushed_out = cache_flush and not swap_buf

        # ===== COMPUTE NEXT STATE (n) FROM CURRENT STATE (s) AND INPUTS =====
        n = dict(s)
        n['rd_data'] = list(s['rd_data'])
        n['rd_addrs'] = list(s['rd_addrs'])
        n['cache_valid'] = list(s['cache_valid'])
        n['cache_row_base_addr'] = list(s['cache_row_base_addr'])
        n['cache_buf_sel'] = list(s['cache_buf_sel'])
        n['cache_row_data'] = [list(row) for row in s['cache_row_data']]

        # Default next-state values (pulses default to 0)
        n['buf_swapped'] = False
        n['cache_flushed'] = False
        n['rd_valid'] = False

        # -----------------------------------------------------------------------
        # Write FSM next state - matches RTL exactly
        # -----------------------------------------------------------------------
        if s['wr_state'] == WR_IDLE:
            if wr_en:
                # Pack pixel into DDR word
                n['wr_pack_data'] = s['wr_pack_data'] | ((wr_data & ((1 << self.pix_w) - 1)) << (s['wr_pack_cnt'] * self.pix_w))
                n['wr_pack_strb'] = s['wr_pack_strb'] | (((1 << self.pix_w_bytes) - 1) << (s['wr_pack_cnt'] * self.pix_w_bytes))
                n['wr_pack_cnt'] = s['wr_pack_cnt'] + 1
                n['wr_addr_next'] = wr_addr + 1
                n['wr_pixel_count'] = s['wr_pixel_count'] + 1

                # Check if we should issue a burst (word full)
                if s['wr_pack_cnt'] == self.pix_per_word - 1:
                    buf_base = self._get_ddr_base(s['wr_buf'])
                    word_addr = buf_base + ((n['wr_pixel_count'] - 1) // self.pix_per_word) * self.bytes_per_word
                    byte_addr = word_addr
                    n['wr_burst_active'] = True
                    n['wr_burst_addr'] = byte_addr
                    n['wr_burst_len'] = 0
                    n['wr_state'] = WR_BURST
                    n['wr_pack_cnt'] = 0
                    n['wr_pack_data'] = 0
                    n['wr_pack_strb'] = 0

            if wr_frame_done:
                # Flush partial word if any
                if s['wr_pack_cnt'] != 0:
                    buf_base = self._get_ddr_base(s['wr_buf'])
                    word_addr = buf_base + ((s['wr_pixel_count'] - 1) // self.pix_per_word) * self.bytes_per_word
                    byte_addr = word_addr
                    n['wr_burst_active'] = True
                    n['wr_burst_addr'] = byte_addr
                    n['wr_burst_len'] = 0
                    n['wr_state'] = WR_BURST
                    n['wr_pack_cnt'] = 0
                    n['wr_pack_data'] = 0
                    n['wr_pack_strb'] = 0
                else:
                    n['wr_state'] = WR_WAIT_BRESP
                if s['wr_buf'] == 0:
                    n['frame0_written'] = True
                else:
                    n['frame1_written'] = True
                n['wr_fill'] = 2  # full

        elif s['wr_state'] == WR_BURST:
            # DDR controller outputs handled below
            pass

        elif s['wr_state'] == WR_WAIT_BRESP:
            pass

        # Process DDR controller outputs for write FSM (next state)
        if s['wr_state'] == WR_BURST:
            if ddr_out['awready'][0] and ddr_out['wready'][0]:
                n['wr_burst_active'] = False
                if wr_frame_done:
                    n['wr_state'] = WR_WAIT_BRESP
                else:
                    n['wr_state'] = WR_IDLE

        if s['wr_state'] == WR_WAIT_BRESP:
            if ddr_out['bvalid'][0]:
                n['wr_state'] = WR_IDLE

        # -----------------------------------------------------------------------
        # Read FSM next state - matches RTL exactly
        # -----------------------------------------------------------------------
        if s['rd_state'] == RD_IDLE:
            if rd_en:
                n['rd_addrs'] = [rd_addr0, rd_addr1, rd_addr2, rd_addr3]
                n['rd_addr_idx'] = 0
                n['rd_issued'] = 0
                n['rd_completed'] = 0
                n['rd_resp_idx'] = 0
                n['rd_state'] = RD_ISSUE
                n['rd_pixel_count'] = s['rd_pixel_count'] + 1
                n['rd_buf_q_latched'] = s['rd_buf']  # Use internal buffer selection

        elif s['rd_state'] == RD_ISSUE:
            # DDR controller outputs handled below
            pass

        elif s['rd_state'] == RD_WAIT:
            pass

        # Process DDR controller outputs for read FSM (next state)
        if s['rd_state'] == RD_ISSUE:
            if ddr_out['arready'][1]:
                n['rd_issued'] = s['rd_issued'] | (1 << s['rd_addr_idx'])
                n['rd_addr_idx'] = (s['rd_addr_idx'] + 1) & 0b11
                if s['rd_addr_idx'] == 3:
                    n['rd_state'] = RD_WAIT
                    n['rd_resp_idx'] = 0

        if s['rd_state'] == RD_WAIT:
            if ddr_out['rvalid'][1]:
                # Extract RID to determine which response this is
                rid_port1 = ddr_out['rid'][1] if len(ddr_out['rid']) > 1 else 0
                resp_idx = rid_port1 & 0x3  # Lower 2 bits
                addr = s['rd_addrs'][resp_idx]
                pixel_in_word = (addr % self.pix_per_word)
                n['rd_data'][resp_idx] = (ddr_out['rdata'][1] >> (pixel_in_word * self.pix_w)) & ((1 << self.pix_w) - 1)
                n['rd_completed'] = s['rd_completed'] | (1 << resp_idx)
                n['rd_resp_idx'] = s['rd_resp_idx'] + 1

                # Check completion: all 4 responses received
                if n['rd_completed'] == 0b1111:
                    n['rd_valid'] = True
                    n['rd_state'] = RD_IDLE

        # -----------------------------------------------------------------------
        # Buffer swap - matches RTL exactly
        # -----------------------------------------------------------------------
        if swap_buf:
            n['wr_buf'], n['rd_buf'] = n['rd_buf'], n['wr_buf']
            n['buf_swapped'] = True
            for i in range(self.cache_lines):
                if n['cache_buf_sel'][i] == n['rd_buf']:
                    n['cache_valid'][i] = False
            n['buf0_base_bytes'], n['buf1_base_bytes'] = n['buf1_base_bytes'], n['buf0_base_bytes']

        # -----------------------------------------------------------------------
        # Cache flush
        # -----------------------------------------------------------------------
        if cache_flush and not swap_buf:
            for i in range(self.cache_lines):
                n['cache_valid'][i] = False
            n['cache_flushed'] = True

        # -----------------------------------------------------------------------
        # Cache management on write (when wr_en && wr_ready && WR_IDLE)
        # -----------------------------------------------------------------------
        if wr_en and s['wr_ready'] and s['wr_state'] == WR_IDLE:
            row_base = (wr_addr // self.frame_width) * self.frame_width
            match_idx = -1
            for i in range(self.cache_lines):
                if (s['cache_valid'][i] and
                    s['cache_row_base_addr'][i] == row_base and
                    s['cache_buf_sel'][i] == s['wr_buf']):
                    match_idx = i
                    break

            if match_idx >= 0:
                col = wr_addr % self.frame_width
                n['cache_row_data'][match_idx][col] = wr_data
                # Update LRU
                for i in range(self.cache_lines):
                    if s['cache_lru_count'][i] >= 0 and i != match_idx:
                        n['cache_lru_count'][i] = s['cache_lru_count'][i] + 1
                    elif i == match_idx:
                        n['cache_lru_count'][i] = 0
            else:
                if wr_addr % self.frame_width == 0:
                    # Find LRU victim
                    victim = 0
                    max_lru = -1
                    for i in range(self.cache_lines):
                        if not s['cache_valid'][i] or s['cache_lru_count'][i] > max_lru:
                            max_lru = s['cache_lru_count'][i]
                            victim = i
                    n['cache_valid'][victim] = True
                    n['cache_row_base_addr'][victim] = row_base
                    n['cache_buf_sel'][victim] = s['wr_buf']
                    n['cache_row_data'][victim] = [0] * self.frame_width
                    col = wr_addr % self.frame_width
                    n['cache_row_data'][victim][col] = wr_data
                    # Update LRU
                    for i in range(self.cache_lines):
                        if s['cache_lru_count'][i] >= 0 and i != victim:
                            n['cache_lru_count'][i] = s['cache_lru_count'][i] + 1
                        elif i == victim:
                            n['cache_lru_count'][i] = 0

        # -----------------------------------------------------------------------
        # Compute registered outputs for NEXT state
        # -----------------------------------------------------------------------
        n['wr_ready'] = (s['wr_state'] == WR_IDLE)
        n['wr_fill'] = 1 if s['wr_state'] == WR_IDLE else s['wr_fill']
        n['rd_ready'] = (s['rd_state'] == RD_IDLE)
        if s['rd_state'] == RD_IDLE:
            n['rd_fill'] = 1 if rd_en else 0
        elif s['rd_state'] in (RD_ISSUE, RD_WAIT):
            n['rd_fill'] = 2
        else:
            n['rd_fill'] = s['rd_fill']

        # Store idle
        store_idle = (n['wr_state'] == WR_IDLE and n['rd_state'] == RD_IDLE and
                      not n['wr_burst_active'] and (n['rd_issued'] == n['rd_completed']))

        # ===== UPDATE REGISTERED STATE =====
        self.s = n

        # ===== RETURN REGISTERED OUTPUTS FOR THIS CLOCK EDGE =====
        return {
            'wr_ready': wr_ready_out,
            'rd_ready': rd_ready_out,
            'rd_valid': rd_valid_out,
            'rd_data0': rd_data_out[0],
            'rd_data1': rd_data_out[1],
            'rd_data2': rd_data_out[2],
            'rd_data3': rd_data_out[3],
            'buf_swapped': buf_swapped_out,
            'cache_flushed': cache_flushed_out,
            'store_idle': store_idle,
            'wr_fill': wr_fill_out,
            'rd_fill': rd_fill_out,
        }

    def reset(self):
        self.s = {
            'wr_state': WR_IDLE,
            'wr_addr_next': 0,
            'wr_pixel_count': 0,
            'wr_pack_cnt': 0,
            'wr_pack_data': 0,
            'wr_pack_strb': 0,
            'wr_burst_active': False,
            'wr_burst_len': 0,
            'wr_burst_addr': 0,
            'wr_ready': True,
            'wr_fill': 1,

            'rd_state': RD_IDLE,
            'rd_addr_idx': 0,
            'rd_resp_idx': 0,
            'rd_issued': 0,
            'rd_completed': 0,
            'rd_valid': False,
            'rd_data': [0, 0, 0, 0],
            'rd_ready': True,
            'rd_fill': 0,
            'rd_pixel_count': 0,
            'rd_addrs': [0, 0, 0, 0],
            'rd_buf_q_latched': 1,

            'wr_buf': 0,
            'rd_buf': 1,
            'buf0_base_bytes': 0,
            'buf1_base_bytes': self.frame_bytes,
            'frame0_written': False,
            'frame1_written': False,

            'cache_valid': [False] * self.cache_lines,
            'cache_row_base_addr': [0] * self.cache_lines,
            'cache_buf_sel': [0] * self.cache_lines,
            'cache_row_data': [[0] * self.frame_width for _ in range(self.cache_lines)],
            'cache_lru_count': [0] * self.cache_lines,

            'prev_ddr_out': None,

            'buf_swapped': False,
            'cache_flushed': False,
        }
        self.ddr_ctrl.reset()
