# USB PCM receive path

`usb_pcm_decoder` consumes complete USB packet payloads atomically and emits
32-bit stereo frames as `{right16,left16}`. The first supported UM2 profile is
interface 2, alternate 1, endpoint 0x84 IN: stereo S16_LE at 48 kHz. The
descriptor advertises a maximum packet size of 196 bytes. The decoder and
behavioral model exercise 188-, 192-, and 196-byte payloads; these correspond
to 47, 48, and 49 stereo frames. They are modeled/tested lengths, not measured
USB capture sizes. Bytes
arrive packed little-endian, left sample first, then right sample. Sign bits are
preserved by direct bit slicing.

The packet input must provide at least 256 bytes of payload storage. A packet
with a USB error, a length not divisible by four, or a length above 256 bytes
is dropped whole and raises `malformed_o` for one cycle. A zero-length packet is
accepted and produces no frames. The decoder accepts a new packet only while
it has no frames pending, and holds its current frame stable until the consumer
asserts ready. `flush_i` clears pending frames on reset/disconnect so data from
an earlier connection cannot escape afterward.

`audio_sample_buffer` is a synchronous FIFO (default depth 256) between the
decoder and downstream audio logic. Producer and consumer use ready/valid;
full plus a simultaneous pop permits a replacement push. `overflow_o` pulses
only when a valid producer transfer is blocked. A ready consumer on an empty
FIFO is not an underflow because the interface has no explicit pop request.
`occupancy_o` reports current entries and `high_water_o` tracks the maximum
occupancy since reset/flush. Flush clears both counters and all queued data.

The decoder and buffer assume the same 50 MHz clock. No clock-domain crossing
is needed in this path. If a USB controller or audio sink runs in another clock
domain, insert a proper asynchronous FIFO across that boundary. Packet atomicity
avoids partial-packet loss inside the decoder, but sustained system-level
losslessness still requires the downstream buffer not to fill; integrate and
size it against actual producer and consumer rates before claiming end-to-end
losslessness.
