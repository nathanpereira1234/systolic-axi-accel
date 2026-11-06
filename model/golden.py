"""Golden reference model for the systolic-array accelerator.

Pure Python so it runs anywhere (cocotb tests import it). Matches the RTL:
signed INT8 operands, signed 32-bit accumulation with two's-complement wrap.
"""
import random

INT8_MIN, INT8_MAX = -128, 127


def wrap32(x: int) -> int:
    """Wrap an integer to signed 32-bit, like the hardware accumulator."""
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def matmul(a, b):
    """C = A x B for square lists-of-lists."""
    n = len(a)
    return [[wrap32(sum(a[i][k] * b[k][j] for k in range(n))) for j in range(n)]
            for i in range(n)]


def random_matrix(n, rng=random, lo=INT8_MIN, hi=INT8_MAX):
    return [[rng.randint(lo, hi) for _ in range(n)] for _ in range(n)]


def const_matrix(n, v):
    return [[v] * n for _ in range(n)]


def identity(n):
    return [[1 if i == j else 0 for j in range(n)] for i in range(n)]


def pack_row(row):
    """Pack one matrix row into a 32-bit register value (byte k = row[k])."""
    word = 0
    for k, v in enumerate(row):
        word |= (v & 0xFF) << (8 * k)
    return word


def pack_matrix(m, width=8):
    """Pack a matrix into the flat bus used by accel_core (element (r,c) at (r*N+c)*width)."""
    n = len(m)
    val = 0
    for r in range(n):
        for c in range(n):
            val |= (m[r][c] & ((1 << width) - 1)) << ((r * n + c) * width)
    return val


def unpack_matrix(val, n, width=32):
    out = [[0] * n for _ in range(n)]
    mask = (1 << width) - 1
    for r in range(n):
        for c in range(n):
            x = (val >> ((r * n + c) * width)) & mask
            out[r][c] = x - (1 << width) if x >> (width - 1) else x
    return out


if __name__ == "__main__":
    A = random_matrix(4)
    B = random_matrix(4)
    print("A =", A)
    print("B =", B)
    print("C =", matmul(A, B))
