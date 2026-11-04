# Integrated USB host model runs

Date: 2026-11-01. All runs use Verilator 5.052, `--timing`, and the actual
SPI-facing `usb_audio_host_top`; no USB or SPI RTL is bypassed. C++ builds use
`-CFLAGS -O3`. The full stream test retains the 50 MHz system clock, 25 MHz
SPI, USB full-speed byte cadence (33/34 system clocks per byte), and 1 ms SOF.

## Results

### Full stream and recovery

Command:

```sh
/tmp/um2_final_o3/Vusb_audio_host_tb
```

Exit code 0; simulation covered 1.000 s of USB frames. Output:

```text
PASS normal stream: frames=1000 packets=1000 PCM=48000 bytes=1200 bank=2/1690 cyc byte-gap=33..34 PCM-latency=8178..8680 cyc avg=8411
Missed-frame injection: model/top missed=1/1 lost=47 scoreboard gap=47 samples
Disconnect injected mid-packet at source byte 80/196
Reconnect recovery: fresh enum complete, packets resumed to 10
PASS injected ISO overrun/recovery: overrun=1 drop=1 lost/gap samples=49/49 resumed packets=1
PASS usb_audio_host_tb; SPI transactions=104202 setup/status=14/14 USB errors=1
- Verilator: $finish at 1s; walltime 117.320 s; speed 8.816 ms/s
```

The control enumeration stages were 7 SETUPs and 7 status stages, with 26
device-descriptor bytes and 1200 configuration-descriptor bytes (the 9-byte
header plus the 1191-byte captured configuration). The normal stream accepted
exactly 48,000 samples with no sequence gaps or drops. PCM integrity checks the
right channel is the complement of the left and the left channel equals the
known source sample index. The latency metric maps that source index to its
recorded SOF cycle and measures through `sample_valid && sample_ready`; it is a
digital model pipeline latency, not ADC conversion latency.

The missed-SOF test records exactly 47 source samples lost and the same 47
sample-index gap at the PCM output; both model and host missed-frame counters
increment. Disconnect occurs after byte 80 of a 196-byte packet. Reconnect
performs a fresh enumeration and delivers at least 10 packets. The injected
overrun is counted at its source, then the test waits for the host packet-drop
counter and the next successful packet and PCM samples. The subsequent sequence
gap is 49 samples, matching the model's lost-sample count.

### Full-path smoke

The `+SMOKE` run checks the same physical SPI/control path and at least 10
stream packets over 12 model frames. It passes with 11 packets and 528 samples,
bank high-water 2, bank release latency 1690 clocks, and digital PCM latency
8178 to 8680 clocks.

### Default reset timing

Built with `-GFAST_INIT=0`, the smoke run uses the RTL's 100 ms debounce and
50 ms bus reset, plus 5 ms MAX oscillator startup. It passes the same control
enumeration and 12-frame stream check. Verilator reports 172 ms simulated time,
18.427 s wall time.

### Slow SPI negative case

Built with `-GCLK_HZ=10000000`, the MAX SPI runs at 5 MHz while USB byte timing
remains full-speed. The run passes as a negative bandwidth test: both receive
banks fill, bank release latency reaches 2718 clocks, and 11 overruns are
recorded. No PCM packets are accepted.

### Control fault injections

Each isolated run exits successfully after the host surfaces the injected
failure: `+FAULT_STALL`, `+FAULT_CRC`, `+FAULT_TIMEOUT`, and
`+FAULT_NAK_EXHAUST`. The last case observed nine NAK responses. These cover
control enumeration error handling; the CRC case is not an ISO CRC test.

## Reproduction build

Run from the repository root:

```sh
verilator --binary --timing -Wno-fatal -j 0 -CFLAGS -O3 \
  --top-module usb_audio_host_tb --Mdir /tmp/um2_final_o3 \
  tb/usb/models/max3421e_um2_model.sv rtl/usb/usb_audio_host_top.sv \
  rtl/usb/max3421e_controller.sv rtl/usb/max3421e_spi_bridge.sv \
  rtl/usb/usb_host_engine.sv rtl/usb/usb_control_transfer.sv \
  rtl/usb/usb_enumerator.sv rtl/usb/usb_descriptor_parser.sv \
  rtl/usb/usb_isochronous_receiver.sv rtl/usb/usb_pcm_decoder.sv \
  rtl/usb/audio_sample_buffer.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv tb/usb/usb_audio_host_tb.sv
```

Use the same source list with a distinct `--Mdir` and `-GFAST_INIT=0` for the
default reset timing run, or `-GCLK_HZ=10000000` for the slow SPI run. Run the
binary from the repository root so the captured descriptor `.mem` files load.

## Frozen source hashes for the earlier replay

These hashes identify the earlier full run above, before the explicit RTL
width cleanup. The current-source replay and its matching hashes follow below.

