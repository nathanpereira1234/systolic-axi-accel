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
// Timing: the skew mux output is registered (a_left_q/b_top_q) so the mux is
// not in the same cycle as the PE multiply-accumulate. The array enable and
// clear are registered too (en_q/clr_q), which takes the FSM state bits off
// the high-fanout nets into every PE. Each PE adds one more pipeline stage
// (product register, for DSP48 mapping), so two FLUSH cycles wait for the
// last delayed accumulate before DRAIN copies the results.
//
// FSM: IDLE -> LOAD -> COMPUTE -> FLUSH -> FLUSH2 -> DRAIN (copy to C) -> DONE
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
  typedef enum logic [2:0] {S_IDLE, S_LOAD, S_COMPUTE, S_FLUSH, S_FLUSH2, S_DRAIN, S_DONE} state_t;
  state_t state;

  localparam int LAST_T = 3*N - 3;
  localparam int TW     = $clog2(3*N);

  logic [TW-1:0]     t;
  logic [N*DW-1:0]   a_left, b_top;      // combinational skew mux output
  logic [N*DW-1:0]   a_left_q, b_top_q;  // registered array inputs
  // High-fanout control: registered, and Vivado may replicate them to meet timing
  (* max_fanout = 64 *) logic en_q;      // array enable, aligned with *_q
  (* max_fanout = 64 *) logic clr_q;     // array clear, one cycle after LOAD
  logic [N*N*AW-1:0] acc_flat;
  logic              arr_clr, arr_en;

  assign busy       = (state != S_IDLE);
  assign arr_clr    = clr_q;
  assign arr_en     = en_q;
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

  // Reset synchronizer for the array: asserts asynchronously, releases
  // synchronously. The PEs use it as a synchronous reset (needed for DSP48
  // mapping) without sampling the raw asynchronous rst_n input.
  logic [1:0] arr_rst_sync;
  logic       arr_rst_n;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) arr_rst_sync <= 2'b00;
    else        arr_rst_sync <= {arr_rst_sync[0], 1'b1};
  end
  assign arr_rst_n = arr_rst_sync[1];

  // Input pipeline register: cuts the skew mux off the PE MAC path.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_left_q <= '0;
      b_top_q  <= '0;
      en_q     <= 1'b0;
      clr_q    <= 1'b0;
    end else begin
      a_left_q <= a_left;
      b_top_q  <= b_top;
      en_q     <= (state == S_COMPUTE);
      clr_q    <= (state == S_LOAD);   // lands in COMPUTE cycle 0, before en_q rises
    end
  end

  systolic_array #(.N(N), .DW(DW), .AW(AW)) u_array (
    .clk      (clk),
    .rst_n    (arr_rst_n),
    .clr      (arr_clr),
    .en       (arr_en),
    .a_left   (a_left_q),
    .b_top    (b_top_q),
    .acc_flat (acc_flat)
  );

  // Result-buffer control, registered: the load/clear enables for the 512-bit
  // C buffer are decoded one cycle early so the FSM state bits don't drive
  // ~570 flip-flops directly (that net was the critical path).
  (* max_fanout = 64 *) logic c_load_q;  // high during DRAIN
  (* max_fanout = 64 *) logic c_clr_q;   // one cycle after an accepted clear_c
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_load_q <= 1'b0;
      c_clr_q  <= 1'b0;
      c_mat    <= '0;
    end else begin
      c_load_q <= (state == S_FLUSH2);
      c_clr_q  <= (state == S_IDLE) && !start && clear_c;
      if (c_load_q)     c_mat <= acc_flat;
      else if (c_clr_q) c_mat <= '0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      t     <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          t <= '0;
          if (start) state <= S_LOAD;   // clear_c is handled by c_clr_q above
        end
        S_LOAD:    state <= S_COMPUTE;
        S_COMPUTE: begin
          if (t32 == LAST_T) state <= S_FLUSH;
          else                   t <= t + 1'b1;
        end
        S_FLUSH:  state <= S_FLUSH2; // last product enters the PE pipeline
        S_FLUSH2: state <= S_DRAIN;  // last accumulate lands this cycle
        S_DRAIN:  state <= S_DONE;   // c_load_q copies acc_flat into c_mat this cycle
        S_DONE:  state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
