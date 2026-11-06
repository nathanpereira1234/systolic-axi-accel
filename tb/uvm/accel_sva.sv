// ---------------------------------------------------------------------------
// accel_sva.sv - Assertions and functional coverage bound into the DUT.
//   axil_protocol_sva : AXI4-Lite handshake rules, bound to accel_top
//   accel_core_sva    : FSM legality, start/busy rules, FSM transition coverage,
//                       bound to accel_core
// ---------------------------------------------------------------------------
module axil_protocol_sva #(parameter int ADDR_W = 12) (
  input logic              clk,
  input logic              rst_n,
  input logic [ADDR_W-1:0] s_axil_awaddr,
  input logic              s_axil_awvalid,
  input logic              s_axil_awready,
  input logic [31:0]       s_axil_wdata,
  input logic [3:0]        s_axil_wstrb,
  input logic              s_axil_wvalid,
  input logic              s_axil_wready,
  input logic [1:0]        s_axil_bresp,
  input logic              s_axil_bvalid,
  input logic              s_axil_bready,
  input logic [ADDR_W-1:0] s_axil_araddr,
  input logic              s_axil_arvalid,
  input logic              s_axil_arready,
  input logic [31:0]       s_axil_rdata,
  input logic [1:0]        s_axil_rresp,
  input logic              s_axil_rvalid,
  input logic              s_axil_rready
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---- Master side (checks the UVM driver) ----
  a_awvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_awvalid && !s_axil_awready |=> s_axil_awvalid && $stable(s_axil_awaddr))
    else `uvm_error("SVA", "AWVALID dropped or AWADDR changed before AWREADY")

  a_wvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_wvalid && !s_axil_wready |=> s_axil_wvalid && $stable(s_axil_wdata) && $stable(s_axil_wstrb))
    else `uvm_error("SVA", "WVALID dropped or WDATA/WSTRB changed before WREADY")

  a_arvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_arvalid && !s_axil_arready |=> s_axil_arvalid && $stable(s_axil_araddr))
    else `uvm_error("SVA", "ARVALID dropped or ARADDR changed before ARREADY")

  // ---- Slave side (checks the DUT) ----
  a_bvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_bvalid && !s_axil_bready |=> s_axil_bvalid && $stable(s_axil_bresp))
    else `uvm_error("SVA", "BVALID dropped or BRESP changed before BREADY")

  a_rvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_rvalid && !s_axil_rready |=> s_axil_rvalid && $stable(s_axil_rdata) && $stable(s_axil_rresp))
    else `uvm_error("SVA", "RVALID dropped or RDATA/RRESP changed before RREADY")

  a_resp_legal: assert property (@(posedge clk) disable iff (!rst_n)
    (s_axil_bvalid |-> s_axil_bresp inside {2'b00, 2'b10}) and
    (s_axil_rvalid |-> s_axil_rresp inside {2'b00, 2'b10}))
    else `uvm_error("SVA", "Response other than OKAY/SLVERR")

  a_no_x_valid: assert property (@(posedge clk) disable iff (!rst_n)
    !$isunknown({s_axil_awready, s_axil_wready, s_axil_bvalid, s_axil_arready, s_axil_rvalid}))
    else `uvm_error("SVA", "X on a DUT handshake output")

  // ---- Every response must follow a request ----
  int unsigned aw_cnt, w_cnt, b_cnt, ar_cnt, r_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_cnt <= 0; w_cnt <= 0; b_cnt <= 0; ar_cnt <= 0; r_cnt <= 0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) aw_cnt <= aw_cnt + 1;
      if (s_axil_wvalid  && s_axil_wready)  w_cnt  <= w_cnt  + 1;
      if (s_axil_bvalid  && s_axil_bready)  b_cnt  <= b_cnt  + 1;
      if (s_axil_arvalid && s_axil_arready) ar_cnt <= ar_cnt + 1;
      if (s_axil_rvalid  && s_axil_rready)  r_cnt  <= r_cnt  + 1;
    end
  end

  a_b_after_aw_w: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_bvalid |-> (b_cnt < aw_cnt) && (b_cnt < w_cnt))
    else `uvm_error("SVA", "Write response without a matching AW and W")

  a_r_after_ar: assert property (@(posedge clk) disable iff (!rst_n)
    s_axil_rvalid |-> (r_cnt < ar_cnt))
    else `uvm_error("SVA", "Read response without a matching AR")

  // Handshake coverage
  c_aw_before_w: cover property (@(posedge clk) disable iff (!rst_n)
    s_axil_awvalid && s_axil_awready && !s_axil_wvalid);
  c_w_before_aw: cover property (@(posedge clk) disable iff (!rst_n)
    s_axil_wvalid && s_axil_wready && !s_axil_awvalid);
  c_aw_w_together: cover property (@(posedge clk) disable iff (!rst_n)
    s_axil_awvalid && s_axil_awready && s_axil_wvalid && s_axil_wready);
  c_b_backpressure: cover property (@(posedge clk) disable iff (!rst_n)
    s_axil_bvalid && !s_axil_bready);
endmodule


module accel_core_sva (
  input logic       clk,
  input logic       rst_n,
  input logic [2:0] state,
  input logic       start,
  input logic       busy,
  input logic       done_pulse
);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Encodings must match accel_core's state_t
  localparam logic [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_COMPUTE = 3'd2,
                         S_DRAIN = 3'd3, S_DONE = 3'd4;

  a_state_legal: assert property (@(posedge clk) disable iff (!rst_n)
    state inside {S_IDLE, S_LOAD, S_COMPUTE, S_DRAIN, S_DONE})
    else `uvm_error("SVA", $sformatf("Illegal FSM state %0d", state))

  a_no_start_when_busy: assert property (@(posedge clk) disable iff (!rst_n)
    start |-> !busy)
    else `uvm_error("SVA", "START reached the core while it was busy")

  a_done_after_drain: assert property (@(posedge clk) disable iff (!rst_n)
    done_pulse |-> $past(state) == S_DRAIN)
    else `uvm_error("SVA", "done_pulse not preceded by DRAIN")

  a_start_leads_to_done: assert property (@(posedge clk) disable iff (!rst_n)
    start |-> ##[1:20] done_pulse)
    else `uvm_error("SVA", "START did not lead to done_pulse within 20 cycles")

  // FSM transition coverage
  covergroup cg_fsm @(posedge clk);
    option.per_instance = 1;
    cp_state: coverpoint state {
      bins idle = {S_IDLE}; bins load = {S_LOAD}; bins compute = {S_COMPUTE};
      bins drain = {S_DRAIN}; bins done = {S_DONE};
      bins run_start = (S_IDLE => S_LOAD => S_COMPUTE);
      bins run_end   = (S_COMPUTE => S_DRAIN => S_DONE => S_IDLE);
      bins b2b       = (S_DONE => S_IDLE [* 1:30] => S_LOAD);   // quick restart
      illegal_bins bad = {[5:7]};
    }
  endgroup
  cg_fsm fsm_cov = new();
endmodule