```text
ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c  tb/usb/models/max3421e_um2_model.sv
c1de26eafdf6ac4b6d4ca93a19f9d50bb6e21f8237343a5adfe2bc7a5b128fbe  tb/usb/usb_audio_host_tb.sv
f47a5827ce0ea0f7d2f875c485d85ca27ff2a15dca831ceef8ec441f6365301f  rtl/usb/usb_audio_host_top.sv
dff68324945bdcedaef6e779d645d812ac0902af61c1a58319609f0800c217e7  rtl/usb/max3421e_controller.sv
c5b51aa42c73941af383938e0c11f234258acbe3432680f984aa89dedb23837a  rtl/usb/max3421e_spi_bridge.sv
b6216249b7c7b30de8d34cb7fe5a74c5ad1db0226a8f62e9296aa243d873983c  rtl/usb/usb_host_engine.sv
a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33  rtl/usb/usb_control_transfer.sv
09adab96f7cc66c64f61c45cc5dc8461afa4b85771ca29ce0e55b85f2dfc8f2a  rtl/usb/usb_enumerator.sv
aeaccdf7580f41ac0dc3bbadaae17d0c9b23a907d7e6c06c21c94f2e66173c40  rtl/usb/usb_descriptor_parser.sv
97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423  rtl/usb/usb_isochronous_receiver.sv
a978e658c96fd3f6c388480f1ca7f5895a07d29487911b0aa24ddd831bd64300  rtl/usb/usb_pcm_decoder.sv
d174535469a3126dbfa582dfeb860f84396bd5386d4444daf531f13d3ec35d26  rtl/usb/audio_sample_buffer.sv
83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc  third_party/spi-fpga-core/rtl/spi_master.sv
1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad  third_party/spi-fpga-core/rtl/spi_fifo.sv
73864b28ff3a032c84608080a9beed2d34796bdb3aa98d159fc6da29f3e1f48a  tb/usb/pcm2902_device.mem
b1bafbfbfcad8d9f45a76f53ea3d0624c897e781318f70e8d98f3001ddf7aafb  tb/usb/pcm2902_config.mem
```

This earlier O3 result used the registered-MOSI source set before width cleanup.

## Replay after width cleanup (source snapshot 2026-11-01)

Rebuilt with Verilator 5.052 in `/tmp/usb_host_current_o3` after explicit RTL
width cleanup. The 1-second stream passed in 75.123 s wall time with the same
1,000 packets, 48,000 samples, 1,690-cycle first-bank release, exact 47-sample
missed-frame gap, disconnect/re-enumeration, and exact 49-sample overrun gap.
The same binary passed `+SMOKE`, `+FAULT_STALL`, `+FAULT_CRC`,
`+FAULT_TIMEOUT`, and `+FAULT_NAK_EXHAUST` (nine NAK responses). The
`-GFAST_INIT=0` smoke passed with the default 100 ms debounce, 50 ms reset,
and 5 ms oscillator startup. The `-GCLK_HZ=10000000` negative case still
reported 5 MHz SPI, 2,718-cycle bank latency, and 11 overruns.

Source and executable SHA-256 for the 2026-11-01 snapshot:

```text
ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c  tb/usb/models/max3421e_um2_model.sv
c1de26eafdf6ac4b6d4ca93a19f9d50bb6e21f8237343a5adfe2bc7a5b128fbe  tb/usb/usb_audio_host_tb.sv
f47a5827ce0ea0f7d2f875c485d85ca27ff2a15dca831ceef8ec441f6365301f  rtl/usb/usb_audio_host_top.sv
c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584  rtl/usb/max3421e_controller.sv
8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a  rtl/usb/max3421e_spi_bridge.sv
27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9  rtl/usb/usb_host_engine.sv
a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33  rtl/usb/usb_control_transfer.sv
09adab96f7cc66c64f61c45cc5dc8461afa4b85771ca29ce0e55b85f2dfc8f2a  rtl/usb/usb_enumerator.sv
f41dfa4254455a80a41a4f23caa2cfae3a59dc5271a27914763e2e56c7cec018  rtl/usb/usb_descriptor_parser.sv
97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423  rtl/usb/usb_isochronous_receiver.sv
075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075  rtl/usb/usb_pcm_decoder.sv
95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a  rtl/usb/audio_sample_buffer.sv
83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc  third_party/spi-fpga-core/rtl/spi_master.sv
1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad  third_party/spi-fpga-core/rtl/spi_fifo.sv
73864b28ff3a032c84608080a9beed2d34796bdb3aa98d159fc6da29f3e1f48a  tb/usb/pcm2902_device.mem
b1bafbfbfcad8d9f45a76f53ea3d0624c897e781318f70e8d98f3001ddf7aafb  tb/usb/pcm2902_config.mem
02e9de92ef0b45d6c53e7e0ac3972ee8821df40dd7645b2b7417e657a4739e7f  /tmp/usb_host_current_o3/Vusb_audio_host_tb
```

This integrated test accepts PCM at the host sample interface. It does not
prove reception by a physical ESP32; the separate GPIO board-long regression
checks the modeled path through the FPGA pins.

## Current-source replay after USB profile updates (2026-11-02)

