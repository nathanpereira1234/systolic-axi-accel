# Convenience targets. Run from the repo root.
RTL := rtl/pe.sv rtl/systolic_array.sv rtl/accel_core.sv rtl/axil_slave.sv rtl/accel_top.sv
SIM ?= icarus

.PHONY: help lint test test-all-n waves synth eda vivado clean

help:
	@echo "make lint        - Verilator lint (-Wall) of the RTL"
	@echo "make test        - all cocotb tests (SIM=icarus default, SIM=verilator needs Verilator >= 5.036)"
	@echo "make test-all-n  - cocotb tests for array sizes N = 1, 2, 3, 4"
	@echo "make waves       - tests with waveform dump (open the .fst/.vcd in GTKWave or Surfer)"
	@echo "make synth       - Yosys generic synthesis, writes synth_report.txt"
	@echo "make eda         - regenerate eda_playground/design.sv and testbench.sv"
	@echo "make vivado      - Vivado out-of-context synthesis + P&R + timing (needs Vivado)"

lint:
	verilator --lint-only -Wall -Irtl $(RTL) --top-module accel_top
	verilator --lint-only -Wall rtl/sync_fifo.sv

test:
	SIM=$(SIM) python3 -m pytest -v tb/cocotb/test_runner.py

test-all-n:
	for n in 1 2 3 4; do ACCEL_N=$$n SIM=$(SIM) python3 -m pytest -q tb/cocotb/test_runner.py || exit 1; done

waves:
	WAVES=1 SIM=$(SIM) python3 -m pytest -v tb/cocotb/test_runner.py

synth:
	yosys -q -s scripts/synth.ys
	@grep -E "Number of cells|DFF" synth_report.txt

eda:
	./scripts/build_eda_playground.sh

vivado:
	vivado -mode batch -source fpga/vivado_ooc.tcl

clean:
	rm -rf tb/cocotb/sim_build tb/cocotb/__pycache__ tb/cocotb/results.xml .pytest_cache \
	       synth_report.txt fpga/reports vivado*.log vivado*.jou .Xil
