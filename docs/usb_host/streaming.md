# USB audio receive and isochronous scheduling

`usb_audio_host_top` composes the MAX3421E controller, host engine, EP0
enumerator, PCM packet decoder, and synchronous sample FIFO. All of these blocks
use the same 50 MHz clock. The physical USB host controller supplies full-speed
SOF/interrupt observations; there is no synthetic frame counter or clock-domain
crossing in this path.

Streaming is enabled only after the controller is initialized, a connected
full-speed device is enumerated, and the selected capture profile is stereo
16-bit 48 kHz with interval 1, an IN endpoint, and an advertised packet maximum
no larger than 256 bytes. The endpoint address and advertised maximum come
from enumeration, so the scheduler follows the discovered endpoint. For the
characterized UM2 profile this is interface 2 alternate 1, endpoint 0x84, with
a 196-byte maximum.

The receiver observes merged controller/engine SOF pulses. For an eligible tick
with no request, response, or staged packet outstanding, it queues one ISO-IN
token using the enumerated device address (1) and endpoint number. It never
queues catch-up requests. A tick while occupied increments `missed_frames_o`.
If the host engine has not accepted a queued request by the default 250 us local
deadline, the receiver withdraws its valid request and counts a missed frame;
this is an intentional deadline cancellation, so ready/valid stability applies
until the deadline and then the request is explicitly abandoned. If no SOF
pulse arrives for 2.1 ms of local time, the receiver increments the same
counter once per 2.1 ms watchdog window and restarts its local gap timer. An
observed SOF after at least 1.5 ms also adds one estimated missed interval if
the watchdog has not already reported that gap; its arrival resets the timer.
The 1.5 ms
threshold absorbs ordinary 1 ms spacing plus polling jitter while detecting a
single omitted SOF. These are estimated gap events, not exact USB frame IDs.
If several SOFs are coalesced into one observed pulse, the local counter cannot
recover their exact number.

The host response is always drained immediately so MAX3421E receive banks are
released without waiting for downstream PCM. One complete packet can be staged
for the decoder. The staged packet remains stable until accepted. If a response
fails, exceeds the enumerated packet maximum, arrives while the staging slot is
occupied, or arrives during disconnect flush, the complete packet is dropped
and counted. Decoder malformed-packet pulses contribute to top-level
drop/protocol counters. The sample FIFO applies ordinary ready/valid
backpressure to decoded frames. A producer stalled by a full FIFO retains its
current sample and is not counted as a dropped packet; `overflow_o` reports a
blocked transfer, not a lost transfer.

`frame_count_o` counts observed SOF pulses while streaming. `packet_count_o`
counts successful host transactions, including a successful transaction later
dropped for size or staging reasons. `dropped_packets_o` counts rejected whole
packets plus decoder-rejected malformed packets. FIFO backpressure is not loss.
`missed_frames_o` counts busy ticks,
expired queued requests, and local-clock SOF-gap events. `protocol_errors_o`
counts host transaction errors, oversized/malformed packets, unexpected host
responses, and enumeration errors. `sample_count_o` counts frames accepted by
the downstream consumer. These counters clear only on reset. Disconnect,
engine reinitialization, or a newly reported enumeration error flushes queued
audio and partial decoder state; the top-level high-water output retains its
maximum since reset even though the underlying FIFO clears its local high-water
mark on flush.

The top exports aggregate fault and protocol counters rather than the low-level
control/enumerator error codes or configuration/interface/alternate metadata.
It exposes the FIFO high-water mark, not instantaneous occupancy. The FIFO's
`valid && !ready` overflow indication is intentionally not counted as loss: the
ready/valid producer keeps the sample until the consumer can accept it.

The host request owner is latched when the engine accepts a control or ISO
request. Its eventual response is routed to that owner even if enumeration
cancels or changes state meanwhile. This keeps late control responses from
being interpreted as audio and ensures disconnect cancellation drains the
engine before reuse.

No end-to-end losslessness claim is made for an indefinitely stalled sample
consumer. The default 256-frame FIFO holds about 5.33 ms of stereo 48 kHz audio;
when it fills, the decoder and one-packet staging slot can back up, and later
isochronous packets are dropped rather than replayed. The fixed 9-bit
high-water output supports FIFO depths through 511 entries. Integration should
check the counters and prove that the real consumer sustains the required rate.
