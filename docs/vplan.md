# Verification plan

DUT: `accel_top` (AXI4-Lite systolic-array matrix multiplier), N = 4 unless noted.
Checks: **SB** = UVM scoreboard, **SVA** = assertion (`tb/uvm/accel_sva.sv`), **COV** = functional coverage,
**CT** = cocotb test (`tb/cocotb/`).

| # | Feature | Stimulus | Check | Coverage goal |
| --- | --- | --- | --- | --- |
| 1 | Matrix multiply correctness | Random signed INT8 matrices | SB vs `ref_matmul`; CT vs `golden.py` | 100+ random runs |
| 2 | Operand corner values | All -128, all +127, mixed extremes, zeros, identity, small values | SB | `cg_operand` all 5 bins |
| 3 | Accumulator sign handling | -128 x -128 sums, +127 x -128 | SB, CT `test_corners` | covered by #2 |
| 4 | A/B buffer write/readback | Full and partial (WSTRB) writes, readback | SB mirror compare | `cg_strb` full/single/partial |
| 5 | CTRL / IRQ_EN readback | Writes with IRQ_EN 0/1, CTRL reads | SB | `x_region_dir` CTRL |
| 6 | DONE / IRQ behaviour | Poll STATUS, W1C, irq_en | SB (STATUS resp), CT `test_irq` | — |
| 7 | Back-to-back runs | START again while DONE still set | SB | FSM bin `b2b` |
| 8 | Accesses while BUSY | A/B/CTRL writes, C reads right after START | SB (SLVERR, result intact), SVA `a_no_start_when_busy`, CT `test_busy_access` | `x_region_resp` SLVERR for A, B, CTRL, C |
| 9 | Illegal addresses | Unmapped, past-the-end, RO writes | SB expects SLVERR | `x_region_resp` unmapped/SLVERR |
| 10 | AXI handshake rules | Random AW/W order and delays, random B/R ready delays | SVA `a_*_stable`, `a_b_after_aw_w`, `a_r_after_ar` | `c_aw_before_w`, `c_w_before_aw`, `c_aw_w_together`, `c_b_backpressure` |
| 11 | FSM legality | All tests | SVA `a_state_legal`, `a_done_after_drain`, `a_start_leads_to_done` | `cg_fsm` states and transitions |
| 12 | Latency | Single run | CT `test_core_latency` (3N cycles to done_pulse) | — |
| 13 | Parameterization | N = 1, 2, 3, 4 | CT `make test-all-n` | all four sizes pass |

Sign-off criteria: all tests pass on 5+ seeds, zero SVA failures, functional coverage at 100%
(or every hole explained in the README).
