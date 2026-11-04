`timescale 1ns/1ps

// DE10-Lite board composition. Keep this module at the board boundary:
// reset, the complete audio datapath, physical pad routing, and LED status.
module aces2_usb_audio_top #(
  parameter int unsigned USB_INT_ARDUINO_PIN = 9
) (
  input  logic        clk_50,
  input  logic [1:0]  key_n,
  output logic [9:0]  ledr,
  inout  wire  [35:0] gpio,
  inout  wire  [15:0] arduino_io,
  output logic        arduino_reset_n
);
  // These nets are the explicit interface between the board-level blocks.
  // Retain their names to keep SignalTap/board-level debug easy to follow.
  logic system_rst_n;

  logic usb_sck, usb_mosi, usb_cs_n, usb_miso, usb_int_n;
  logic esp_sck, esp_mosi, esp_miso, esp_cs_n, esp_busy, esp_stall;
  logic connected, enumerated, streaming, host_fault;
  logic sample_accepted;
  logic [31:0] dropped_packets, missed_frames, protocol_errors;

  de10_lite_reset_release u_reset_release (
    .clk_i(clk_50),
    .key0_n_i(key_n[0]),
    .rst_ni_o(system_rst_n)
  );

  usb_audio_fpga_subsystem u_audio_system (
    .clk_i(clk_50),
    .rst_ni(system_rst_n),
    .usb_int_n_i(usb_int_n),
    .usb_miso_i(usb_miso),
    .usb_sck_o(usb_sck),
    .usb_mosi_o(usb_mosi),
    .usb_cs_n_o(usb_cs_n),
    .esp_miso_i(esp_miso),
    .esp_sck_o(esp_sck),
    .esp_mosi_o(esp_mosi),
    .esp_cs_n_o(esp_cs_n),
    .esp_busy_o(esp_busy),
    .esp_stall_o(esp_stall),
    .connected_o(connected),
    .enumerated_o(enumerated),
    .streaming_o(streaming),
    .host_fault_o(host_fault),
    .sample_accepted_o(sample_accepted),
    .dropped_packets_o(dropped_packets),
    .missed_frames_o(missed_frames),
    .protocol_errors_o(protocol_errors)
  );

  de10_lite_usb_audio_pads #(
    .USB_INT_ARDUINO_PIN(USB_INT_ARDUINO_PIN)
  ) u_board_pads (
    .gpio,
    .arduino_io,
    .reset_n_i(system_rst_n),
    .arduino_reset_n_o(arduino_reset_n),
    .usb_sck_i(usb_sck),
    .usb_mosi_i(usb_mosi),
    .usb_cs_n_i(usb_cs_n),
    .usb_miso_o(usb_miso),
    .usb_int_n_o(usb_int_n),
    .esp_sck_i(esp_sck),
    .esp_mosi_i(esp_mosi),
    .esp_cs_n_i(esp_cs_n),
    .esp_miso_o(esp_miso)
  );

  de10_lite_status_leds u_status_leds (
    .clk_i(clk_50),
    .rst_ni(system_rst_n),
    .connected_i(connected),
    .enumerated_i(enumerated),
    .streaming_i(streaming),
    .host_fault_i(host_fault),
    .sample_accepted_i(sample_accepted),
    .esp_busy_i(esp_busy),
    .esp_stall_i(esp_stall),
    .dropped_packets_i(dropped_packets),
    .missed_frames_i(missed_frames),
    .protocol_errors_i(protocol_errors),
    .ledr_o(ledr)
  );
endmodule
