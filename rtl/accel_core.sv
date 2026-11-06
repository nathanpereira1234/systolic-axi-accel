// ---------------------------------------------------------------------------
// accel_core.sv - Control FSM + input skewing + systolic array + result buffer.
//
// Computes C = A x B for N x N signed INT8 matrices.
//   a_mat[(i*N+k)*8 +: 8] = A[i][k]
//   b_mat[(k*N+j)*8 +: 8] = B[k][j]
//   c_mat[(i*N+j)*32 +: 32] = C[i][j]
//
// Skewing: at compute cycle t, row i receives A[i][t-i] and column j receives
// B[t-j][j] (zero outside 0..N-1). PE(i,j) then sees A[i][k] and B[k][j] for
// the same k = t-i-j. The last product reaches PE(N-1,N-1) at t = 3N-3, so
// COMPUTE lasts 3N-2 cycles.
//
// FSM: IDLE -> LOAD (clear array) -> COMPUTE -> DRAIN (copy to C buffer) -> DONE
// ---------------------------------------------------------------------------
module accel_core #(
  parameter int N  = 4,
  parameter int DW = 8,
  parameter int AW = 32
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,       // 1-cycle pulse, ignored when busy
  input  logic              clear_c,     // 1-cycle pulse, zeroes C buffer (ignored when busy)
  input  logic [N*N*DW-1:0] a_mat,
  input  logic [N*N*DW-1:0] b_mat,
  output logic [N*N*AW-1:0] c_mat,
  output logic              busy,
  output logic              done_pulse   // 1-cycle pulse when C is valid
);
  typedef enum logic [2:0] {S_IDLE, S_LOAD, S_COMPUTE, S_DRAIN, S_DONE} state_t;
  state_t state;

  localparam int LAST_T = 3*N - 3;
  localparam int TW     = $clog2(3*N);

  logic [TW-1:0]     t;
  logic [N*DW-1:0]   a_left, b_top;
  logic [N*N*AW-1:0] acc_flat;
  logic              arr_clr, arr_en;

  assign busy       = (state != S_IDLE);
  assign arr_clr    = (state == S_LOAD);
  assign arr_en     = (state == S_COMPUTE);
  assign done_pulse = (state == S_DONE);

  // Zero-extended counter so comparisons with integer loop variables are 32-bit
  logic [31:0] t32;
  assign t32 = {{(32-TW){1'b0}}, t};

  // Input skew logic: row r gets A[r][k] and column r gets B[k][r] when t == r + k
  always_comb begin
    a_left = '0;
    b_top  = '0;
    if (state == S_COMPUTE) begin
      for (int r = 0; r < N; r++) begin
        for (int k = 0; k < N; k++) begin
          if (t32 == r + k) begin
            a_left[r*DW +: DW] = a_mat[(r*N + k)*DW +: DW];
            b_top [r*DW +: DW] = b_mat[(k*N + r)*DW +: DW];
          end
        end
      end
    end
  end

  systolic_array #(.N(N), .DW(DW), .AW(AW)) u_array (
    .clk      (clk),
    .rst_n    (rst_n),
    .clr      (arr_clr),
    .en       (arr_en),
    .a_left   (a_left),
    .b_top    (b_top),
    .acc_flat (acc_flat)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      t     <= '0;
      c_mat <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          t <= '0;
          if (start)        state <= S_LOAD;
          else if (clear_c) c_mat <= '0;
        end
        S_LOAD:    state <= S_COMPUTE;
        S_COMPUTE: begin
          if (t32 == LAST_T) state <= S_DRAIN;
          else                   t <= t + 1'b1;
        end
        S_DRAIN: begin
          c_mat <= acc_flat;
          state <= S_DONE;
        end
        S_DONE:  state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