Rebuilt against the parser/enum profile parameters and `usb_audio_host_top`
hashes listed below, using Verilator 5.052, `--timing`, and `-CFLAGS -O3`.
Command:

```sh
verilator --binary --timing -Wno-fatal -j 0 -CFLAGS -O3 \
  --top-module usb_audio_host_tb --Mdir /tmp/um2_usb_current_o3 \
  tb/usb/models/max3421e_um2_model.sv rtl/usb/usb_audio_host_top.sv \
  rtl/usb/max3421e_controller.sv rtl/usb/max3421e_spi_bridge.sv \
  rtl/usb/usb_host_engine.sv rtl/usb/usb_control_transfer.sv \
  rtl/usb/usb_enumerator.sv rtl/usb/usb_descriptor_parser.sv \
  rtl/usb/usb_isochronous_receiver.sv rtl/usb/usb_pcm_decoder.sv \
  rtl/usb/audio_sample_buffer.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv tb/usb/usb_audio_host_tb.sv
timeout 300s /tmp/um2_usb_current_o3/Vusb_audio_host_tb
```

The replay passed in 40.932 s. It covered 1,000 SOFs and ISO packets, exactly
48,000 PCM frames, with no normal-stream losses. The 1,690-cycle first-bank
release and 33/34-cycle byte cadence matched the earlier run. Injected missing
SOF lost exactly 47 samples; disconnect at byte 80/196 re-enumerated; injected
ISO overrun produced an exact 49-sample loss and stream recovery. The output was:

```text
PASS normal stream: frames=1000 packets=1000 PCM=48000 bytes=1200 bank=2/1690 cyc byte-gap=33..34 PCM-latency=8178..8680 cyc avg=8411
Missed-frame injection: model/top missed=1/1 lost=47 scoreboard gap=47 samples
Disconnect injected mid-packet at source byte 80/196
Reconnect recovery: fresh enum complete, packets resumed to 10
PASS injected ISO overrun/recovery: overrun=1 drop=1 lost/gap samples=49/49 resumed packets=1
PASS usb_audio_host_tb; SPI transactions=104202 setup/status=14/14 USB errors=1
- Verilator: $finish at 1s; walltime 40.932 s; speed 25.268 ms/s
- Verilator: cpu 40.822 s on 1 threads; allocated 5 MB
```

Current source and executable SHA-256:

```text
ff2c4205541e291ed6eee386a23a5028a026165995da72b5c1c301716a91bb7c  tb/usb/models/max3421e_um2_model.sv
c1de26eafdf6ac4b6d4ca93a19f9d50bb6e21f8237343a5adfe2bc7a5b128fbe  tb/usb/usb_audio_host_tb.sv
349a3ac658bb279dda5c42d76cc56f55335eb39fadb55c538bc610127a94cd93  rtl/usb/usb_audio_host_top.sv
c101d3000a8137ec6710761fc24072b074aba9ccc7ddc2e304d28f2652432584  rtl/usb/max3421e_controller.sv
8084c0c3942ebc8ec3a8e0ab2f2d61f34b2f6d979f94a60c693fd4aed9aba84a  rtl/usb/max3421e_spi_bridge.sv
27f21742234b6f341b2b1886f674a178ac26ecd2d1b2510e90204519ea8e39c9  rtl/usb/usb_host_engine.sv
a761209cb2e26caf8ec477f0153ba500bf3c74e0cdb23aeade4820ed55bf6b33  rtl/usb/usb_control_transfer.sv
450be28ab28dc50e6e2f2be4c1c52c8e7edc1d8595d61020c4061a635d7d2a97  rtl/usb/usb_enumerator.sv
8920978ca8f5dbe4d3d36667e22b46e8ecc9896c02c1716252ef52f7953ce11e  rtl/usb/usb_descriptor_parser.sv
97eb747c1f28a7211aa6a118f31b79d20b1d933fe915f08280f155cbd7796423  rtl/usb/usb_isochronous_receiver.sv
075ae2494c57aa21c7ea33f8eaef54182100c5b0035af271dadfd56860046075  rtl/usb/usb_pcm_decoder.sv
95dc41b262a8e26becd5960db005b18c684015d3bbf5bb304729622d9489603a  rtl/usb/audio_sample_buffer.sv
83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc  third_party/spi-fpga-core/rtl/spi_master.sv
1c8b396df50fb83201fad9971b6aaaab3ceae4ac450052e65d22165404e0ddad  third_party/spi-fpga-core/rtl/spi_fifo.sv
73864b28ff3a032c84608080a9beed2d34796bdb3aa98d159fc6da29f3e1f48a  tb/usb/pcm2902_device.mem
b1bafbfbfcad8d9f45a76f53ea3d0624c897e781318f70e8d98f3001ddf7aafb  tb/usb/pcm2902_config.mem
f6b1ed2814d610019c33e4f4e9933cf37e886121f3704bd07f8ad3801d0ad9ef  /tmp/um2_usb_current_o3/Vusb_audio_host_tb
```
