// ---------------------------------------------------------------------------
// systolic_array.sv - N x N grid of PEs.
// a_left[i] enters row i from the left, b_top[j] enters column j from the top.
// PE(i,j) accumulates C[i][j]. Results are exposed as a flat bus:
//   acc_flat[(i*N+j)*AW +: AW] = C[i][j]
// ---------------------------------------------------------------------------
module systolic_array #(
  parameter int N  = 4,
  parameter int DW = 8,
  parameter int AW = 32
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              clr,
  input  logic              en,
  input  logic [N*DW-1:0]   a_left,     // row i at [i*DW +: DW]
  input  logic [N*DW-1:0]   b_top,      // col j at [j*DW +: DW]
  output logic [N*N*AW-1:0] acc_flat
);
  // Horizontal A wires: a_h[i][j] is the input to PE(i,j); a_h[i][N] is unused.
  // Vertical B wires:   b_v[i][j] is the input to PE(i,j); b_v[N][j] is unused.
  logic [DW-1:0] a_h [N][N+1];
  logic [DW-1:0] b_v [N+1][N];

  genvar i, j;
  generate
    for (i = 0; i < N; i++) begin : g_edge_a
      assign a_h[i][0] = a_left[i*DW +: DW];
    end
    for (j = 0; j < N; j++) begin : g_edge_b
      assign b_v[0][j] = b_top[j*DW +: DW];
    end

    for (i = 0; i < N; i++) begin : g_row
      for (j = 0; j < N; j++) begin : g_col
        logic signed [AW-1:0] acc_ij;
        pe #(.DW(DW), .AW(AW)) u_pe (
          .clk   (clk),
          .rst_n (rst_n),
          .clr   (clr),
          .en    (en),
          .a_in  (a_h[i][j]),
          .b_in  (b_v[i][j]),
          .a_out (a_h[i][j+1]),
          .b_out (b_v[i+1][j]),
          .acc   (acc_ij)
        );
        assign acc_flat[(i*N+j)*AW +: AW] = acc_ij;
      end
    end
  endgenerate
endmodule
