// Maps subsystem state to the DE10-Lite red LEDs.
// LEDR4 is sticky: it records the first accepted PCM sample until reset.
module de10_lite_status_leds (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        connected_i,
  input  logic        enumerated_i,
  input  logic        streaming_i,
  input  logic        host_fault_i,
  input  logic        sample_accepted_i,
  input  logic        esp_busy_i,
  input  logic        esp_stall_i,
  input  logic [31:0] dropped_packets_i,
  input  logic [31:0] missed_frames_i,
  input  logic [31:0] protocol_errors_i,
  output logic [9:0]  ledr_o
);
  logic sample_seen_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)       sample_seen_q <= 1'b0;
    else if (sample_accepted_i) sample_seen_q <= 1'b1;
  end

  // LEDR[0..9]: connected, enumerated, streaming, fault, sample seen,
  // ESP SPI busy, ESP SPI stall, dropped packet, missed frame, protocol error.
  assign ledr_o = {
    (protocol_errors_i != 0),
    (missed_frames_i != 0),
    (dropped_packets_i != 0),
    esp_stall_i,
    esp_busy_i,
    sample_seen_q,
    host_fault_i,
    streaming_i,
    enumerated_i,
    connected_i
  };
endmodule
