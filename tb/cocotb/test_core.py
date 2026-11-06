"""Tests accel_core (FSM + skew + systolic array) directly, without AXI."""
import random

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from common import array_size, start_clock_and_reset
from golden import (const_matrix, identity, matmul, pack_matrix, random_matrix,
                    unpack_matrix)


async def init(dut):
    dut.start.value = 0
    dut.clear_c.value = 0
    dut.a_mat.value = 0
    dut.b_mat.value = 0
    await start_clock_and_reset(dut)


async def run(dut, a, b, n):
    await FallingEdge(dut.clk)
    dut.a_mat.value = pack_matrix(a)
    dut.b_mat.value = pack_matrix(b)
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    cycles = 0
    while True:
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        cycles += 1
        if int(dut.done_pulse.value):
            break
        assert cycles < 10 * n + 20, "timeout waiting for done_pulse"
    got = unpack_matrix(int(dut.c_mat.value), n)
    exp = matmul(a, b)
    assert got == exp, f"\nA={a}\nB={b}\nexpected {exp}\ngot      {got}"
    return cycles


@cocotb.test()
async def test_core_random(dut):
    n = array_size()
    await init(dut)
    for _ in range(100):
        await run(dut, random_matrix(n), random_matrix(n), n)


@cocotb.test()
async def test_core_corners(dut):
    n = array_size()
    await init(dut)
    cases = [
        (const_matrix(n, 0), random_matrix(n)),
        (identity(n), random_matrix(n)),
        (random_matrix(n), identity(n)),
        (const_matrix(n, -128), const_matrix(n, -128)),
        (const_matrix(n, 127), const_matrix(n, -128)),
        (const_matrix(n, 127), const_matrix(n, 127)),
    ]
    for a, b in cases:
        await run(dut, a, b, n)


@cocotb.test()
async def test_core_latency(dut):
    """Start-to-done_pulse latency must be 3N cycles (LOAD + 3N-2 COMPUTE + DRAIN)."""
    n = array_size()
    await init(dut)
    cycles = await run(dut, random_matrix(n), random_matrix(n), n)
    dut._log.info("N=%d start-to-done latency: %d cycles", n, cycles)
    assert cycles == 3 * n, f"latency {cycles}, expected {3 * n}"
