"""Unit test for the synchronous FIFO (rtl/sync_fifo.sv) against a Python deque."""
import random
from collections import deque

import cocotb
from cocotb.triggers import FallingEdge

from common import start_clock_and_reset

DEPTH = 8


@cocotb.test()
async def test_fifo_random(dut):
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    await start_clock_and_reset(dut)

    model = deque()
    pending_read = None
    for cycle in range(2000):
        await FallingEdge(dut.clk)
        # Check the value read on the previous edge
        if pending_read is not None:
            got = int(dut.rd_data.value)
            assert got == pending_read, f"cycle {cycle}: read {got:#x}, expected {pending_read:#x}"
            pending_read = None

        assert int(dut.empty.value) == (len(model) == 0)
        assert int(dut.full.value) == (len(model) == DEPTH)
        assert int(dut.count.value) == len(model)

        # Bias toward filling in the first half and draining in the second
        p_wr = 0.7 if cycle < 1000 else 0.3
        wr = random.random() < p_wr
        rd = random.random() < (1 - p_wr)
        data = random.getrandbits(32)
        dut.wr_en.value = int(wr)
        dut.rd_en.value = int(rd)
        dut.wr_data.value = data

        do_rd = rd and len(model) > 0
        do_wr = wr and len(model) < DEPTH
        if do_rd:
            pending_read = model.popleft()
        if do_wr:
            model.append(data)
