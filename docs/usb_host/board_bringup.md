# DE10-Lite USB host board bring-up

## Readiness and current bench state (updated 2026-11-03)

The physical chain UM2 → MAX3421E shield → DE10-Lite MAX 10 → SPI → ESP32 →
Wi-Fi/UDP → Python receiver was brought up. The user confirmed the system was
working and could capture audio to WAV for later listening. The ESP32 monitor
observed approximately 3,530 complete 512-bit SPI frames/s, zero invalid
frames and zero CRC errors in steady state. The final FPGA debug image uses a
100 µs inactive-CS interval between frames; diagnostic history and the exact
SPI changes are in
[`esp32_spi_audio_postmortem.md`](esp32_spi_audio_postmortem.md).

The user measured 4.8 V at USB-A VBUS with the UM2 connected and disconnected.
The shield marking is “2045L USB Host Shield”; a revision-specific schematic
was not identified. The successful physical operation verifies that the
connected setup works, but does not identify every internal shield revision,
prove electrical timing margin at the ESP32 pad, or characterize audio quality
with a calibrated tone.

The image was built from Quartus revision `aces2_usb_audio`, whose top entity
is `aces2_usb_audio_top`. The separate legacy revision `aces2_de10_lite` uses
`aces2_top` and a WAV-derived ROM mock; it does not instantiate the USB host.
Program the USB-audio `.sof` above for this procedure. Its SHA-256 from the
2026-11-02 build is
`e5727a24cf0f4465e0412081620fb965dea75a05ea5134fac6cfc1f9b74d8afc`.

The open GPIO2 MOSI/GPIO3 CS output delays are for the ESP32 sample transport.
They do not constrain the MAX3421E USB-host SPI interface. Physical transport
to the ESP32 now works; pad-level receiver timing remains unmeasured. The ESP32
never runs the USB stack.

## Verified board connections

The DE10-Lite User Manual dated October 17, 2022 lists the Arduino Uno R3
header signals and MAX 10 package pins in Table 3-8 (manual page 32):

| MAX3421E signal | DE10-Lite Arduino signal | MAX 10 pin | Direction at FPGA |
| --- | --- | --- | --- |
| SS / chip select | Arduino_IO10 / D10 | AB19 | output |
| MOSI | Arduino_IO11 / D11 | AA19 | output |
| MISO | Arduino_IO12 / D12 | Y19 | input |
| SCLK | Arduino_IO13 / D13 | AB20 | output |
| MAX3421E RES# | ARDUINO_RESET_N | F16 | output, active low |

The manual labels these digital I/O pins 3.3-V LVTTL and ARDUINO_RESET_N active
low. The common full-size MAX3421E Host Shield maps D10=CS, D11=MOSI, D12=MISO,
D13=SCK, D9=INT, and MAX3421E RES# to Arduino RESET; D8/GPX is not used by this
top. Shield clones and modified boards can differ, so identify the exact
revision and check its schematic/jumpers before relying on this routing.

MAX3421E SCLK, MOSI, SS, and RES input thresholds are referenced to VL. Its
datasheet allows VL from 1.4 V to 3.6 V and describes internal SPI level
translation. For a direct DE10-Lite connection, confirm that the module drives
VL at a compatible voltage, that its MISO high level is safe for the FPGA, and
that grounds are common. The board manual's 3.3-V LVTTL marking does not
identify the level shifter or regulator fitted to a third-party shield. Do not
connect the shield's INT or RES line until its pinout and voltage are verified.

## SPI timing target

The Quartus bridge uses the 50 MHz DE10-Lite clock. Divider zero in
`spi_master` changes SCLK on each system-clock edge, yielding a 25 MHz clock
with a 40 ns period and nominal 20 ns high/low pulses. MAX3421E datasheet Rev. 4
SPI timing characteristics (page 13, VL > 2.5 V) specify a minimum 38.4 ns SCLK period, 17 ns
high and low pulses, 30 ns SS leading time, 30 ns SS trailing time, 5 ns data
input setup, and 14.2 ns SCLK-fall-to-MISO propagation. Thus the frequency
margin is only 1.6 ns per period. The bridge holds SS for at least two 50 MHz
clock intervals after the final SCLK edge (nominally 40 ns); its testbench
checks SS setup/hold, SCLK period/pulse widths, MOSI setup, and a modeled
MAX3421E MISO output delay.

The 25 MHz generated SCLK is below the MAX3421E's 26 MHz stated maximum, but
that comparison alone is not a board timing closure result. The testbench uses
ideal RTL timing. Quartus timing analysis must include the board clock,
generated SCLK, SCLK-to-MISO input delay, and MOSI/SS output delays based on
the actual shield and interconnect. Do not treat a virtual-pin synthesis run
as I/O timing closure.

