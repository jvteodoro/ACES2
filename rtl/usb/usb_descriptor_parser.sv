// Incrementally parses one bounded USB configuration descriptor stream. It
// associates AudioControl/AudioStreaming interfaces, Type-I PCM format and
// isochronous IN endpoints, then reports the first alternate matching the
// configured channel/bit/rate/packet constraints.
module usb_descriptor_parser #(
  parameter logic [15:0] TARGET_RATE_HZ = 16'd48000,
  parameter logic [7:0]  TARGET_CHANNELS = 8'd2,
  parameter logic [7:0]  TARGET_BITS = 8'd16,
  // Zero selects the first matching isochronous IN endpoint in the profile.
  parameter logic [7:0]  TARGET_ENDPOINT = 8'h00,
  parameter logic [15:0] MIN_PACKET_BYTES = 16'd4,
  // The host engine's complete-packet storage is 256 bytes.
  parameter logic [15:0] MAX_PACKET_BYTES = 16'd256
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  logic [15:0] total_length_i,
  input  logic [7:0]  byte_data_i,
  input  logic        byte_valid_i,
  output logic        byte_ready_o,
  output logic        done_o,
  output logic        valid_o,
  output logic        error_o,
  output logic [7:0]  interface_o,
  output logic [7:0]  alternate_setting_o,
  output logic [7:0]  endpoint_o,
  output logic [10:0] max_packet_size_o,
  output logic [7:0]  interval_o,
  output logic [7:0]  channels_o,
  output logic [7:0]  sample_bits_o,
  output logic [15:0] sample_rate_o
);
  localparam logic [7:0] DESC_CONFIGURATION = 8'h02;
  localparam logic [7:0] DESC_INTERFACE     = 8'h04;
  localparam logic [7:0] DESC_ENDPOINT      = 8'h05;
  localparam logic [7:0] DESC_CS_INTERFACE = 8'h24;

  logic active_q;
  logic [15:0] total_q, consumed_q;
  logic [7:0] desc_buf [0:254];
  logic [7:0] desc_len_q, desc_pos_q;
  logic [15:0] desc_start_q;
  logic desc_active_q;
  logic config_seen_q;
  logic [7:0] declared_interfaces_q;
  logic [255:0] interface_seen_q;
  logic [7:0] unique_interfaces_q;
  logic [7:0] current_interface_q, current_alt_q;
  logic have_interface_q;
  logic [7:0] current_ep_expected_q, current_ep_count_q;
  logic current_audio_stream_q;
  logic current_pcm_q, current_match_format_q;
  logic [7:0] fmt_channels_q, fmt_bits_q;
  logic [15:0] fmt_rate_q;
  logic candidate_found_q;
  logic [7:0] candidate_interface_q, candidate_alt_q, candidate_endpoint_q;
  logic [10:0] candidate_packet_q;
  logic [7:0] candidate_interval_q;
  logic [7:0] candidate_channels_q, candidate_bits_q;
  logic [15:0] candidate_rate_q;

  assign byte_ready_o = active_q && !done_o && !error_o;

  task automatic fail_parse;
    begin
      active_q <= 1'b0;
      error_o <= 1'b1;
      done_o <= 1'b1;
    end
  endtask

  always_ff @(posedge clk_i) begin : parser_fsm
    logic [7:0] b_length;
    logic [7:0] b_type;
    logic [15:0] packet_size;
    logic rate_matches;
    logic malformed_this_desc;
    logic [7:0] endpoint_interval;
    packet_size = 16'd0;
    rate_matches = 1'b0;
    malformed_this_desc = 1'b0;
    endpoint_interval = 8'd0;
    if (!rst_ni) begin
      active_q <= 1'b0;
      total_q <= 0;
      consumed_q <= 0;
      desc_len_q <= 0;
      desc_pos_q <= 0;
      desc_start_q <= 0;
      desc_active_q <= 1'b0;
      config_seen_q <= 1'b0;
      declared_interfaces_q <= 0;
      interface_seen_q <= '0;
      unique_interfaces_q <= 0;
      current_interface_q <= 0;
      current_alt_q <= 0;
      have_interface_q <= 1'b0;
      current_ep_expected_q <= 0;
      current_ep_count_q <= 0;
      current_audio_stream_q <= 1'b0;
      current_pcm_q <= 1'b0;
      current_match_format_q <= 1'b0;
      fmt_channels_q <= 0;
      fmt_bits_q <= 0;
      fmt_rate_q <= 0;
      candidate_found_q <= 1'b0;
      candidate_interface_q <= 0;
      candidate_alt_q <= 0;
      candidate_endpoint_q <= 0;
      candidate_packet_q <= 0;
      candidate_interval_q <= 0;
      candidate_channels_q <= 0;
      candidate_bits_q <= 0;
      candidate_rate_q <= 0;
      done_o <= 1'b0;
      valid_o <= 1'b0;
      error_o <= 1'b0;
      interface_o <= 0;
      alternate_setting_o <= 0;
      endpoint_o <= 0;
      max_packet_size_o <= 0;
      interval_o <= 0;
      channels_o <= 0;
      sample_bits_o <= 0;
      sample_rate_o <= 0;
    end else begin
      done_o <= 1'b0;
      if (start_i) begin
        active_q <= 1'b0;
        total_q <= total_length_i;
        consumed_q <= 0;
        desc_len_q <= 0;
        desc_pos_q <= 0;
        desc_start_q <= 0;
        desc_active_q <= 1'b0;
        config_seen_q <= 1'b0;
        declared_interfaces_q <= 0;
        interface_seen_q <= '0;
        unique_interfaces_q <= 0;
        current_interface_q <= 0;
        current_alt_q <= 0;
        have_interface_q <= 1'b0;
        current_ep_expected_q <= 0;
        current_ep_count_q <= 0;
        current_audio_stream_q <= 1'b0;
        current_pcm_q <= 1'b0;
        current_match_format_q <= 1'b0;
        candidate_found_q <= 1'b0;
        candidate_interface_q <= 0;
        candidate_alt_q <= 0;
        candidate_endpoint_q <= 0;
        candidate_packet_q <= 0;
        candidate_interval_q <= 0;
        candidate_channels_q <= 0;
        candidate_bits_q <= 0;
        candidate_rate_q <= 0;
        valid_o <= 1'b0;
        error_o <= 1'b0;
        if (total_length_i < 9 || total_length_i > 2048) begin
          active_q <= 1'b0;
          done_o <= 1'b1;
          error_o <= 1'b1;
        end else active_q <= 1'b1;
      end else if (active_q && byte_valid_i && byte_ready_o) begin
        if (consumed_q >= total_q) begin
          fail_parse();
        end else if (!desc_active_q) begin
          if (byte_data_i < 2 || (consumed_q == 0 && byte_data_i < 9)) begin
            fail_parse();
          end else if ({1'b0, consumed_q} + {8'b0, byte_data_i} > {1'b0,total_q}) begin
            fail_parse();
          end else begin
            desc_len_q <= byte_data_i;
            desc_pos_q <= 1;
            desc_start_q <= consumed_q;
            desc_buf[0] <= byte_data_i;
            desc_active_q <= 1'b1;
            consumed_q <= consumed_q + 1'b1;
            if (byte_data_i == 1) begin
              // bLength=1 is never a legal USB descriptor.
              fail_parse();
            end
          end
        end else begin
          desc_buf[desc_pos_q] <= byte_data_i;
          consumed_q <= consumed_q + 1'b1;
          if (desc_pos_q == desc_len_q - 1'b1) begin
            desc_active_q <= 1'b0;
            desc_pos_q <= 0;
            malformed_this_desc = 1'b0;
            b_length = desc_len_q;
            b_type = desc_buf[1];
            if (consumed_q + 1'b1 == total_q && b_type != DESC_CONFIGURATION && !config_seen_q) begin
              fail_parse();
              malformed_this_desc = 1'b1;
            end else begin
              case (b_type)
                DESC_CONFIGURATION: begin
                  if (config_seen_q || desc_start_q != 0 || b_length < 9 ||
                      {desc_buf[3], desc_buf[2]} != total_q || desc_buf[4] == 0) begin
                    fail_parse();
                    malformed_this_desc = 1'b1;
                  end else begin
                    config_seen_q <= 1'b1;
                    declared_interfaces_q <= desc_buf[4];
                  end
                end
                DESC_INTERFACE: begin
                  if (b_length < 9) begin fail_parse(); malformed_this_desc = 1'b1; end
                  else begin
                    if (have_interface_q && current_ep_count_q != current_ep_expected_q) begin
                      fail_parse(); malformed_this_desc = 1'b1;
                    end
                    current_interface_q <= desc_buf[2];
                    current_alt_q <= desc_buf[3];
                    current_ep_expected_q <= desc_buf[4];
                    current_ep_count_q <= 0;
                    have_interface_q <= 1'b1;
                    current_audio_stream_q <= desc_buf[5] == 1 && desc_buf[6] == 2;
                    current_pcm_q <= 1'b0;
                    current_match_format_q <= 1'b0;
                    if (!interface_seen_q[desc_buf[2]]) begin
                      interface_seen_q[desc_buf[2]] <= 1'b1;
                      unique_interfaces_q <= unique_interfaces_q + 1'b1;
                    end
                  end
                end
                DESC_CS_INTERFACE: begin
                  if (b_length < 3) begin fail_parse(); malformed_this_desc = 1'b1; end
                  else if (current_audio_stream_q && desc_buf[2] == 1) begin
                    if (b_length < 7) begin fail_parse(); malformed_this_desc = 1'b1; end
                    else current_pcm_q <= {(desc_pos_q == 6 ? byte_data_i : desc_buf[6]),desc_buf[5]} == 16'h0001;
                  end else if (current_audio_stream_q && desc_buf[2] == 2) begin
                    if (b_length < 8) begin fail_parse(); malformed_this_desc = 1'b1; end
                    else begin
                      fmt_channels_q <= desc_buf[4];
                      fmt_bits_q <= desc_buf[6];
                      fmt_rate_q <= 0;
                      rate_matches = 1'b0;
                      // FORMAT_TYPE_I: sample frequencies begin at byte 8,
                      // encoded as 24-bit little-endian values.
                      if (desc_buf[3] == 1 && desc_buf[4] == TARGET_CHANNELS &&
                          desc_buf[5] == (TARGET_BITS/8) && desc_buf[6] == TARGET_BITS) begin
                        if (desc_buf[7] == 0) begin
                          if (b_length != 14) begin fail_parse(); malformed_this_desc = 1'b1; end
                          else rate_matches =
                            {desc_buf[10],desc_buf[9],desc_buf[8]} <= {8'h00,TARGET_RATE_HZ} &&
                            {8'h00,TARGET_RATE_HZ} <= {desc_buf[13],desc_buf[12],desc_buf[11]};
                        end else if (b_length != 8 + 3*desc_buf[7]) begin
                          fail_parse(); malformed_this_desc = 1'b1;
                        end else begin
                          for (int k=0;k<81;k++) begin
                            if ((8 + k*3 + 2) < b_length &&
                                {(int'(desc_pos_q) == 10+k*3 ? byte_data_i : desc_buf[10+k*3]),
                                 (int'(desc_pos_q) == 9+k*3 ? byte_data_i : desc_buf[9+k*3]),
                                 (int'(desc_pos_q) == 8+k*3 ? byte_data_i : desc_buf[8+k*3])} == {8'h00,TARGET_RATE_HZ})
                              rate_matches = 1'b1;
                          end
                        end
                      end
                      current_match_format_q <= rate_matches;
                      fmt_rate_q <= TARGET_RATE_HZ;
                    end
                  end
                end
                DESC_ENDPOINT: begin
                  if (b_length < 7) begin fail_parse(); malformed_this_desc = 1'b1; end
                  else begin
                    packet_size = {5'b0,desc_buf[5][2:0],desc_buf[4]};
                    endpoint_interval = (desc_pos_q == 6 ? byte_data_i : desc_buf[6]);
                    if (!have_interface_q || current_ep_count_q >= current_ep_expected_q) begin
                      fail_parse(); malformed_this_desc = 1'b1;
                    end else begin
                      current_ep_count_q <= current_ep_count_q + 1'b1;
                    end
                    if (have_interface_q && current_ep_count_q < current_ep_expected_q &&
                        config_seen_q && current_audio_stream_q && current_pcm_q &&
                        current_match_format_q && desc_buf[2][7] &&
                        (TARGET_ENDPOINT == 0 || desc_buf[2] == TARGET_ENDPOINT) &&
                        desc_buf[3][1:0] == 2'b01 && endpoint_interval == 1 &&
                        desc_buf[5][7:3] == 0 && packet_size >= MIN_PACKET_BYTES &&
                        packet_size <= MAX_PACKET_BYTES &&
                        !candidate_found_q) begin
                      candidate_found_q <= 1'b1;
                      candidate_interface_q <= current_interface_q;
                      candidate_alt_q <= current_alt_q;
                      candidate_endpoint_q <= desc_buf[2];
                      candidate_packet_q <= packet_size[10:0];
                      candidate_interval_q <= endpoint_interval;
                      candidate_channels_q <= fmt_channels_q;
                      candidate_bits_q <= fmt_bits_q;
                      candidate_rate_q <= fmt_rate_q;
                    end
                  end
                end
                default: begin end
              endcase
              if (consumed_q + 1'b1 == total_q) begin
                active_q <= 1'b0;
                done_o <= 1'b1;
                if (malformed_this_desc) begin
                  error_o <= 1'b1;
                  valid_o <= 1'b0;
                end else if (!config_seen_q || candidate_found_q == 1'b0) begin
                  // A matching endpoint in this final descriptor is reflected
                  // in candidate_found_q only next cycle, so check this case.
                  if (!(b_type == DESC_ENDPOINT && config_seen_q && current_audio_stream_q && current_pcm_q &&
                        current_match_format_q && desc_buf[2][7] &&
                        (TARGET_ENDPOINT == 0 || desc_buf[2] == TARGET_ENDPOINT) &&
                        desc_buf[3][1:0] == 2'b01 && endpoint_interval == 1 &&
                        desc_buf[5][7:3] == 0 && packet_size >= MIN_PACKET_BYTES &&
                        packet_size <= MAX_PACKET_BYTES)) begin
                    error_o <= 1'b1;
                  end else begin
                    valid_o <= 1'b1;
                    error_o <= 1'b0;
                    interface_o <= current_interface_q;
                    alternate_setting_o <= current_alt_q;
                    endpoint_o <= desc_buf[2];
                    max_packet_size_o <= packet_size[10:0];
                    interval_o <= endpoint_interval;
                    channels_o <= fmt_channels_q;
                    sample_bits_o <= fmt_bits_q;
                    sample_rate_o <= fmt_rate_q;
                  end
                end else begin
                  valid_o <= 1'b1;
                  error_o <= 1'b0;
                  interface_o <= candidate_interface_q;
                  alternate_setting_o <= candidate_alt_q;
                  endpoint_o <= candidate_endpoint_q;
                  max_packet_size_o <= candidate_packet_q;
                  interval_o <= candidate_interval_q;
                  channels_o <= candidate_channels_q;
                  sample_bits_o <= candidate_bits_q;
                  sample_rate_o <= candidate_rate_q;
                end
                if ((unique_interfaces_q +
                     ((b_type == DESC_INTERFACE && !interface_seen_q[desc_buf[2]]) ? 8'd1 : 8'd0)) != declared_interfaces_q) begin
                  error_o <= 1'b1;
                  valid_o <= 1'b0;
                end
                if (b_type == DESC_INTERFACE) begin
                  if (desc_buf[4] != 0) begin error_o <= 1'b1; valid_o <= 1'b0; end
                end else if (current_ep_count_q + {7'd0,(b_type == DESC_ENDPOINT)} != current_ep_expected_q) begin
                  error_o <= 1'b1;
                  valid_o <= 1'b0;
                end
              end
            end
          end else desc_pos_q <= desc_pos_q + 1'b1;
        end
      end
    end
  end
endmodule
