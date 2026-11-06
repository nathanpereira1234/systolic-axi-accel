"""Shared helpers for the cocotb tests."""
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# Make model/golden.py importable
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "model")))

CLK_PERIOD_NS = 10


async def start_clock_and_reset(dut, cycles=5):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    await Timer(1, unit="ns")
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def array_size():
    return int(os.environ.get("ACCEL_N", "4"))
