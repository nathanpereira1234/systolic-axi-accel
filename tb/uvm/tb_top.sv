// ---------------------------------------------------------------------------
// tb_top.sv - UVM testbench top for accel_top.
// Run with +UVM_TESTNAME=<test>, e.g. +UVM_TESTNAME=random_test +NUM_ITERS=200
// Tests: smoke_test random_test corner_test back2back_test busy_access_test
//        error_test full_regression_test
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  import accel_tb_pkg::*;
  `include "uvm_macros.svh"

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;                // 100 MHz
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1;
  end

  axil_if #(.ADDR_W(ADDR_W)) vif (.clk(clk), .rst_n(rst_n));

  accel_top #(.N(N), .ADDR_W(ADDR_W)) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axil_awaddr  (vif.awaddr),
    .s_axil_awprot  (vif.awprot),
    .s_axil_awvalid (vif.awvalid),
    .s_axil_awready (vif.awready),
    .s_axil_wdata   (vif.wdata),
    .s_axil_wstrb   (vif.wstrb),
    .s_axil_wvalid  (vif.wvalid),
    .s_axil_wready  (vif.wready),
    .s_axil_bresp   (vif.bresp),
    .s_axil_bvalid  (vif.bvalid),
    .s_axil_bready  (vif.bready),
    .s_axil_araddr  (vif.araddr),
    .s_axil_arprot  (vif.arprot),
    .s_axil_arvalid (vif.arvalid),
    .s_axil_arready (vif.arready),
    .s_axil_rdata   (vif.rdata),
    .s_axil_rresp   (vif.rresp),
    .s_axil_rvalid  (vif.rvalid),
    .s_axil_rready  (vif.rready),
    .irq            (vif.irq)
  );

  // Assertions and FSM coverage, bound so the RTL stays untouched
  bind accel_top axil_protocol_sva #(.ADDR_W(ADDR_W)) u_axil_sva (.*);
  bind accel_core accel_core_sva u_core_sva (
    .clk(clk), .rst_n(rst_n), .state(state), .start(start),
    .busy(busy), .done_pulse(done_pulse));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.*", "vif", vif);
    run_test("smoke_test");
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
  end
endmodule
