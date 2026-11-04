# DE10-Lite USB audio host wrapper

`aces2_usb_audio_top` is a separate board wrapper for the pure-RTL MAX3421E
host. Its Quartus project is `quartus/de10_lite/aces2_usb_audio.qpf`
with revision `aces2_usb_audio`; its output directory is
`output_files_usb_audio`. The wrapper uses only CLK1_50, KEY0, LEDs, GPIO, and
the Arduino connector, and reserves unused board pins as tri-stated inputs.
The Quartus configuration builds a programming image only; it does not flash
or program the board.

## Host and transport wiring

The MAX3421E SPI host is on the DE10-Lite Arduino header:

| Arduino signal | DE10-Lite IO | FPGA pin | Direction |
| --- | ---: | --- | --- |
| CS_n | IO10 | AB19 | FPGA to MAX3421E |
| MOSI | IO11 | AA19 | FPGA to MAX3421E |
| MISO | IO12 | Y19 | MAX3421E to FPGA |
| SCK | IO13 | AB20 | FPGA to MAX3421E |
| INT_n | IO9 / D9 | AA17 | MAX3421E to FPGA |
| RES_n | Arduino RESET header | F16 | FPGA to MAX3421E |

The default full-size MAX3421E USB Host Shield routing is D9=INT, D10=CS,
D11=MOSI, D12=MISO, D13=SCK; MAX3421E RES# follows the Arduino RESET rail.
D8 is GPX on common shields and remains high impedance. The wrapper drives the
dedicated `arduino_reset_n` output from its reset conditioner and reads
active-low INT at IO9. This follows the USB Host Shield Hardware Manual; a
clone or modified board may route these signals differently, so confirm its
revision and solder jumpers before relying on that mapping.

The controller configures INT as active-low, open-drain (PINCTL `0x18`), so the
MAX3421E board must provide a pull-up to its VL supply. Check the actual
pull-up, level shifters, VL, and MISO voltage before connecting; the DE10-Lite
Arduino pads use 3.3-V LVTTL. The project does not assume the third-party
shield's logic voltage or power configuration.

KEY0 (FPGA pin B8) asynchronously asserts the wrapper reset. Its 12-stage
release conditioner keeps the host and ESP32 transport reset through twelve
50 MHz clock edges. This gives at least 220 ns from any KEY0 release phase,
exceeding the MAX3421E Rev. 4 minimum RES# pulse of 200 ns. KEY1 (pin A7) is
not used.

The existing 32-bit framed SPI transport is reused on GPIO0=SCK, GPIO1=MISO,
GPIO2=MOSI, GPIO3=CS_n. Its frame remains the `ACED`/sequence header, 14
payload words, and CRC-32. Each USB sample is one payload word packed as
`{right_s16,left_s16}`; the wrapper does not downmix or change the frame
protocol. The FPGA uses divider 4, so this 50 MHz design clocks the ESP32 at
5 MHz in SPI mode 1 (`CPOL=0`, `CPHA=1`). The firmware selects `SPI3_HOST` for
GPIO18/19/23/5, the dedicated SPI3 pins on the classic ESP32, with DMA and a
100 µs CS-inactive interval between frames. The physical receiver setup/cable
timing still needs measurement; see the
[ESP32 transport postmortem](esp32_spi_audio_postmortem.md).

LEDs show connected, enumerated, streaming, host fault, sample-valid, ESP32 SPI
busy/stall, and nonzero drop/missed-frame/protocol-error indicators.

## Timing and validation

The SDC constrains the 50 MHz board clock, generated 25 MHz MAX3421E SCK and
generated 5 MHz ESP32 SCK, MISO using the datasheet's 14.2 ns maximum
SCLK-fall-to-MISO-valid delay, MOSI using
the 5 ns setup/10 ns hold requirements, and CS using the 30 ns setup/hold
requirements. It false-paths KEY0 only to the asynchronous reset-release
conditioner. Jumper/cable board delays are not known or included, so this SDC
does not claim external-interface timing closure. The DE10 pad voltage is
3.3 V LVTTL; verify the actual MAX3421E module's VL and pull-up before use.

Run the board-wrapper simulation with the repository's Verilator installation
by compiling `tb/usb/aces2_usb_audio_top_tb.sv` and the RTL source list from the
new QSF. The bench checks the sub-clock asynchronous KEY0 pulse, guarded reset
release, external INT/MISO pad selection, and both SPI pin maps. It now also
connects the MAX3421E/UM2 behavioral model to the Arduino SPI pins and verifies
PCM frames on the GPIO transport; see `results/board_gpio_frame.md`. This is
digital model evidence, not physical USB capture. The Quartus wrapper project
must also be fitted and its pad/timing reports reviewed separately.

The configurable INT input must remain within Arduino IO0..IO15 and outside
IO10..IO13. If the installed shield routes INT elsewhere, update the top
parameter and wiring documentation, then verify the QSF pad map and external
wiring together. Reset remains on the dedicated Arduino RESET net for the
standard full-size shield. All unused Arduino and GPIO signals are tri-stated;
the project does not assign or drive unrelated SDRAM, VGA, ADC, or sensor pins.
