// ---------------------------------------------------------------------------
// axil_if.sv - AXI4-Lite interface used by the UVM agent and the SVA checker.
// ---------------------------------------------------------------------------
interface axil_if #(parameter int ADDR_W = 12) (input logic clk, input logic rst_n);
  logic [ADDR_W-1:0] awaddr;
  logic [2:0]        awprot;
  logic              awvalid;
  logic              awready;
  logic [31:0]       wdata;
  logic [3:0]        wstrb;
  logic              wvalid;
  logic              wready;
  logic [1:0]        bresp;
  logic              bvalid;
  logic              bready;
  logic [ADDR_W-1:0] araddr;
  logic [2:0]        arprot;
  logic              arvalid;
  logic              arready;
  logic [31:0]       rdata;
  logic [1:0]        rresp;
  logic              rvalid;
  logic              rready;
  logic              irq;
endinterface
