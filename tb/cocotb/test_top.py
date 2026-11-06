"""System-level tests for accel_top through its AXI4-Lite interface.

Uses cocotbext-axi's AxiLiteMaster as the bus driver.
"""
import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge
from cocotbext.axi import AxiLiteBus, AxiLiteMaster

from common import array_size, start_clock_and_reset
from golden import (const_matrix, identity, matmul, pack_row, random_matrix)

CTRL, STATUS, DIM = 0x000, 0x004, 0x008
A_BASE, B_BASE, C_BASE = 0x100, 0x200, 0x300
OKAY, SLVERR = 0, 2


class Accel:
    def __init__(self, dut):
        self.dut = dut
        self.n = array_size()
        self.axil = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axil"), dut.clk, dut.rst_n,
                                  reset_active_level=False)
        self.axil.write_if.log.setLevel("WARNING")
        self.axil.read_if.log.setLevel("WARNING")

    async def write(self, addr, value, strb=0xF):
        data = value.to_bytes(4, "little")
        if strb != 0xF:
            # Partial write: only send the enabled bytes
            first = (strb & -strb).bit_length() - 1
            last = strb.bit_length() - 1
            resp = await self.axil.write(addr + first, data[first:last + 1])
        else:
            resp = await self.axil.write(addr, data)
        return int(resp.resp)

    async def read(self, addr):
        resp = await self.axil.read(addr, 4)
        return int.from_bytes(resp.data, "little"), int(resp.resp)

    async def load(self, a, b):
        for i in range(self.n):
            assert await self.write(A_BASE + 4 * i, pack_row(a[i])) == OKAY
            assert await self.write(B_BASE + 4 * i, pack_row(b[i])) == OKAY

    async def start(self, irq_en=0):
        return await self.write(CTRL, 0x1 | (irq_en << 2))

    async def wait_done(self, timeout=200):
        for _ in range(timeout):
            status, _ = await self.read(STATUS)
            if status & 0x2:
                assert await self.write(STATUS, 0x2) == OKAY   # W1C DONE
                return
        raise AssertionError("timeout waiting for DONE")

    async def read_c(self):
        c = [[0] * self.n for _ in range(self.n)]
        for i in range(self.n):
            for j in range(self.n):
                v, resp = await self.read(C_BASE + 4 * (i * self.n + j))
                assert resp == OKAY
                c[i][j] = v - (1 << 32) if v & 0x80000000 else v
        return c

    async def matmul(self, a, b):
        await self.load(a, b)
        assert await self.start() == OKAY
        await self.wait_done()
        got = await self.read_c()
        exp = matmul(a, b)
        assert got == exp, f"\nA={a}\nB={b}\nexpected {exp}\ngot      {got}"


async def setup(dut):
    for sig in ("awprot", "arprot"):
        getattr(dut, f"s_axil_{sig}").value = 0
    acc = Accel(dut)
    await start_clock_and_reset(dut)
    return acc


@cocotb.test()
async def test_smoke(dut):
    acc = await setup(dut)
    v, resp = await acc.read(DIM)
    assert (v, resp) == (acc.n, OKAY)
    n = acc.n
    a = [[i * n + j + 1 for j in range(n)] for i in range(n)]
    await acc.matmul(a, identity(n))


@cocotb.test()
async def test_random(dut):
    acc = await setup(dut)
    for _ in range(50):
        await acc.matmul(random_matrix(acc.n), random_matrix(acc.n))


@cocotb.test()
async def test_corners(dut):
    acc = await setup(dut)
    n = acc.n
    for a, b in [(const_matrix(n, 0), const_matrix(n, 0)),
                 (const_matrix(n, -128), const_matrix(n, -128)),
                 (const_matrix(n, 127), const_matrix(n, -128)),
                 (identity(n), random_matrix(n))]:
        await acc.matmul(a, b)


@cocotb.test()
async def test_back_to_back(dut):
    """START again right after a run, without clearing DONE first."""
    acc = await setup(dut)
    for _ in range(5):
        a, b = random_matrix(acc.n), random_matrix(acc.n)
        await acc.load(a, b)
        assert await acc.start() == OKAY
        while not ((await acc.read(STATUS))[0] & 0x2):
            pass
        assert await acc.start() == OKAY   # DONE still set: must be accepted
        await acc.wait_done()
        assert await acc.read_c() == matmul(a, b)


@cocotb.test()
async def test_busy_access(dut):
    """Each illegal access, issued right after START, must get SLVERR and leave the result intact."""
    acc = await setup(dut)
    n = acc.n

    async def wr_a():
        return await acc.write(A_BASE, 0x01010101)

    async def wr_b():
        return await acc.write(B_BASE + 4 * (n - 1), 0x01010101)

    async def wr_ctrl():
        return await acc.write(CTRL, 0x1)

    async def rd_c():
        return (await acc.read(C_BASE))[1]

    for name, access in (("write A", wr_a), ("write B", wr_b), ("write CTRL", wr_ctrl), ("read C", rd_c)):
        a, b = random_matrix(n), random_matrix(n)
        await acc.load(a, b)
        assert await acc.start() == OKAY
        assert await access() == SLVERR, f"{name} while BUSY was not rejected"
        await acc.wait_done()
        assert await acc.read_c() == matmul(a, b), f"{name} while BUSY corrupted the result"


@cocotb.test()
async def test_errors(dut):
    """Unmapped addresses, misaligned accesses and writes to read-only registers."""
    acc = await setup(dut)
    n = acc.n
    for addr in (0x00C, 0x0FC, A_BASE + 4 * n, B_BASE + 4 * n, C_BASE + 4 * n * n, 0x400, 0xFFC):
        assert await acc.write(addr, 0xDEADBEEF) == SLVERR, f"write {addr:#x}"
        _, resp = await acc.read(addr)
        assert resp == SLVERR, f"read {addr:#x}"
    assert await acc.write(DIM, 7) == SLVERR
    assert await acc.write(C_BASE, 7) == SLVERR
    # Registers still sane after errors
    v, resp = await acc.read(DIM)
    assert (v, resp) == (n, OKAY)


@cocotb.test()
async def test_wstrb(dut):
    """Byte-enable writes to A only change the enabled bytes."""
    acc = await setup(dut)
    if acc.n < 2:
        return
    assert await acc.write(A_BASE, 0x44332211) == OKAY
    assert await acc.write(A_BASE, 0x0000BB00, strb=0x2) == OKAY
    v, _ = await acc.read(A_BASE)
    mask = (1 << (8 * acc.n)) - 1
    assert v == (0x4433BB11 & mask), f"got {v:#x}"


@cocotb.test()
async def test_irq(dut):
    acc = await setup(dut)
    await acc.load(random_matrix(acc.n), random_matrix(acc.n))
    assert int(dut.irq.value) == 0
    assert await acc.start(irq_en=1) == OKAY
    for _ in range(100):
        await RisingEdge(dut.clk)
        if int(dut.irq.value):
            break
    assert int(dut.irq.value) == 1, "IRQ did not assert"
    assert await acc.write(STATUS, 0x2) == OKAY
    await ClockCycles(dut.clk, 2)
    assert int(dut.irq.value) == 0, "IRQ did not clear with DONE"
