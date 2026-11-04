# Board wrapper GPIO frame verification

## Scope

The board-wrapper test keeps the KEY0 asynchronous reset and 12-edge
release checks, Arduino RESET# inactivity, jumper input checks, and both board
SPI pin maps. It adds a MAX3421E/UM2 model on the Arduino SPI pins and runs the
actual host, enumerator, ISO receive path, PCM decoder, encoder, and
`spi.sv`. An external SPI-slave monitor samples MOSI on rising SCK at GPIO
0..3 and validates complete transactions from the physical GPIO nets.

The monitor ignores the first complete ESP frame while its simulated consumer
is inactive. It then checks two complete frames for the `ACED` header,
monotonic sequence numbers, 14 stereo PCM payload words per frame, left/right
channel relation, contiguous sample IDs, and independently recomputed
CRC-32/IEEE. The captured frames were sequence 1 and 2 after one ignored frame.
The monitor also requires at least 120 ns between GPIO SCK rising edges while
CS is active, matching the 8.33 MHz board setting.

The test accelerates only the wrapper's default 100 ms attach debounce by
forcing the controller debounce counter to its terminal value for one clock.
The asynchronous board reset, host/MAX initialization, model oscillator and
2 ms bus reset, enumeration traffic, full-speed frame cadence, ISO byte
cadence, PCM decoder, frame encoder, SPI word transfers, and physical pin
monitor remain active. The existing full-path model tests separately cover
the unaccelerated host path and long-run PCM scoreboard. This test is for the
board wrapper and wire-level output framing; it does not replace them.

## Reproduction

Run from the repository root:

```sh
verilator --binary --timing -Wno-fatal --top-module aces2_usb_audio_top_tb \
  --Mdir /tmp/aces2_board_frame_obj \
  tb/usb/aces2_usb_audio_top_tb.sv tb/usb/models/max3421e_um2_model.sv \
  rtl/top/aces2_usb_audio_top.sv rtl/usb/usb_audio_host_top.sv \
  rtl/usb/usb_isochronous_receiver.sv rtl/usb/usb_control_transfer.sv \
  rtl/usb/usb_enumerator.sv rtl/usb/usb_descriptor_parser.sv \
  rtl/usb/usb_host_engine.sv rtl/usb/max3421e_controller.sv \
  rtl/usb/max3421e_spi_bridge.sv rtl/usb/usb_pcm_decoder.sv \
  rtl/usb/audio_sample_buffer.sv rtl/spi/spi_frame_encoder.sv \
  rtl/spi/spi.sv rtl/spi/spi_uc.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv
timeout 120s /tmp/aces2_board_frame_obj/Vaces2_usb_audio_top_tb
```

## Evidence

Verified independently with Verilator 5.052 after enabling the MAX bridge's
optional trailing-edge MISO sampling. Result:

```text
PASS aces2_usb_audio_top_tb: model packets=1 host samples=47 discarded frames=1 verified GPIO frames=2 seq=1..2 CRC/PCM words=28
Verilator: $finish at 9ms; walltime 7.113 s
```

The MAX model reported no USB/SPI errors or lost/missed samples. The host
accepted 47 PCM frames, while the GPIO monitor discarded one pre-consumer
transaction and checked 28 payload words across two complete transactions.
This replay validates that the new MAX MISO sample phase preserves the complete
framed GPIO PCM output through the board wrapper.

## Optional one-second GPIO regression

`make -C tb/usb board_long` runs the same wrapper test with `+LONG_RUN`. The
monitor is enabled before the first PCM frame, so sequence zero is checked too.
It waits for the UM2 model/host to deliver 48,000 synthetic stereo sample
frames, then requires at least `floor(48000 / 14) = 3,428` complete GPIO
transactions, or 47,992 verified payload samples. The eight remaining samples
are a partial encoder group and cannot form a transaction because the frame
encoder only emits after collecting 14 payload words. Every observed complete
transaction is checked for sequence continuity, CRC-32/IEEE, left/right sample
complement and sample-ID continuity; the GPIO monitor checks the SCK edge
spacing throughout for the 8.33 MHz ceiling. The test timeout is 1,800 seconds
to allow the cycle-accurate 50 MHz simulation to process the one-second stream.

Clean run with Verilator 5.052:

```text
PASS aces2_usb_audio_top_tb LONG_RUN: model packets=1000 host samples=48000 discarded=0 verified GPIO frames=3428 payload=47992 expected complete=3428 tail=8 seq=0..3427
- Verilator: $finish at 1s; walltime 556.061 s; speed 1.813 ms/s
- Verilator: cpu 552.474 s on 1 threads
```

The board wrapper's 100 ms attach debounce is accelerated as described above;
the UM2 model still produces 1,000 1 ms packets and the host accepts exactly
48,000 sample frames. There were no discarded GPIO frames. The first 47,992
samples appeared in 3,428 checked transactions, and the final eight remain in
the encoder's incomplete 14-word group. The final checked sequence is 3427.

