// ---------------------------------------------------------------------------
// sync_fifo.sv - Parameterized synchronous FIFO (first-word-fall-through off).
// Classic interview block; tested on its own in tb/cocotb/test_fifo.py.
// DEPTH must be a power of two.
// ---------------------------------------------------------------------------
module sync_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 8
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             wr_en,
  input  logic [WIDTH-1:0] wr_data,
  input  logic             rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             full,
  output logic             empty,
  output logic [$clog2(DEPTH):0] count
);
  localparam int PW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PW:0]      wptr, rptr;   // extra MSB distinguishes full from empty

  wire do_wr = wr_en && !full;
  wire do_rd = rd_en && !empty;

  assign empty = (wptr == rptr);
  assign full  = (wptr[PW] != rptr[PW]) && (wptr[PW-1:0] == rptr[PW-1:0]);
  assign count = wptr - rptr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr    <= '0;
      rptr    <= '0;
      rd_data <= '0;
    end else begin
      if (do_wr) begin
        mem[wptr[PW-1:0]] <= wr_data;
        wptr <= wptr + 1'b1;
      end
      if (do_rd) begin
        rd_data <= mem[rptr[PW-1:0]];
        rptr <= rptr + 1'b1;
      end
    end
  end
endmodule
