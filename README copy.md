# Systolic-Array Matrix-Multiply Accelerator (AXI4-Lite) — RTL + UVM

A parameterizable INT8 systolic-array matrix multiplier (N x N, N = 1..4, default 4) with an AXI4-Lite
register interface, written in SystemVerilog and verified two ways:

- **cocotb** (Python) unit and system tests that run on free tools (Icarus Verilog), locally, in GitHub
  Codespaces, or in GitHub Actions CI.
- A **UVM** testbench (agent, scoreboard with reference model, functional coverage, bound SVA) for
  commercial simulators on EDA Playground.

```
             AXI4-Lite
  master ──────────────────► axil_slave ──a_mat, b_mat──► accel_core
                             (regs, decode,  ◄──c_mat───   ├─ control FSM
                              SLVERR, irq)  ──start────►   ├─ input skew
                                            ◄─busy/done─   └─ systolic_array (N x N pe)
```

## Repository layout

```
rtl/            pe.sv  systolic_array.sv  accel_core.sv  axil_slave.sv  accel_top.sv  sync_fifo.sv
tb/cocotb/      test_pe.py  test_fifo.py  test_core.py  test_top.py  test_runner.py  common.py
tb/uvm/         axil_if.sv  accel_tb_pkg.sv  accel_sva.sv  tb_top.sv
model/          golden.py           (Python reference model used by cocotb)
eda_playground/ design.sv  testbench.sv   (generated; paste into EDA Playground)
scripts/        build_eda_playground.sh  synth.ys
fpga/           vivado_ooc.tcl  accel_ooc.xdc   (Vivado synthesis + timing, no board needed)
docs/           regmap.md  vplan.md  bug_log.md
.github/workflows/ci.yml
```

`sync_fifo.sv` is a standalone block with its own test (FIFO design is a classic interview question);
it is not used inside `accel_top`.

## How it works

`pe.sv` multiplies two signed INT8 values and adds the product into a signed 32-bit accumulator, passing
A to the right and B downward each cycle. `systolic_array.sv` builds the N x N grid. `accel_core.sv`
skews the inputs (row r receives A[r][k] and column r receives B[k][r] when the cycle count t = r + k),
so PE(i,j) sees matching A[i][k] and B[k][j]. The last product reaches PE(N-1,N-1) at t = 3N-3, so
compute takes 3N-2 cycles. FSM: IDLE → LOAD (clear) → COMPUTE → DRAIN (copy to C buffer) → DONE.

Register map: see [docs/regmap.md](docs/regmap.md). Short version: A rows at 0x100, B rows at 0x200,
C at 0x300, CTRL at 0x000 (START, CLR_C, IRQ_EN), STATUS at 0x004 (BUSY, DONE W1C), DIM at 0x008.

---

## Step 1 — Get the code into GitHub

1. Create an empty repo on GitHub named `systolic-axi-accel`.
2. Unzip this project, then from inside the folder:

```bash
git init
git add .
git commit -m "Systolic-array AXI4-Lite accelerator with cocotb and UVM testbenches"
git branch -M main
git remote add origin https://github.com/<your-username>/systolic-axi-accel.git
git push -u origin main
```

The CI workflow in `.github/workflows/ci.yml` runs lint, all cocotb tests (N = 1..4) and Yosys
synthesis on every push. Check the **Actions** tab; a green tick there is a nice README badge later.

## Step 2 — Run the cocotb tests (free tools)

### Option A: fully online with GitHub Codespaces

On your repo page click **Code → Codespaces → Create codespace on main**. In its terminal:

```bash
sudo apt-get update && sudo apt-get install -y iverilog verilator yosys
pip install -r requirements.txt
make lint          # Verilator -Wall, should print nothing but the commands
make test          # 4 groups of cocotb tests on Icarus
make test-all-n    # repeat for N = 1, 2, 3, 4
```

### Option B: local Linux or WSL (Ubuntu)

Same commands as above. On Windows, install WSL first (`wsl --install` in an admin PowerShell),
open Ubuntu, and work inside your Linux home folder.

### What the tests cover

| Test file | Top | What it checks |
| --- | --- | --- |
| `test_pe.py` | `pe` | 500+ random signed products, -128 x -128, accumulator wrap, forwarding, clear |
| `test_fifo.py` | `sync_fifo` | 2000 random push/pop cycles vs a Python deque, full/empty/count |
| `test_core.py` | `accel_core` | 100 random matmuls, corner matrices, latency = 3N cycles |
| `test_top.py` | `accel_top` | Through AXI: smoke, 50 random, corners, back-to-back, accesses while BUSY → SLVERR, illegal addresses, WSTRB partial writes, IRQ |

Useful options:

```bash
ACCEL_N=2 make test     # a different array size
make waves              # dump waveforms (tb/cocotb/sim_build/*/) - open with GTKWave or https://app.surfer-project.org
SIM=verilator make test # only with Verilator >= 5.036 (Ubuntu 24.04's apt package is 5.020; use Icarus there)
```

## Step 3 — Run the UVM testbench on EDA Playground (free, in the browser)

