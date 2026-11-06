# Register map

AXI4-Lite slave, 12-bit address, 32-bit data. `addr[1:0]` is ignored; byte lanes are selected by `WSTRB`.
Shown for the default N = 4 (N may be 1 to 4).

| Offset | Name | Access | Fields / behaviour |
| --- | --- | --- | --- |
| 0x000 | CTRL | RW | bit0 START (self-clearing, reads 0), bit1 CLR_C (self-clearing: zero the C buffer), bit2 IRQ_EN. Any write while BUSY returns SLVERR and has no effect. START also clears STATUS.DONE. |
| 0x004 | STATUS | RO / W1C | bit0 BUSY, bit1 DONE (write 1 to clear). |
| 0x008 | DIM | RO | N. Writes return SLVERR. |
| 0x100 + 4*i | A_BUF[i] | RW | Row i of A. Byte k = A[i][k] (signed INT8). Write while BUSY returns SLVERR. |
| 0x200 + 4*k | B_BUF[k] | RW | Row k of B. Byte j = B[k][j] (signed INT8). Write while BUSY returns SLVERR. |
| 0x300 + 4*(i*N+j) | C_BUF[i][j] | RO | C[i][j], signed 32-bit (two's-complement wrap). Read while BUSY returns SLVERR. Writes return SLVERR. |
| anything else | — | — | SLVERR on read and write. |

`irq` output = STATUS.DONE AND CTRL.IRQ_EN.

## Programming sequence

1. Write A_BUF[0..N-1] and B_BUF[0..N-1].
2. Write CTRL = 0x1 (or 0x5 to enable the interrupt).
3. Poll STATUS until DONE = 1 (or wait for `irq`).
4. Write STATUS = 0x2 to clear DONE.
5. Read C_BUF[0..N*N-1].

## Timing

From the cycle the core sees START to its done pulse takes 3N cycles (LOAD 1 + COMPUTE 3N-2 + DRAIN 1),
plus 1 cycle for the CTRL write to reach the core. For N = 4 that is about 13 cycles.
