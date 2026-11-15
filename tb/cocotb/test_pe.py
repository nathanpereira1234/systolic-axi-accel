"""Unit test for a single processing element (rtl/pe.sv)."""
import random

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from common import start_clock_and_reset
from golden import wrap32


async def init(dut):
    dut.clr.value = 0
    dut.en.value = 0
    dut.a_in.value = 0
    dut.b_in.value = 0
    await start_clock_and_reset(dut)


@cocotb.test()
async def test_accumulate_random(dut):
    """Random signed pairs, including corner values; check acc and forwarding."""
    await init(dut)
    pairs = [(-128, -128), (127, 127), (-128, 127), (0, -128)]
    pairs += [(random.randint(-128, 127), random.randint(-128, 127)) for _ in range(500)]

    # acc lags the operands by one cycle (product register), so after accepting
    # pair i we check that acc holds the sum of pairs 0..i-1.
    expected = 0
    prev = None
    for a, b in pairs + [(0, 0)]:
        await FallingEdge(dut.clk)
        dut.en.value = 1
        dut.a_in.value = a
        dut.b_in.value = b
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        if prev is not None:
            expected = wrap32(expected + prev[0] * prev[1])
        assert dut.acc.value.to_signed() == expected, f"acc {dut.acc.value.to_signed()} != {expected}"
        assert dut.a_out.value.to_signed() == a, "A not forwarded"
        assert dut.b_out.value.to_signed() == b, "B not forwarded"
        prev = (a, b)
        dut.en.value = 0                    # idle cycle between pairs, as before


@cocotb.test()
async def test_clear_and_hold(dut):
    """acc holds when en=0 and clears on clr."""
    await init(dut)
    await FallingEdge(dut.clk)
    dut.en.value = 1
    dut.a_in.value = -7
    dut.b_in.value = 9
    await FallingEdge(dut.clk)
    dut.en.value = 0
    for _ in range(3):                      # one cycle to accumulate, then hold
        await FallingEdge(dut.clk)
    assert dut.acc.value.to_signed() == -63
    dut.clr.value = 1
    await FallingEdge(dut.clk)
    dut.clr.value = 0
    assert dut.acc.value.to_signed() == 0
    assert dut.a_out.value.to_signed() == 0
