"""pytest entry point: builds and runs every cocotb test.

Usage (from the repo root):
    pytest -v tb/cocotb/test_runner.py            # Icarus (default)
    SIM=verilator pytest -v tb/cocotb/test_runner.py
    ACCEL_N=2 pytest -v tb/cocotb/test_runner.py   # other array size (1..4)
    WAVES=1 pytest -v tb/cocotb/test_runner.py     # dump waveforms
"""
import os
from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "rtl"
TB = Path(__file__).resolve().parent
SIM = os.environ.get("SIM", "icarus")
N = int(os.environ.get("ACCEL_N", "4"))
WAVES = os.environ.get("WAVES", "0") == "1"

SOURCES = {
    "pe": ["pe.sv"],
    "sync_fifo": ["sync_fifo.sv"],
    "accel_core": ["pe.sv", "systolic_array.sv", "accel_core.sv"],
    "accel_top": ["pe.sv", "systolic_array.sv", "accel_core.sv", "axil_slave.sv", "accel_top.sv"],
}


def _run(toplevel, module, parameters=None):
    runner = get_runner(SIM)
    build_args = ["--timing", "-Wno-fatal"] if SIM == "verilator" else []
    if SIM == "verilator" and WAVES:
        build_args.append("--trace-fst")
    build_dir = TB / "sim_build" / f"{toplevel}_N{N}_{SIM}"
    runner.build(
        sources=[RTL / f for f in SOURCES[toplevel]],
        hdl_toplevel=toplevel,
        parameters=parameters or {},
        build_args=build_args,
        build_dir=build_dir,
        timescale=("1ns", "1ps"),
        waves=WAVES,
        always=True,
    )
    runner.test(
        hdl_toplevel=toplevel,
        test_module=module,
        test_dir=TB,
        build_dir=build_dir,
        extra_env={"ACCEL_N": str(N)},
        waves=WAVES,
    )


def test_pe():
    _run("pe", "test_pe")


def test_fifo():
    _run("sync_fifo", "test_fifo", {"WIDTH": 32, "DEPTH": 8})


def test_core():
    _run("accel_core", "test_core", {"N": N})


def test_top():
    _run("accel_top", "test_top", {"N": N})