The current Verilator bridge test measured 6 system clocks from accepted
one-byte request to CS assertion and 50 clocks to response; for a 64-byte
request it measured 69 clocks to CS and 1436 clocks to response. These values include the
bridge implementation and synchronous testbench handshakes, but not controller
initialization, USB-token scheduling, external SPI return delay, or host
software consumption. The bench's MISO model delays data by 14.2 ns after the
falling edge; the FPGA core samples 20 ns after that edge, leaving 5.8 ns before
board trace and input setup delays. The simulated minima were 60 ns SS setup,
40 ns SS hold, 40 ns SCLK period, 20 ns high/low pulse widths, and 20 ns MOSI
setup across 482 observed MOSI transitions. This is a simulated budget, not a
measured module waveform.

The ESP32 transport uses divider 4, producing 5 MHz, mode 1, and a 100 µs
inactive-CS gap between 512-bit frames. Espressif's ESP-IDF guide documents
10 MHz as the classic ESP32 SPI-slave ceiling. The firmware uses `SPI3_HOST`
with GPIO18/19/23/5, the dedicated SPI3 IO_MUX pins. Physical pad/cable timing
is not independently measured; see
[`references/esp32_spi_slave_notes.md`](references/esp32_spi_slave_notes.md)
and the [transport postmortem](esp32_spi_audio_postmortem.md).

## Build and measurement sequence

Both Quartus projects are defined in the repository. Reproduce both fits with
`make QUARTUS_SH=/path/to/quartus_sh quartus` (or run `quartus-core` and
`quartus-board` separately). The board SDC propagates the 5 MHz ESP32 SCK
clock to GPIO0; it keeps MOSI/CS receiver setup delays open until those values
and the wiring delay are established. Diagnostic LEDs and the asynchronous
MAX reset output are excluded from synchronous setup analysis; the reset pulse
width is checked functionally in the wrapper testbench.

1. VBUS check recorded: 4.8 V with the UM2 connected and disconnected, as
   reported by the user on 2026-11-02. This is within the 4.75–5.25 V range.
   The MAX3421E logic supply/VL and exact shield revision still need
   confirmation. With the UM2 attached, the user reports only LEDR3 lit. Check
   the UM2 POWER LED; LEDR3 is the aggregate controller/enumerator fault, as
   defined in the wrapper. It does not identify the failing stage by itself.
2. Confirm the shield connector mapping, MISO voltage, INT polarity, and reset
   routing. The standard full-size MAX3421E Host Shield uses D9=INT, D10-D13=SPI,
   and the Arduino RESET rail for MAX3421E RES#; D8 is GPX and is left undriven.
3. Compare the actual shield and any solder-jumper modifications with that
   routing. The DE10-Lite Arduino RESET output is pin F16; D9 INT is AA17.
   Keep D8/GPX unconnected. Do not assume a clone uses the standard routes
   without checking its board.
4. For an isolated USB-host diagnosis, program the `aces2_usb_audio` image and
   disconnect the optional ESP32 link. For an end-to-end audio capture, use the
   debug image and ESP32 configuration documented in
   [`esp32_spi_audio_postmortem.md`](esp32_spi_audio_postmortem.md).
5. With a current-limited, powered and identified module, measure SCLK period,
   duty cycle, SS setup/hold, MOSI setup/hold, and MISO timing at the module
   connector. Verify initialization writes and OSCOK, bus J/K, BUSRST, and
   FRAMEIRQ observations before attaching a USB device.
6. With VBUS in range, keep the UM2 connected and inspect the DE10-Lite red
   LEDs. LEDR0 indicates connection; LEDR1 indicates enumeration/profile
   selection; LEDR2 indicates streaming; LEDR3 indicates `controller_fault ||
   enum_error`; LEDR4 indicates that at least one PCM frame was accepted.
   Record the complete LEDR0–4 pattern and whether the UM2 POWER LED is on.
   Confirm enumeration and one control transaction
   before enabling audio streaming; then check stream/drop/error LEDs during a
   sustained capture. This is the first physical test of the USB path.
7. For the ESP32 transport, use SPI mode 1 at 5 MHz and a 100 µs inactive-CS
   interval between frames. Confirm `trans_len=512`, CRC zero and UDP packet
   reception as described in the
   [transport postmortem](esp32_spi_audio_postmortem.md). GPIO2/3 pad-level
   timing remains open until receiver and interconnect delays are measured.

## Diagnostic indications and audio correctness

The DE10-Lite red LEDs are the first-level host diagnostics:

| LED | Meaning when lit |
| --- | --- |
| LEDR0 | MAX3421E reports a connected full-speed device |
| LEDR1 | USB enumeration and target profile selection completed |
| LEDR2 | ISO audio streaming is enabled |
| LEDR3 | host/controller or enumeration fault |
| LEDR4 | at least one PCM frame was accepted; sticky until KEY0 reset |
| LEDR5 | ESP32 SPI transfer active |
| LEDR6 | ESP32 SPI backpressure/stall |
| LEDR7 | one or more ISO packets dropped |
| LEDR8 | one or more USB frames missed |
| LEDR9 | one or more protocol errors |

### Interpreting LEDR3 during bring-up