The default fast target passed on the source used for the earlier run: 1 model
packet, 47 host samples, one deliberately discarded initial GPIO frame, and
two verified transactions (sequence 1..2, 28 payload words). The short target
was also rerun after width cleanup as part of the full USB suite; see below.

## Current-source replay after RTL width cleanup

Rebuilt/reran `make -C tb/usb board_long` against the current sizing-cleanup
sources on 2026-11-01. It passed: 1,000 modeled packets, 48,000 host samples,
zero discarded GPIO frames, 3,428 complete frames and 47,992 checked payload
samples, sequence 0..3427, with an 8-sample partial tail. PCM continuity, CRC
and the minimum 120 ns SCK interval passed. Walltime was 686.707 s, CPU 654.198
s. The `make -C tb/usb` suite also passed the short board wrapper test after
these changes.

Current source/executable SHA-256:

| File | SHA-256 |
| --- | --- |
| `tb/usb/aces2_usb_audio_top_tb.sv` | `8928785ffb44b0cd8814e557362c66ee339fda2e03dbfd0652655e49b4fd6ab2` |
| `tb/usb/Makefile` | `6e8f6c32db958b518d2c977e9b1f03ef25d11f04e7ec716fc00e73c7fb524a23` |
| `tb/usb/models/max3421e_um2_model.sv` | `ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c` |
| `tb/usb/pcm2902_device.mem` | `73864b28ff3a032c84608080a9beed2d34796bdb3aa98d159fc6da29f3e1f48a` |
| `tb/usb/pcm2902_config.mem` | `b1bafbfbfcad8d9f45a76f53ea3d0624c897e781318f70e8d98f3001ddf7aafb` |
| `rtl/usb/audio_sample_buffer.sv` | `95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a` |
| `rtl/usb/usb_audio_host_top.sv` | `f47a5827ce0ea0f7d2f875c485d85ca27ff2a15dca831ceef8ec441f6365301f` |
| `rtl/usb/usb_control_transfer.sv` | `a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33` |
| `rtl/usb/max3421e_controller.sv` | `c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584` |
| `rtl/usb/max3421e_spi_bridge.sv` | `8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a` |
| `rtl/usb/usb_host_engine.sv` | `27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9` |
| `rtl/usb/usb_descriptor_parser.sv` | `f41dfa4254455a80a41a4f23caa2cfae3a59dc5271a27914763e2e56c7cec018` |
| `rtl/usb/usb_enumerator.sv` | `09adab96f7cc66c64f61c45cc5dc8461afa4b85771ca29ce0e55b85f2dfc8f2a` |
| `rtl/usb/usb_isochronous_receiver.sv` | `97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423` |
| `rtl/usb/usb_pcm_decoder.sv` | `075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075` |
| `rtl/spi/spi_frame_encoder.sv` | `54649703100540ec69c591d8607ff61d74426bc6d856404fdacc939f9643b410` |
| `rtl/spi/spi.sv` | `ffbd6a3608277cae10e6e81b7275c41a1470f83733008900e35ac9ecaeba556d` |
| `rtl/spi/spi_uc.sv` | `271e1a3705e099d052b02c9e389727b038bbe707d8bd13523aeab516d4df6238` |
| `rtl/top/aces2_usb_audio_top.sv` | `4d46d61e61c10fc602c754d65b7e313daccf9260b80dd2fecbc233b64596bc9d` |
| `third_party/spi-fpga-core/rtl/spi_master.sv` | `83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc` |
| `third_party/spi-fpga-core/rtl/spi_fifo.sv` | `1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad` |
| `obj_dir/usb/board/Vaces2_usb_audio_top_tb` | `6c8d7abd59f34798bc4ff37b3e11c09850f10b4a48e2f221eac5c626816d3deb` |

SHA-256 for the earlier long-run source set and executable (before RTL width
cleanup):

| File | SHA-256 |
| --- | --- |
| `tb/usb/aces2_usb_audio_top_tb.sv` | `8928785ffb44b0cd8814e557362c66ee339fda2e03dbfd0652655e49b4fd6ab2` |
| `tb/usb/Makefile` | `6e8f6c32db958b518d2c977e9b1f03ef25d11f04e7ec716fc00e73c7fb524a23` |
| `obj_dir/usb/board/Vaces2_usb_audio_top_tb` | `b4efa93969ea242b6d8896b7ac76143fa3b65f57f916846f674991e96aac4f3f` |

SHA-256 for an earlier rate-assertion replay (before RTL width cleanup):

| File | SHA-256 |
| --- | --- |
| `tb/usb/aces2_usb_audio_top_tb.sv` | `790ecba85bbc000b19d46c0a103529565ce6a501d409b9eebcd8ae53c59b4ace` (rate assertion run) |
| `rtl/top/aces2_usb_audio_top.sv` | `4d46d61e61c10fc602c754d65b7e313daccf9260b80dd2fecbc233b64596bc9d` |
| `tb/usb/models/max3421e_um2_model.sv` | `ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c` |
| `rtl/spi/spi_frame_encoder.sv` | `6cc4fe86499be40ed482a984821b8d8d827fc1c1633ac0c7ccfe0213c0d7cb4c` |
| `rtl/spi/spi.sv` | `ffbd6a3608277cae10e6e81b7275c41a1470f83733008900e35ac9ecaeba556d` |
| `rtl/spi/spi_uc.sv` | `271e1a3705e099d052b02c9e389727b038bbe707d8bd13523aeab516d4df6238` |

