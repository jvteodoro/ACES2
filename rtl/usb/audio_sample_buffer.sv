// Single-clock FIFO between the packet decoder and board-level PCM consumer.
// Tracks occupancy/high-water and reports overflow; it is not a clock-domain
// crossing FIFO, so both handshakes must use clk_i.
module audio_sample_buffer #(
  parameter int DEPTH = 256,
  parameter int COUNT_WIDTH = $clog2(DEPTH + 1),
  parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
  input logic clk_i, rst_ni, flush_i,
  input logic [31:0] sample_data_i, input logic sample_valid_i,
  output logic sample_ready_o,
  output logic [31:0] sample_data_o, output logic sample_valid_o,
  input logic sample_ready_i,
  output logic [COUNT_WIDTH-1:0] occupancy_o,
  output logic [COUNT_WIDTH-1:0] high_water_o,
  output logic overflow_o
);
  logic [31:0] mem [0:DEPTH-1];
  logic [ADDR_WIDTH-1:0] rd_q, wr_q;
  logic push, pop;
  localparam logic [COUNT_WIDTH-1:0] DEPTH_COUNT = COUNT_WIDTH'(DEPTH);
  localparam logic [ADDR_WIDTH-1:0] LAST_ADDR = ADDR_WIDTH'(DEPTH-1);

  assign sample_valid_o = occupancy_o != 0;
  assign sample_ready_o = (occupancy_o < DEPTH_COUNT) || (sample_valid_o && sample_ready_i);
  assign sample_data_o = mem[rd_q];
  assign push = sample_valid_i && sample_ready_o;
  assign pop = sample_valid_o && sample_ready_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rd_q <= '0;
      wr_q <= '0;
      occupancy_o <= '0;
      high_water_o <= '0;
      overflow_o <= 1'b0;
    end else if (flush_i) begin
      rd_q <= '0;
      wr_q <= '0;
      occupancy_o <= '0;
      high_water_o <= '0;
      overflow_o <= 1'b0;
    end else begin
      overflow_o <= sample_valid_i && !sample_ready_o;
      if (push) begin
        mem[wr_q] <= sample_data_i;
        wr_q <= wr_q == LAST_ADDR ? '0 : wr_q + 1'b1;
      end
      if (pop) rd_q <= rd_q == LAST_ADDR ? '0 : rd_q + 1'b1;
      case ({push,pop})
        2'b10: occupancy_o <= occupancy_o + 1'b1;
        2'b01: occupancy_o <= occupancy_o - 1'b1;
        default: occupancy_o <= occupancy_o;
      endcase
      if (push && (!pop) && occupancy_o + 1'b1 > high_water_o)
        high_water_o <= occupancy_o + 1'b1;
    end
  end
endmodule