1. Regenerate the two paste-in files if you changed anything: `make eda`
   (writes `eda_playground/design.sv` and `eda_playground/testbench.sv`).
2. Go to <https://www.edaplayground.com> and log in (free account; commercial simulators need a login).
3. Left panel settings:
   - **Testbench + Design:** SystemVerilog/Verilog
   - **UVM / OVM:** UVM 1.2
   - **Tools & Simulators:** Synopsys VCS (or Cadence Xcelium, or Aldec Riviera-PRO)
   - **Run Options:** `+UVM_TESTNAME=full_regression_test +NUM_ITERS=60`
   - Tick **Open EPWave after run** if you want waveforms.
4. Paste `eda_playground/testbench.sv` into the left editor pane (testbench.sv) and
   `eda_playground/design.sv` into the right pane (design.sv).
5. Click **Run**. At the end of the log look for:
   - `---- Scoreboard summary ----` with `total errors : 0`
   - `---- Functional coverage ----` percentages
   - `UVM_ERROR : 0` and `UVM_FATAL : 0` in the report summary
6. Click **Save** and copy the public link for your README.

Tests (set with `+UVM_TESTNAME=`):

| Test | What it runs |
| --- | --- |
| `smoke_test` | One random A times identity |
| `random_test` | `NUM_ITERS` (default 100) random matmuls |
| `corner_test` | Zero, identity, all -128, all +127, mixed extremes, small values |
| `back2back_test` | START again as soon as DONE is seen, without clearing DONE |
| `busy_access_test` | One illegal access (write A/B/CTRL, read C) right after START; expects SLVERR and an intact result |
| `error_test` | Unmapped and past-the-end addresses, read-only writes, partial WSTRB writes with readback |
| `full_regression_test` | All of the above mixed randomly — use this for coverage |

Random seeds: add `+ntb_random_seed=<n>` (VCS), `-svseed <n>` (Xcelium) or `-sv_seed <n>` (Riviera) to
Run Options and repeat with 5+ different seeds. Keep `NUM_ITERS` modest (about 60–200) because EDA
Playground limits how long one run may take.

Structure of the UVM environment:

- `axil_item` — one AXI4-Lite read or write, with random AW/W order and delays and random B/R ready delays
- `axil_driver` / `axil_monitor` / `axil_agent` — the monitor rebuilds transactions purely from the bus
- `accel_scoreboard` — mirrors A, B, IRQ_EN; computes expected C with `ref_matmul` on every accepted START;
  checks every C read, register readback and response code
- `accel_coverage` — register/direction/response crosses, WSTRB patterns, operand value bins
- `accel_sva.sv` — AXI handshake stability, every response follows a request, legal FSM states,
  START never reaches a busy core, START always leads to DONE; FSM transition covergroup (bound, so RTL is untouched)

## Step 4 — Synthesis numbers

**Yosys (free, in Codespaces):** `make synth` → generic gate count in `synth_report.txt`.

**Vivado (Artix-7 area and Fmax, no board needed):** needs the Vivado install and the free Basic licence.

```bash
vivado -mode batch -source fpga/vivado_ooc.tcl
# or another part / size:
vivado -mode batch -source fpga/vivado_ooc.tcl -tclargs xc7a100tcsg324-1 4
```

On Windows: open **Vivado Tcl Shell** from the Start menu, `cd` to the project folder (use forward
slashes, e.g. `cd C:/Users/you/systolic-axi-accel`), then `source fpga/vivado_ooc.tcl`.
It prints WNS and an estimated Fmax and writes utilization, timing and power reports to `fpga/reports/`.
To push Fmax, lower the period in `fpga/accel_ooc.xdc` (e.g. 6.667 ns = 150 MHz) and rerun. If timing
fails, the usual fix is a pipeline register between the multiplier and the accumulator in `pe.sv`.

## Step 5 — Make it yours (important)

This is a working reference. Before you put it on your CV or talk about it in an interview, make sure
you can explain every line, and extend it so the work is genuinely yours. Good extensions:

- Add a pipeline stage in `pe.sv` and adjust the COMPUTE length; report the Fmax gain.
- Replace polling with an interrupt-driven sequence in UVM.
- Add a UVM register model (`uvm_reg_block`) and a frontdoor adapter for the AXI agent.
- Swap the SystemVerilog reference model for the Python one via DPI-C.
- Support N up to 8 (two words per row) and update the decode.
- Run it on an FPGA with MicroBlaze/Zynq, or harden it with LibreLane for Tiny Tapeout (needs a
  narrow serial wrapper because a Tiny Tapeout tile has few I/O pins).

Log every bug your tests find in `docs/bug_log.md`, and keep `docs/vplan.md` up to date.

## Resume line (fill in your numbers)

> Designed a parameterizable INT8 systolic-array matrix-multiply accelerator with an AXI4-Lite interface
> in SystemVerilog; verified it with a UVM testbench (constrained-random AXI agent, scoreboard with
> reference model, SVA protocol checks, functional coverage at X%) on Synopsys VCS and cocotb regression
> in CI; synthesized for Artix-7 at X MHz using X LUTs.