## Current-source replay after profile and diagnostic updates (2026-11-02)

Command:

```sh
make -C tb/usb BUILD=/tmp/aces2_usb_diagnostics board_long
```

Result from Verilator 5.052:

```text
PASS aces2_usb_audio_top_tb LONG_RUN: model packets=1000 host samples=48000 discarded=0 verified GPIO frames=3428 payload=47992 expected complete=3428 tail=8 seq=0..3427
- Verilator: $finish at 1s; walltime 531.571 s; speed 1.897 ms/s
- Verilator: cpu 529.583 s on 1 threads; allocated 4 MB
```

This replay includes the current USB profile parameters and the sticky LEDR4
assertion in the board testbench. The MAX3421E/UM2 behavioral model produced
1,000 1 ms packets; the host delivered 48,000 stereo frames; no PCM samples or
GPIO frames were discarded. The GPIO monitor checked all 3,428 complete
transactions, including sequence continuity, CRC-32, left/right PCM values and
SCK spacing. The last eight sample words remain below the encoder's 14-word
transaction threshold. This is simulation through FPGA GPIO, not a physical
capture by the ESP32 or UDP backend.

## Physical bring-up status (2026-11-02)

The updated wrapper has been programmed to the DE10-Lite. The user measured
4.8 V at USB-A VBUS both with the UM2 connected and disconnected, within the
4.75–5.25 V target. The UM2 power indicator and DE10-Lite LEDR0–4 pattern are
the next observations; physical enumeration/audio capture remain unverified.
The board regression above verifies pin mapping/reset behavior in simulation
only.

Source and executable hashes for this replay:

| File | SHA-256 |
| --- | --- |
| `tb/usb/aces2_usb_audio_top_tb.sv` | `17d7bdfa29c81334730b4d9bdbb7f2411abf23d513742b7380ce64ce4213f175` |
| `tb/usb/Makefile` | `6e8f6c32db958b518d2c977e9b1f03ef25d11f04e7ec716fc00e73c7fb524a23` |
| `tb/usb/models/max3421e_um2_model.sv` | `ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c` |
| `tb/usb/pcm2902_device.mem` | `73864b28ff3a032c84608080a9beed2d34796bdb3aa98d159fc6da29f3e1f48a` |
| `tb/usb/pcm2902_config.mem` | `b1bafbfbfcad8d9f45a76f53ea3d0624c897e781318f70e8d98f3001ddf7aafb` |
| `rtl/top/aces2_usb_audio_top.sv` | `0f6e39450f7875f01b644e30c4f4a618b2029fa1a0d967de427c259d9da315e4` |
| `rtl/usb/audio_sample_buffer.sv` | `95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a` |
| `rtl/usb/usb_audio_host_top.sv` | `349a3ac658bb279dda5c42d76cc56f55335eb39fadb55c538bc610127a94cd93` |
| `rtl/usb/usb_control_transfer.sv` | `a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33` |
| `rtl/usb/max3421e_controller.sv` | `c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584` |
| `rtl/usb/max3421e_spi_bridge.sv` | `8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a` |
| `rtl/usb/usb_host_engine.sv` | `27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9` |
| `rtl/usb/usb_descriptor_parser.sv` | `8920978ca8f5dbe4d3d36667e22b46e8ecc9896c02c1716252ef52f7953ce11e` |
| `rtl/usb/usb_enumerator.sv` | `450be28ab28dc50e6e2f2be4c1c52c8e7edc1d8595d61020c4061a635d7d2a97` |
| `rtl/usb/usb_isochronous_receiver.sv` | `97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423` |
| `rtl/usb/usb_pcm_decoder.sv` | `075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075` |
| `rtl/spi/spi_frame_encoder.sv` | `54649703100540ec69c591d8607ff61d74426bc6d856404fdacc939f9643b410` |
| `rtl/spi/spi.sv` | `ffbd6a3608277cae10e6e81b7275c41a1470f83733008900e35ac9ecaeba556d` |
| `rtl/spi/spi_uc.sv` | `271e1a3705e099d052b02c9e389727b038bbe707d8bd13523aeab516d4df6238` |
| `third_party/spi-fpga-core/rtl/spi_master.sv` | `83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc` |
| `third_party/spi-fpga-core/rtl/spi_fifo.sv` | `1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad` |
| `/tmp/aces2_usb_diagnostics/board/Vaces2_usb_audio_top_tb` | `42839660d32658ec484fb757318c6160a288899ec1946edd53980f0c1a768f7e` |