The wrapper drives LEDR3 from `controller_fault || enum_error`. It is an
aggregate fault and does not identify the failing stage. The MAX3421E
controller can assert it after an SPI bridge error, failure to observe OSCOK
within 20 ms, failure to observe FRAMEIRQ within 20 ms, or failure to finish
the USB bus reset within 100 ms. The enumerator can also assert it after a
control-transfer or descriptor/profile failure. If LEDR3 is the only lit red
LED, there is no positive indication of a connected device, completed
enumeration, streaming, or accepted audio sample.

For a quick physical isolation, press KEY0 to clear the fault while the UM2 is
attached, then observe the board during restart. At the shield header, check
for SPI clock bursts on D13, chip select on D10, MOSI on D11, and returning data
on D12; also confirm D9 is connected to MAX3421E INT and the Arduino RESET rail
releases RES#. If SCK/CS are absent, investigate FPGA reset/configuration and
pin assignment. If SCK/CS occur but MISO is stuck or reads incorrectly, check
shield orientation, D12 continuity, common ground, MAX3421E 3.3-V/VL supply,
and level shifting. The current SPI divider produces 25 MHz, close to the
MAX3421E's 26 MHz limit; a lower SPI clock is a useful next diagnostic if the
electrical routing checks out.

On 2026-11-02, the user reported LEDR0 goes off when the UM2 is removed and
returns to a stable dim blink when it is connected; LEDR3 lights when pressing
the shield's physical reset button. The LEDR0 behavior tracks attachment but
does not prove enumeration. Avoid the shield reset button until its circuit is
identified: this top actively drives the Arduino RESET rail high while running,
and a button that pulls that same net low could contend with the FPGA output.
Use KEY0 to reset the complete setup. Record whether LEDR0 settles, LEDR1/2/4
turn on, or LEDR3 returns, and whether the UM2 POWER LED is on.

The shield silkscreen is reported as “2045L USB Host Shield”. No authoritative
revision-specific schematic was located for this marking. Photograph both
board sides and compare the actual RESET, D9–D13, and power-select routing
before treating the standard full-size pinout as confirmed.

For a full content check, the FPGA's existing GPIO SPI stream sends each
stereo frame as `{right_s16,left_s16}` with a sequence number and CRC-32. The
ESP32 is only a diagnostic/transport receiver; it does not run USB. Its serial
monitor reports malformed frames, CRC errors, sequence errors and dropped
frames. Generate and replay a known stereo signal through an analog line output
into the UM2 LINE IN inputs, then record and analyze the received stream:

```sh
python3 software/udp_receiver/aces2_udp_receiver.py \
  --channels 2 --sample-rate 48000 --wav /tmp/um2_capture.wav
```

Set the ESP32 UDP destination to the receiver's LAN address. Feed a known,
low-level line input tone to the UM2. A successful capture should show LEDR0–2
and LEDR4 lit, LEDR3 and LEDR7–9 dark, zero SPI/UDP CRC or sequence errors, no
sequence gaps, and approximately 48,000 PCM frames/s. Inspect the WAV for the
known tone in the expected channel(s). The LEDR4 presence flag alone only proves
that samples moved; frame checks plus a known signal are needed to judge PCM
content. For a reproducible stereo content check, generate and analyze the
test WAV with these commands (play it from a separate analog output into the
UM2 LINE IN; start at low volume):

```sh
python3 software/udp_receiver/make_test_tone.py /tmp/um2_test_tone.wav
python3 software/udp_receiver/aces2_udp_receiver.py --channels 2 --sample-rate 48000 --wav /tmp/um2_capture.wav
# play um2_test_tone.wav from a separate analog output into the UM2, then Ctrl-C
python3 software/udp_receiver/analyze_capture.py /tmp/um2_capture.wav
```

The WAV contains 997 Hz on left and 1597 Hz on right. The analyzer checks
48 kHz PCM16 stereo, channel frequencies, signal level, and clipping. The UDP
receiver command above must save `/tmp/um2_capture.wav`. No physical run has
yet been performed.

## Source records

- `docs/DE10-Lite_User_Manual.pdf`, Table 3-8, p. 32, and GPIO voltage table,
  Sections 3.5-3.6. SHA-256:
  `ab2c47e5a7e4ac26874013bfe05df31e2d498bc9a7f9f6b33bd931c64db848ac`.
- `docs/usb_host/references/MAX3421E.pdf`, Rev. 4, SPI timing characteristics, p. 13, and SPI
  pin descriptions, p. 5. SHA-256:
  `436111bce010e99d2e772828a89d042a40c8ab043a7daae5c898b4961878a003`.
- `docs/usb_host/references/max3421e-programming-guide.pdf`, reset,
  connection-detection, HIRQ, and host-transfer sections. SHA-256:
  `2dddf5ef4ca6a22cd9f24de3ef311a6357434d3c51e6ce1067e81328ceec9121`.

Archived-source provenance and retrieval details are recorded in
[`references/manifest.json`](references/manifest.json). The component PDFs
identify MAX3421E Rev. 4; the connected shield/module revision remains
unidentified.
