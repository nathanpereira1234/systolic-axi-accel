// ---------------------------------------------------------------------------
// accel_top.sv - AXI4-Lite systolic-array matrix-multiply accelerator.
// ---------------------------------------------------------------------------
module accel_top #(
  parameter int N      = 4,     // array size, 1..4
  parameter int ADDR_W = 12
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic [2:0]        s_axil_awprot,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic [2:0]        s_axil_arprot,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  output logic              irq
);
  localparam int DW = 8;
  localparam int AW = 32;

  logic [N*N*DW-1:0] a_mat, b_mat;
  logic [N*N*AW-1:0] c_mat;
  logic              start, clear_c, core_busy, done_pulse;

  axil_slave #(.N(N), .DW(DW), .AW(AW), .ADDR_W(ADDR_W)) u_regs (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awprot, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arprot, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .a_mat, .b_mat, .c_mat, .start, .clear_c,
    .core_busy, .done_pulse, .irq
  );

  accel_core #(.N(N), .DW(DW), .AW(AW)) u_core (
    .clk, .rst_n,
    .start, .clear_c,
    .a_mat, .b_mat, .c_mat,
    .busy       (core_busy),
    .done_pulse (done_pulse)
  );
endmodule
