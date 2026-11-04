`timescale 1ns/1ps

// Frames accepted PCM words for the existing ESP32 protocol. It accumulates
// a fixed 14-word payload, then emits a 16-word frame:
//   word 0  : 16'hACED + 16-bit sequence
//   words 1-14: payload
//   word 15 : CRC-32/IEEE over header and payload
module spi_frame_encoder #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned PAYLOAD_WORDS = 14,
  parameter logic [15:0] MAGIC = 16'hACED
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic [DATA_WIDTH-1:0]  payload_data_i,
  input  logic                   payload_valid_i,
  output logic                   payload_ready_o,
  output logic [DATA_WIDTH-1:0]  tx_data_o,
  output logic                   tx_valid_o,
  input  logic                   tx_ready_i
);

  typedef enum logic [1:0] {COLLECT, SEND_HEADER, SEND_PAYLOAD, SEND_CRC} state_t;
  state_t state_q;
  logic [DATA_WIDTH-1:0] payload_q [0:PAYLOAD_WORDS-1];
  localparam int unsigned PAYLOAD_COUNT_WIDTH = $clog2(PAYLOAD_WORDS+1);
  localparam int unsigned SEND_INDEX_WIDTH = (PAYLOAD_WORDS <= 1) ? 1 : $clog2(PAYLOAD_WORDS);
  logic [DATA_WIDTH-1:0] crc_q;
  logic [DATA_WIDTH-1:0] crc_word_q;
  logic [15:0] sequence_q;
  logic [PAYLOAD_COUNT_WIDTH-1:0] payload_count_q;
  logic [SEND_INDEX_WIDTH-1:0] send_index_q;

  function automatic logic [31:0] crc32_word(
    input logic [31:0] crc_i,
    input logic [31:0] data_i
  );
    logic [31:0] crc;
    logic [7:0] byte_value;
    integer byte_index;
    integer bit_index;
    begin
      crc = crc_i;
      for (byte_index = 3; byte_index >= 0; byte_index = byte_index - 1) begin
        byte_value = data_i[byte_index*8 +: 8];
        crc = crc ^ {24'b0, byte_value};
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
          if (crc[0]) crc = (crc >> 1) ^ 32'hEDB8_8320;
          else        crc = crc >> 1;
        end
      end
      crc32_word = crc;
    end
  endfunction

  logic [31:0] header_word;
  assign header_word = {MAGIC, sequence_q};

  always_comb begin
    payload_ready_o = rst_ni && (state_q == COLLECT) &&
                      (payload_count_q < PAYLOAD_COUNT_WIDTH'(PAYLOAD_WORDS));
    tx_valid_o = rst_ni && (state_q != COLLECT);
    case (state_q)
      SEND_HEADER:  tx_data_o = header_word;
      SEND_PAYLOAD: tx_data_o = payload_q[send_index_q];
      SEND_CRC:     tx_data_o = crc_word_q;
      default:      tx_data_o = '0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q         <= COLLECT;
      crc_q           <= 32'hFFFF_FFFF;
      crc_word_q      <= '0;
      sequence_q      <= '0;
      payload_count_q <= '0;
      send_index_q    <= '0;
    end else begin
      if (state_q == COLLECT && payload_valid_i && payload_ready_o) begin
        payload_q[payload_count_q] <= payload_data_i;
        payload_count_q <= payload_count_q + 1'b1;
        if (payload_count_q == 0)
          crc_q <= crc32_word(crc32_word(32'hFFFF_FFFF, header_word),
                              payload_data_i);
        else
          crc_q <= crc32_word(crc_q, payload_data_i);
        if (payload_count_q == PAYLOAD_COUNT_WIDTH'(PAYLOAD_WORDS-1)) begin
          crc_word_q      <= crc32_word(crc_q, payload_data_i) ^ 32'hFFFF_FFFF;
          state_q         <= SEND_HEADER;
          send_index_q    <= '0;
        end
      end else if (state_q == SEND_HEADER && tx_valid_o && tx_ready_i) begin
        state_q      <= SEND_PAYLOAD;
        send_index_q <= '0;
      end else if (state_q == SEND_PAYLOAD && tx_valid_o && tx_ready_i) begin
        if (send_index_q == SEND_INDEX_WIDTH'(PAYLOAD_WORDS-1)) begin
          state_q    <= SEND_CRC;
        end else begin
          send_index_q <= send_index_q + 1'b1;
        end
      end else if (state_q == SEND_CRC && tx_valid_o && tx_ready_i) begin
        sequence_q      <= sequence_q + 1'b1;
        payload_count_q <= '0;
        state_q         <= COLLECT;
      end
    end
  end
endmodule
