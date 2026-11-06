// ---------------------------------------------------------------------------
// pe.sv - Processing element for an output-stationary systolic array.
// Multiplies signed INT8 operands, accumulates into a signed 32-bit register,
// and forwards A to the right and B downward one cycle later.
// ---------------------------------------------------------------------------
module pe #(
  parameter int DW = 8,   // operand width
  parameter int AW = 32   // accumulator width
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 clr,     // synchronous clear of acc and pipeline regs
  input  logic                 en,      // compute enable
  input  logic signed [DW-1:0] a_in,
  input  logic signed [DW-1:0] b_in,
  output logic signed [DW-1:0] a_out,
  output logic signed [DW-1:0] b_out,
  output logic signed [AW-1:0] acc
);
  logic signed [2*DW-1:0] prod;
  assign prod = a_in * b_in;   // both operands signed -> signed product

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (clr) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      acc   <= acc + {{(AW-2*DW){prod[2*DW-1]}}, prod};  // sign-extend to AW bits
    end
  end
endmodule
