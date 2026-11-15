// ---------------------------------------------------------------------------
// pe.sv - Processing element for an output-stationary systolic array.
// Multiplies signed INT8 operands, accumulates into a signed 32-bit register,
// and forwards A to the right and B downward one cycle later.
//
// The multiply-accumulate is written to map onto one Xilinx DSP48 slice:
//   stage 1: prod_q <= a_in * b_in          (DSP M register)
//   stage 2: acc    <= acc + prod_q         (DSP P register, accumulate)
// All registers use a SYNCHRONOUS reset/clear, because the DSP48's internal
// pipeline registers only support synchronous reset; an asynchronous reset
// forces the multiplier out into LUTs.
//
// Timing: acc reflects a product one cycle after the operands were accepted
// (en_d is en delayed by one cycle). A/B forwarding is unchanged, so every PE
// lags by the same cycle and the systolic alignment is preserved.
// ---------------------------------------------------------------------------
(* use_dsp = "yes" *)
module pe #(
  parameter int DW = 8,   // operand width
  parameter int AW = 32   // accumulator width
) (
  input  logic                 clk,
  input  logic                 rst_n,   // active-low, sampled synchronously
  input  logic                 clr,     // synchronous clear of acc and pipeline regs
  input  logic                 en,      // compute enable
  input  logic signed [DW-1:0] a_in,
  input  logic signed [DW-1:0] b_in,
  output logic signed [DW-1:0] a_out,
  output logic signed [DW-1:0] b_out,
  output logic signed [AW-1:0] acc
);
  logic signed [2*DW-1:0] prod_q;                        // registered product (DSP MREG)
  logic                    en_d;                         // en delayed to match prod_q

  // Operand forwarding (fabric registers)
  always_ff @(posedge clk) begin
    if (!rst_n || clr) begin
      a_out <= '0;
      b_out <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
    end
  end

  // Multiply-accumulate pipeline (maps to DSP48: M register + P accumulator)
  always_ff @(posedge clk) begin
    if (!rst_n || clr) begin
      prod_q <= '0;
      en_d   <= 1'b0;
      acc    <= '0;
    end else begin
      en_d <= en;
      if (en)   prod_q <= a_in * b_in;   // both operands signed -> signed product
      // Plain signed add (Vivado UG901 multiply-accumulate template): prod_q is
      // sign-extended implicitly, so the M and P registers fuse into one DSP48.
      /* verilator lint_off WIDTHEXPAND */
      if (en_d) acc    <= acc + prod_q;     // DSP PREG accumulate
      /* verilator lint_on WIDTHEXPAND */
    end
  end
endmodule
