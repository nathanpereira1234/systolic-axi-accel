// ---------------------------------------------------------------------------
// axil_slave.sv - AXI4-Lite register block for the systolic accelerator.
//
// Register map (byte offsets, 32-bit registers):
//   0x000 CTRL    RW  bit0 START (self-clearing, reads 0), bit1 CLR_C (self-clearing),
//                     bit2 IRQ_EN.  Any write while BUSY -> SLVERR.
//   0x004 STATUS  RO/W1C  bit0 BUSY, bit1 DONE (write 1 to clear; START also clears it).
//   0x008 DIM     RO  N
//   0x100 + 4*i   A_BUF  RW  row i of A, byte k = A[i][k]. Write while BUSY -> SLVERR.
//   0x200 + 4*k   B_BUF  RW  row k of B, byte j = B[k][j]. Write while BUSY -> SLVERR.
//   0x300 + 4*(i*N+j) C_BUF RO  C[i][j] (signed 32-bit). Read while BUSY -> SLVERR.
//   Anything else -> SLVERR. Writes to RO registers -> SLVERR.
//   addr[1:0] is ignored; byte lanes are selected by WSTRB.
//
// Handles AW and W arriving in either order or together. One outstanding
// write and one outstanding read at a time (allowed by AXI4-Lite).
// Requires N <= 4 so one matrix row fits in one 32-bit word.
// ---------------------------------------------------------------------------
module axil_slave #(
  parameter int N      = 4,
  parameter int DW     = 8,
  parameter int AW     = 32,
  parameter int ADDR_W = 12
) (
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite slave
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
  // To / from the core
  output logic [N*N*DW-1:0] a_mat,
  output logic [N*N*DW-1:0] b_mat,
  input  logic [N*N*AW-1:0] c_mat,
  output logic              start,
  output logic              clear_c,
  input  logic              core_busy,
  input  logic              done_pulse,
  output logic              irq
);
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  localparam logic [ADDR_W-1:0] OFF_CTRL   = 'h000;
  localparam logic [ADDR_W-1:0] OFF_STATUS = 'h004;
  localparam logic [ADDR_W-1:0] OFF_DIM    = 'h008;
  localparam logic [ADDR_W-1:0] OFF_A      = 'h100;
  localparam logic [ADDR_W-1:0] OFF_B      = 'h200;
  localparam logic [ADDR_W-1:0] OFF_C      = 'h300;

  // ----------------------------------------------------------------------
  // State
  // ----------------------------------------------------------------------
  logic irq_en, done;
  logic busy;   // core busy, or a START accepted but not yet seen by the core
  assign busy = core_busy | start;
  assign irq  = done & irq_en;

  // Write channel holding registers
  logic              aw_hold, w_hold;
  logic [ADDR_W-1:0] aw_addr_q;
  logic [31:0]       w_data_q;
  logic [3:0]        w_strb_q;

  assign s_axil_awready = !aw_hold && !s_axil_bvalid;
  assign s_axil_wready  = !w_hold  && !s_axil_bvalid;
  assign s_axil_arready = !s_axil_rvalid;

  // ----------------------------------------------------------------------
  // Address decode (word addresses; addr[1:0] ignored, WSTRB selects bytes)
  // ----------------------------------------------------------------------
  localparam int WW = ADDR_W - 2;   // word-address width
  localparam logic [WW-1:0] W_CTRL   = OFF_CTRL[ADDR_W-1:2];
  localparam logic [WW-1:0] W_STATUS = OFF_STATUS[ADDR_W-1:2];
  localparam logic [WW-1:0] W_DIM    = OFF_DIM[ADDR_W-1:2];
  localparam logic [WW-1:0] W_A      = OFF_A[ADDR_W-1:2];
  localparam logic [WW-1:0] W_B      = OFF_B[ADDR_W-1:2];
  localparam logic [WW-1:0] W_C      = OFF_C[ADDR_W-1:2];
  localparam int            NN       = N * N;
  localparam logic [WW-1:0] N_W      = N[WW-1:0];
  localparam logic [WW-1:0] NN_W     = NN[WW-1:0];

  logic [WW-1:0] aw_word, ar_word;
  assign aw_word = aw_addr_q[ADDR_W-1:2];
  assign ar_word = s_axil_araddr[ADDR_W-1:2];

  logic aw_ctrl, aw_status, aw_a, aw_b;
  logic ar_ctrl, ar_status, ar_dim, ar_a, ar_b, ar_c;
  assign aw_ctrl   = (aw_word == W_CTRL);
  assign aw_status = (aw_word == W_STATUS);
  assign aw_a      = (aw_word >= W_A) && (aw_word < W_A + N_W);
  assign aw_b      = (aw_word >= W_B) && (aw_word < W_B + N_W);
  assign ar_ctrl   = (ar_word == W_CTRL);
  assign ar_status = (ar_word == W_STATUS);
  assign ar_dim    = (ar_word == W_DIM);
  assign ar_a      = (ar_word >= W_A) && (ar_word < W_A + N_W);
  assign ar_b      = (ar_word >= W_B) && (ar_word < W_B + N_W);
  assign ar_c      = (ar_word >= W_C) && (ar_word < W_C + NN_W);

  // Element offsets inside each buffer, zero-extended to 32 bits for indexing
  logic [WW-1:0] aw_off_a, aw_off_b, ar_off_a, ar_off_b, ar_off_c;
  assign aw_off_a = aw_word - W_A;
  assign aw_off_b = aw_word - W_B;
  assign ar_off_a = ar_word - W_A;
  assign ar_off_b = ar_word - W_B;
  assign ar_off_c = ar_word - W_C;

  logic [31:0] aw_ia, aw_ib, ar_ia, ar_ib, ar_ic;
  assign aw_ia = {{(32-WW){1'b0}}, aw_off_a};
  assign aw_ib = {{(32-WW){1'b0}}, aw_off_b};
  assign ar_ia = {{(32-WW){1'b0}}, ar_off_a};
  assign ar_ib = {{(32-WW){1'b0}}, ar_off_b};
  assign ar_ic = {{(32-WW){1'b0}}, ar_off_c};

  // ----------------------------------------------------------------------
  // Write path
  // ----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_hold       <= 1'b0;
      w_hold        <= 1'b0;
      aw_addr_q     <= '0;
      w_data_q      <= '0;
      w_strb_q      <= '0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp  <= RESP_OKAY;
      a_mat         <= '0;
      b_mat         <= '0;
      start         <= 1'b0;
      clear_c       <= 1'b0;
      irq_en        <= 1'b0;
      done          <= 1'b0;
    end else begin
      start   <= 1'b0;
      clear_c <= 1'b0;

      // Capture AW and W independently
      if (s_axil_awvalid && s_axil_awready) begin
        aw_hold   <= 1'b1;
        aw_addr_q <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_hold   <= 1'b1;
        w_data_q <= s_axil_wdata;
        w_strb_q <= s_axil_wstrb;
      end

      // Release the write response
      if (s_axil_bvalid && s_axil_bready)
        s_axil_bvalid <= 1'b0;

      // Perform the write once both halves are captured
      if (aw_hold && w_hold && !s_axil_bvalid) begin
        aw_hold       <= 1'b0;
        w_hold        <= 1'b0;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp  <= RESP_OKAY;

        if (aw_ctrl) begin
          if (busy) begin
            s_axil_bresp <= RESP_SLVERR;
          end else if (w_strb_q[0]) begin
            start   <= w_data_q[0];
            clear_c <= w_data_q[1];
            irq_en  <= w_data_q[2];
            if (w_data_q[0]) done <= 1'b0;   // a new run clears DONE
          end
        end else if (aw_status) begin
          if (w_strb_q[0] && w_data_q[1]) done <= 1'b0;   // W1C
        end else if (aw_a) begin
          if (busy) s_axil_bresp <= RESP_SLVERR;
          else begin
            for (int b = 0; b < N; b++)
              if (w_strb_q[b])
                a_mat[(aw_ia*N + b)*DW +: DW] <= w_data_q[b*8 +: 8];
          end
        end else if (aw_b) begin
          if (busy) s_axil_bresp <= RESP_SLVERR;
          else begin
            for (int b = 0; b < N; b++)
              if (w_strb_q[b])
                b_mat[(aw_ib*N + b)*DW +: DW] <= w_data_q[b*8 +: 8];
          end
        end else begin
          // DIM, C_BUF (read-only) and unmapped addresses
          s_axil_bresp <= RESP_SLVERR;
        end
      end

      // DONE is set by the core; setting wins over a same-cycle clear
      if (done_pulse) done <= 1'b1;
    end
  end

  // ----------------------------------------------------------------------
  // Read path
  // ----------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
      s_axil_rresp  <= RESP_OKAY;
    end else begin
      if (s_axil_rvalid && s_axil_rready)
        s_axil_rvalid <= 1'b0;

      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rresp  <= RESP_OKAY;
        s_axil_rdata  <= '0;

        if (ar_ctrl) begin
          s_axil_rdata <= {29'b0, irq_en, 2'b00};
        end else if (ar_status) begin
          s_axil_rdata <= {30'b0, done, busy};
        end else if (ar_dim) begin
          s_axil_rdata <= N;
        end else if (ar_a) begin
          for (int b = 0; b < N; b++)
            s_axil_rdata[b*8 +: 8] <= a_mat[(ar_ia*N + b)*DW +: DW];
        end else if (ar_b) begin
          for (int b = 0; b < N; b++)
            s_axil_rdata[b*8 +: 8] <= b_mat[(ar_ib*N + b)*DW +: DW];
        end else if (ar_c) begin
          if (busy) s_axil_rresp <= RESP_SLVERR;
          else      s_axil_rdata <= c_mat[ar_ic*AW +: 32];
        end else begin
          s_axil_rresp <= RESP_SLVERR;
        end
      end
    end
  end

  // Unused inputs: AXI protection bits and the byte offset of the address
  logic unused;
  assign unused = ^{s_axil_awprot, s_axil_arprot, aw_addr_q[1:0], s_axil_araddr[1:0]};
endmodule
