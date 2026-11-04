# MAX3421E and PCM2902 full path model

`tb/usb/models/max3421e_um2_model.sv` sits on the physical SPI pins of
`usb_audio_host_top`. The test does not bypass the SPI bridge, register
arbiter, host engine, control transfer, enumerator, isochronous receiver,
decoder, or sample buffer. The model samples the controller's mode-0 SCK,
MOSI, CS, and MISO transactions and implements the MAX3421E register behavior
needed for initialization and host transfers.

The USB SIE is abstracted at packet boundaries. The model validates every
control request in the tested enumeration sequence and enforces EP0 packet
chunks, address timing, status direction, DATA toggles, descriptor lengths,
configuration, and selected interface. It reads the observed 18-byte device
descriptor from `tb/usb/pcm2902_device.mem` and all 1191 configuration bytes
from `tb/usb/pcm2902_config.mem`. The stream endpoint is accepted only after
configuration 1 and interface 2 alternate 1 are active.

## Timing model

The receive FIFO has two distinct 64-byte banks. USB payload bytes arrive at
12 Mbit/s full-speed cadence (one byte every 8/12 MHz), represented by a
fractional accumulator at the system clock. At 50 MHz this produces byte gaps
of 33 or 34 clocks. A bank becomes visible to the controller when it fills or
at end of packet; releasing it requires the host to read its bytes and clear
RCVDAV. If a second bank is queued when software clears RCVDAV, the model
immediately asserts RCVDAV again. A third bank's first byte when both banks
remain occupied records an overrun and returns HRSL `6`. The model tracks
maximum occupancy, full-to-release latency, and byte gaps. The recorded
full-to-release latency starts when the 64th byte marks a bank ready and ends
when the host clears RCVDAV by W1C after draining that bank. It includes HIRQ
polling and the modeled engine/controller/SPI service path.

Frames arrive every 1 ms. The source sample clock advances once per frame,
whether or not the host requests an IN transaction, so a missed frame leaves a
real sequence gap. Packet lengths cycle through 188, 192, 196, and 192 bytes
(47, 48, 49, and 48 stereo frames); four frames therefore carry 192 samples.
Sample words are deterministic: left is the low 16 bits of the sample index,
right is its one's complement. This makes channel order, payload integrity,
frame loss, and reconnect epochs observable at the PCM output.

With the default `FAST_INIT=1`, oscillator startup is 1 ms and bus
reset/debounce use 2 ms to keep simulation time manageable. Compile with
`-GFAST_INIT=0` to use the model's 5 ms oscillator startup and the RTL's 100 ms
debounce and 50 ms bus reset. SOF and USB byte cadence remain real-time at the
selected `CLK_HZ` in either configuration.
Completion of BUSRST resets device address/configuration/interface state,
control DATA toggles, staged descriptor state, and both receive banks. This is
exercised by the reconnect/re-enumeration scenario.

## Fault controls

The model inputs support NAK, STALL, CRC error, MAX SIE transaction timeout, and
ISO overrun injection. `suppress_frame_irq_i` suppresses one or more host-visible
frame interrupts while the device sample clock continues. The TB uses a single
control NAK by default, plus disconnect/reconnect, missing-frame, and ISO
overrun cases. Plusargs `FAULT_STALL`, `FAULT_CRC`, `FAULT_TIMEOUT`, and
`FAULT_NAK_EXHAUST` run isolated control-failure checks.

## Run

From the repository root:

```sh
verilator --binary --timing -Wno-fatal -j 0 --top-module usb_audio_host_tb \
  --Mdir /tmp/um2_model_build \
  tb/usb/models/max3421e_um2_model.sv rtl/usb/usb_audio_host_top.sv \
  rtl/usb/max3421e_controller.sv rtl/usb/max3421e_spi_bridge.sv \
  rtl/usb/usb_host_engine.sv rtl/usb/usb_control_transfer.sv \
  rtl/usb/usb_enumerator.sv rtl/usb/usb_descriptor_parser.sv \
  rtl/usb/usb_isochronous_receiver.sv rtl/usb/usb_pcm_decoder.sv \
  rtl/usb/audio_sample_buffer.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv tb/usb/usb_audio_host_tb.sv
```

Run `/tmp/um2_model_build/Vusb_audio_host_tb` from the repository root so the
descriptor memory paths resolve. Add `+SMOKE` for a 12-frame positive check,
or a `+FAULT_*` option for an isolated control failure. Compile with
`-GFAST_INIT=0` for full reset/debounce timing. Build with `-GCLK_HZ=10000000` for the
negative service-rate case; at 10 MHz system clock the SPI bridge runs at 5 MHz
while USB bytes retain the same 12 Mbit/s full-speed cadence. The two receive
banks then overrun when host service cannot free a bank before the third bank's
first byte.

## Recorded runs

The 50 MHz `+SMOKE` run completed the captured device/configuration control
sequence (7 SETUPs, 7 status stages, 26 device-descriptor bytes, and 1200
configuration bytes including the 9-byte header), then accepted 11 ISO packets
and 528 valid PCM sample frames. It had no dropped packets or protocol errors,
reached both banks, and released the oldest full bank in 1690 system clocks
(33.8 us from its 64th byte through completed W1C).
The run also observed RCVDAV reassertion while a second bank was already
queued.

The 10 MHz run, with USB byte timing unchanged and SPI at 5 MHz, reached both
banks, failed to meet the service deadline (2718 clocks to release), and
recorded 11 receive overruns. This is an intentionally failing bandwidth
configuration; no PCM packets were accepted.

Isolated STALL, CRC, MAX transaction-timeout, and repeated-NAK control cases are
available as plusargs. The timeout input returns the MAX SIE timeout result
code. They test control enumeration error reporting; they do not claim to test
an ISO CRC failure after streaming starts.

## Scope and limitations

This model verifies register-level SPI traffic and packet-level USB behavior.
It does not simulate USB differential signaling, bit stuffing, CRC waveforms,
handshake timing within a bit cell, or electrical disconnect behavior. MAX3421E
SIE register effects and the two FIFO banks are modeled explicitly, but this
does not replace physical hardware capture. Results establish behavior against
the captured descriptor bytes and this timing model only.
Detailed full-stream, recovery, reset-timing, fault, and negative-bandwidth
results plus frozen source hashes are in
[`results/model_run.md`](results/model_run.md).
