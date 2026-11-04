// Packet-atomic USB Audio Class PCM decoder for stereo signed 16-bit little-
// endian samples. It checks packet length/error before publishing words and
// holds each {right,left} sample stable until the downstream ready/valid
// handshake completes. Byte zero is packet_data_i[7:0].
module usb_pcm_decoder (
  input logic clk_i, rst_ni, flush_i,
  input logic packet_valid_i, output logic packet_ready_o,
  input logic [2047:0] packet_data_i, input logic [8:0] packet_len_i,
  input logic packet_error_i,
  output logic [31:0] sample_data_o, output logic sample_valid_o,
  input logic sample_ready_i, output logic malformed_o
);
  logic [2047:0] packet_q;
  logic [8:0] frame_count_q, frame_idx_q;

  assign packet_ready_o = !sample_valid_o;
  assign sample_valid_o = frame_count_q != 0;
  assign sample_data_o = {packet_q[frame_idx_q*32+16 +: 16],
                          packet_q[frame_idx_q*32 +: 16]};

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      packet_q <= '0;
      frame_count_q <= '0;
      frame_idx_q <= '0;
      malformed_o <= 1'b0;
    end else if (flush_i) begin
      packet_q <= '0;
      frame_count_q <= '0;
      frame_idx_q <= '0;
      malformed_o <= 1'b0;
    end else begin
      malformed_o <= 1'b0;
      if (packet_valid_i && packet_ready_o) begin
        if (packet_error_i || packet_len_i > 9'd256 || packet_len_i[1:0] != 0) begin
          malformed_o <= 1'b1;
        end else if (packet_len_i != 0) begin
          packet_q <= packet_data_i;
          frame_count_q <= {2'b00, packet_len_i[8:2]};
          frame_idx_q <= 0;
        end
      end
      if (sample_valid_o && sample_ready_i) begin
        if (frame_idx_q + 1'b1 == frame_count_q) begin
          frame_idx_q <= 0;
          frame_count_q <= 0;
        end else frame_idx_q <= frame_idx_q + 1'b1;
      end
    end
  end
endmodule
