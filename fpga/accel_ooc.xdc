# Out-of-context timing constraint: 100 MHz target. Tighten (e.g. 6.667 = 150 MHz) to find Fmax.
create_clock -period 10.000 -name clk [get_ports clk]
