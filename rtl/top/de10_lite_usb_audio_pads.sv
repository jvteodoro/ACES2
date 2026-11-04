// Physical pad routing for the DE10-Lite, an Arduino-style MAX3421E shield,
// and the ESP32 SPI link. This module owns all tri-state and pin-index logic.
module de10_lite_usb_audio_pads #(
  parameter int unsigned USB_INT_ARDUINO_PIN = 9
) (
  inout  wire  [35:0] gpio,
  inout  wire  [15:0] arduino_io,
  input  logic        reset_n_i,
  output logic        arduino_reset_n_o,
  input  logic        usb_sck_i,
  input  logic        usb_mosi_i,
  input  logic        usb_cs_n_i,
  output logic        usb_miso_o,
  output logic        usb_int_n_o,
  input  logic        esp_sck_i,
  input  logic        esp_mosi_i,
  input  logic        esp_cs_n_i,
  output logic        esp_miso_o
);
  // The common MAX3421E shield routes INT to D9 and SPI to D10-D13.
  // Reject mappings that collide with SPI or exceed the Arduino header.
  // synthesis translate_off
  initial begin
    if (USB_INT_ARDUINO_PIN > 15 ||
        (USB_INT_ARDUINO_PIN >= 10 && USB_INT_ARDUINO_PIN <= 13))
      $fatal(1, "USB INT Arduino index must be outside IO10..IO13");
  end
  // synthesis translate_on

  assign usb_int_n_o = arduino_io[USB_INT_ARDUINO_PIN];
  assign usb_miso_o = arduino_io[12];
  assign arduino_reset_n_o = reset_n_i;

  // ESP32 transport: GPIO0=SCK, GPIO1=MISO, GPIO2=MOSI, GPIO3=CS#.
  assign gpio[0] = esp_sck_i;
  assign gpio[1] = 1'bz;
  assign esp_miso_o = gpio[1];
  assign gpio[2] = esp_mosi_i;
  assign gpio[3] = esp_cs_n_i;
  assign gpio[35:4] = 32'hzzzz_zzzz;

  // D10=CS#, D11=MOSI, D12=MISO, D13=SCK. D8/GPX and all
  // unrelated Arduino header pins remain high impedance.
  genvar pin;
  generate
    for (pin = 0; pin < 16; pin = pin + 1) begin : g_arduino_pads
      if (pin == USB_INT_ARDUINO_PIN || pin == 8 || pin == 12 ||
          pin == 0 || pin == 1 || pin == 2 || pin == 3 || pin == 4 ||
          pin == 5 || pin == 6 || pin == 7 || pin == 14 || pin == 15) begin : g_input_or_unused
        assign arduino_io[pin] = 1'bz;
      end else if (pin == 10) begin : g_usb_cs
        assign arduino_io[pin] = usb_cs_n_i;
      end else if (pin == 11) begin : g_usb_mosi
        assign arduino_io[pin] = usb_mosi_i;
      end else if (pin == 13) begin : g_usb_sck
        assign arduino_io[pin] = usb_sck_i;
      end else begin : g_unused
        assign arduino_io[pin] = 1'bz;
      end
    end
  endgenerate
endmodule
