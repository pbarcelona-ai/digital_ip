import os
import sys
from cocotb_tools.runner import get_runner

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(THIS_DIR, '..', 'src')
MODEL_DIR = os.path.join(THIS_DIR, '..', 'model')
TB_DIR = os.path.join(THIS_DIR, '..', 'tb')
LIB_DIR = os.path.join(THIS_DIR, '..', '..', '..', '..', '..', 'ip')
IF_DIR = os.path.join(LIB_DIR, 'shared', 'src', 'interfaces')
DDR_DIR = os.path.join(LIB_DIR, 'memory')

IFACES = [
    os.path.join(IF_DIR, 'axil_if.sv'),
    os.path.join(IF_DIR, 'frame_store_if.sv'),
    os.path.join(DDR_DIR, 'ddr_ctrl', 'src', 'include', 'ddr_ctrl_regs_if.sv'),
]

DDR_SRCS = [
    os.path.join(DDR_DIR, 'ddr_ctrl', 'src', 'ddr_ctrl.sv'),
    os.path.join(DDR_DIR, 'ddr_mem', 'src', 'ddr_mem.sv'),
]

FIFO_SRCS = [
    os.path.join(LIB_DIR, 'fifo', 'fallthrough_fifo', 'src', 'fallthrough_fifo.sv'),
]

DUT_SRC = os.path.join(SRC_DIR, 'frame_store_ddr.sv')
TOP = 'frame_store_ddr_cocotb_top'
TB_TOP = os.path.join(TB_DIR, f'{TOP}.sv')

sources = IFACES + DDR_SRCS + FIFO_SRCS + [DUT_SRC, TB_TOP]

runner = get_runner('icarus')
runner.build(
    sources=sources,
    hdl_toplevel=TOP,
    always=True,
    timescale=('1ns', '1ps'),
    parameters={
        'FRAME_WIDTH': '8',
        'FRAME_HEIGHT': '8',
        'CACHE_LINES': '4',
        'CACHE_LINE_W': '6',
        'DDR_DATA_W': '64',
        'DDR_ADDR_W': '18',
        'DDR_ID_W': '2',
        'DDR_BANK_W': '2',
        'DDR_ROW_W': '8',
        'DDR_COL_W': '4',
        'DDR_MEM_WORDS': '4096',
        'PIX_W': '16',
        'DDR_REF_MAX': '576',
    },
)

runner.test(
    hdl_toplevel=TOP,
    test_module='debug_ddr_ctrl',
    test_dir=TB_DIR,
    testcase='test_ddr_ctrl_debug_writes',
)

