// Complete FPGA-side audio path between the MAX3421E USB shield and ESP32.
// The USB host returns 32-bit stereo PCM words; the frame encoder and SPI
// master preserve the existing ESP32 wire protocol. Board pad routing lives
// in de10_lite_usb_audio_pads, outside this functional subsystem.
module usb_audio_fpga_subsystem (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        usb_int_n_i,
  input  logic        usb_miso_i,
  output logic        usb_sck_o,
  output logic        usb_mosi_o,
  output logic        usb_cs_n_o,
  input  logic        esp_miso_i,
  output logic        esp_sck_o,
  output logic        esp_mosi_o,
  output logic        esp_cs_n_o,
  output logic        esp_busy_o,
  output logic        esp_stall_o,
  output logic        connected_o,
  output logic        enumerated_o,
  output logic        streaming_o,
  output logic        host_fault_o,
  output logic        sample_accepted_o,
  output logic [31:0] dropped_packets_o,
  output logic [31:0] missed_frames_o,
  output logic [31:0] protocol_errors_o
);
  logic [31:0] sample_data, frame_data;
  logic sample_valid, sample_ready;
  logic frame_valid, frame_ready;

  usb_audio_host_top u_usb_audio_host (
    .clk_i,
    .rst_ni,
    .int_n_i(usb_int_n_i),
    .miso_i(usb_miso_i),
    .sck_o(usb_sck_o),
    .mosi_o(usb_mosi_o),
    .cs_n_o(usb_cs_n_o),
    .sample_data_o(sample_data),
    .sample_valid_o(sample_valid),
    .sample_ready_i(sample_ready),
    .connected_o,
    .enumerated_o,
    .streaming_o,
    .fault_o(host_fault_o),
    .frame_count_o(),
    .packet_count_o(),
    .dropped_packets_o,
    .missed_frames_o,
    .protocol_errors_o,
    .sample_count_o(),
    .buffer_high_water_o()
  );

  // Frames are 16 32-bit words: header/sequence, 14 PCM words, CRC-32.
  // PCM channel order remains {right_s16, left_s16}.
  spi_frame_encoder #(.DATA_WIDTH(32), .PAYLOAD_WORDS(14)) u_frame_encoder (
    .clk_i,
    .rst_ni,
    .payload_data_i(sample_data),
    .payload_valid_i(sample_valid),
    .payload_ready_o(sample_ready),
    .tx_data_o(frame_data),
    .tx_valid_o(frame_valid),
    .tx_ready_i(frame_ready)
  );

  // DIV=4 produces 5 MHz from 50 MHz. CPHA=1 matches ESP-IDF's DMA timing
  // requirement for the ESP32 SPI slave while keeping the existing 64-byte
  // frame and GPIO wiring unchanged.
  spi #(
    .DATA_WIDTH(32),
    .NUM_CS(1),
    .SPI_FIFO_DEPTH(16),
    .SPI_CLK_DIV_WIDTH(8),
    .SPI_CLK_DIV(4),
    // Leave CS inactive for 100 us between frames. USB audio arrives in
    // short bursts; this gives the ESP32 slave time to re-arm its next DMA
    // descriptor between framed transactions without delaying the 1 ms USB
    // frame schedule.
    .SPI_CS_GAP_CYCLES(5000),
    .SPI_WORDS_PER_FRAME(16),
    .CPOL(1'b0),
    .CPHA(1'b1),
    .CS_INTER_BYTE(1'b1)
  ) u_esp32_spi (
    .clk_i,
    .rst_ni,
    .tx_data_i(frame_data),
    .tx_valid_i(frame_valid),
    .tx_ready_o(frame_ready),
    .tx_stall_o(esp_stall_o),
    .rx_data_o(),
    .rx_valid_o(),
    .rx_ready_i(1'b1),
    .miso_i(esp_miso_i),
    .mosi_o(esp_mosi_o),
    .sck_o(esp_sck_o),
    .cs_n_o(esp_cs_n_o),
    .busy_o(esp_busy_o),
    .xfer_done_o()
  );

  // The board LED latches the exact ready/valid acceptance event.
  assign sample_accepted_o = sample_valid && sample_ready;
endmodule
