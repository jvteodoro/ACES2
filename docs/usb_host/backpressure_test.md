# USB audio FIFO backpressure test

`tb/usb/usb_audio_backpressure_tb.sv` exercises the real 50 MHz MAX3421E SPI
host, enumerator, ISO receiver, PCM decoder, and 256-frame sample FIFO against
the read-only timing-aware MAX3421E/UM2 model in
`tb/usb/models/max3421e_um2_model.sv`. The model transfers USB payload bytes at
full-speed cadence and emits a deterministic stereo sequence with the sample
ID in the left channel and its bitwise complement in the right channel.

The bench first holds the consumer for 1 ms and checks lossless ordered
recovery. It then holds `sample_ready_i` low for 12 ms, verifies that FIFO
high-water reaches 256 while source frames continue, and checks that the host
reports missed frames or dropped packets without raising a protocol error. On
resume it waits 14 more observed frames, enough to drain the FIFO backlog and
receive at least three fresh frames. The scoreboard permits consecutive frame
gaps but rejects sample reordering, duplicates, channel corruption, and large
unexplained jumps; after the stream settles, total missing sample IDs must
exactly equal the model's `lost_sample_count_o`.

Run from the repository root:

```sh
verilator --binary --timing -Wno-fatal --top-module usb_audio_backpressure_tb \
  --Mdir /tmp/aces2_backpressure_obj \
  tb/usb/usb_audio_backpressure_tb.sv tb/usb/models/max3421e_um2_model.sv \
  rtl/usb/usb_audio_host_top.sv rtl/usb/usb_isochronous_receiver.sv \
  rtl/usb/usb_control_transfer.sv rtl/usb/usb_enumerator.sv \
  rtl/usb/usb_descriptor_parser.sv rtl/usb/usb_host_engine.sv \
  rtl/usb/max3421e_controller.sv rtl/usb/max3421e_spi_bridge.sv \
  rtl/usb/usb_pcm_decoder.sv rtl/usb/audio_sample_buffer.sv \
  rtl/spi/spi.sv rtl/spi/spi_uc.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv
timeout 100s /tmp/aces2_backpressure_obj/Vusb_audio_backpressure_tb
```

Verified with Verilator 5.052 on the registered-MOSI source set,
`spi_master.sv` SHA-256
`83be588c0847e808ffc7dbe683f77e9f61abec9427bf761bc0a2cb2b17e0cdbc`. Result:
`PASS backpressure`; high-water 256, 30 model frames, 24 successful packets,
6 top-level missed-frame events, 0 whole-packet drops, and 287 source samples
lost and matched by 287 observed sample-ID gaps. The consumer accepted 1105
ordered samples after recovery. Wall time was 4.346 s after build.
The long stall's losses were represented as skipped frame requests, so the
receiver's whole-packet drop counter remained zero; this is expected and the
bench requires the missed-frame or dropped-packet counters to declare the
condition.

This is a bounded-stall behavior test, not a claim of indefinite losslessness.
Once the FIFO and packet path back up, isochronous frames cannot be replayed.
