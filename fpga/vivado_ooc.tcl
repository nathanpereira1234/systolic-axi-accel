# ---------------------------------------------------------------------------
# Out-of-context Vivado run: synthesis + place & route + timing for accel_top.
# No board needed (I/O pins are not assigned).
#
# Run from the repo root:
#   vivado -mode batch -source fpga/vivado_ooc.tcl
# Optional: -tclargs <part> <N>   e.g. -tclargs xc7a100tcsg324-1 4
# Reports are written to fpga/reports/
# ---------------------------------------------------------------------------
set part "xc7a35tcpg236-1"   ;# Basys 3 (Artix-7 35T)
set n    4
if {[llength $argv] >= 1} { set part [lindex $argv 0] }
if {[llength $argv] >= 2} { set n    [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set rpt  [file join $root fpga reports]
file mkdir $rpt

read_verilog -sv [list \
  $root/rtl/pe.sv \
  $root/rtl/systolic_array.sv \
  $root/rtl/accel_core.sv \
  $root/rtl/axil_slave.sv \
  $root/rtl/accel_top.sv ]
read_xdc -mode out_of_context $root/fpga/accel_ooc.xdc

synth_design -top accel_top -part $part -mode out_of_context -generic N=$n
report_utilization    -file $rpt/post_synth_utilization.rpt

opt_design
place_design
route_design

report_utilization    -file $rpt/utilization.rpt
report_timing_summary -file $rpt/timing_summary.rpt -max_paths 10
report_power          -file $rpt/power.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set period [get_property PERIOD [get_clocks clk]]
puts "=================================================="
puts " Part: $part   N: $n"
puts " Clock period: $period ns   WNS: $wns ns"
puts " Estimated Fmax: [format %.1f [expr {1000.0 / ($period - $wns)}]] MHz"
puts " Reports in $rpt"
puts "=================================================="
