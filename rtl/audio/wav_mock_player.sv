`timescale 1ns/1ps

// Replays a mono 16-bit WAV converted to one hexadecimal sample per line.
// The sample is held until the downstream ready signal accepts it.
module wav_mock_player #(
  parameter int unsigned CLOCK_HZ = 50_000_000,
  parameter int unsigned SAMPLE_RATE_HZ = 48_000,
  parameter int unsigned SAMPLE_COUNT = 16,
  parameter string MEM_FILE = "audio_mock.mem"
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        enable_i,
  output logic [31:0] sample_data_o,
  output logic        sample_valid_o,
  input  logic        sample_ready_i
);

  localparam int unsigned PERIOD_CYCLES =
      (CLOCK_HZ + SAMPLE_RATE_HZ / 2) / SAMPLE_RATE_HZ;
  localparam int unsigned PERIOD_W = (PERIOD_CYCLES < 2) ? 1 : $clog2(PERIOD_CYCLES);
  localparam int unsigned INDEX_W = (SAMPLE_COUNT < 2) ? 1 : $clog2(SAMPLE_COUNT);

  logic [15:0] sample_mem [0:SAMPLE_COUNT-1];
  logic [PERIOD_W-1:0] period_q;
  logic [INDEX_W-1:0] sample_index_q;

  initial $readmemh(MEM_FILE, sample_mem);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      period_q       <= '0;
      sample_index_q <= '0;
      sample_data_o  <= '0;
      sample_valid_o <= 1'b0;
    end else if (!enable_i) begin
      period_q       <= '0;
      sample_index_q <= '0;
      sample_data_o  <= '0;
      sample_valid_o <= 1'b0;
    end else begin
      if (sample_valid_o && sample_ready_i) begin
        sample_valid_o <= 1'b0;
        if (sample_index_q == SAMPLE_COUNT - 1)
          sample_index_q <= '0;
        else
          sample_index_q <= sample_index_q + 1'b1;
      end

      if (!sample_valid_o) begin
        if (period_q == PERIOD_CYCLES - 1) begin
          sample_data_o  <= {{16{sample_mem[sample_index_q][15]}},
                             sample_mem[sample_index_q]};
          sample_valid_o <= 1'b1;
          period_q       <= '0;
        end else begin
          period_q <= period_q + 1'b1;
        end
      end
    end
  end
endmodule
