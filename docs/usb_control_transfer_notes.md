# USB EP0 control transfers

`usb_control_transfer` adapts the enumerator's complete control request API to
`usb_host_engine` token transactions. The setup word packs USB byte 0 in bits
`[7:0]`; all multibyte setup fields are little-endian. The controller supports
IN data requests with `bRequest=GET_DESCRIPTOR` (`0x06`) and up to 2048 bytes,
plus standard zero-data `SET_ADDRESS`, `SET_CONFIGURATION`, and
`SET_INTERFACE` requests. It rejects unsupported requests, OUT data stages,
length disagreement, and illegal full-speed EP0 sizes (only 8, 16, 32, or 64).

It sends SETUP using token `0x10` with exactly eight setup bytes. For a data
stage, it issues EP0 IN (`0x00`), initially forcing DATA1 after SETUP and then
allowing the MAX3421E's toggle state to advance across consecutive packets.
Each successful host response is already an atomic, drained packet. The
controller validates the complete packet length against EP0 size and remaining
requested bytes before exposing any byte on the upper ready/valid stream. A
short packet or zero-length packet ends the data stage. Exactly the requested
byte count also ends the stage. A packet that exceeds either bound fails the
whole control transfer rather than being silently truncated.

IN data requests finish with HS-OUT (`0xa0`); no-data control writes finish with
HS-IN (`0x80`). Both encode the required DATA1 status handshake in the MAX3421E.
`ctrl_done_o` pulses only after successful status completion. `ctrl_error_o`
pulses for invalid/unsupported requests, host errors, exhausted NAK retries,
timeout, cancellation, and malformed/oversized packets. The optional
`ctrl_error_code_o` classifies controller-detected failures; a generic host
error covers STALL and other terminal host-engine HRSL/backend errors.

NAK is retried up to `NAK_RETRY_LIMIT` times per stage (default 8 retries).
Retries occur before any bytes from that packet are released, preventing
duplicate bytes after a NAK. `CTRL_TIMEOUT_CYCLES` is an overall deadline from
request acceptance through packet backpressure and status (default 5 seconds
at 50 MHz). Cancellation/timeout asks the host engine to abort an in-flight
token and waits for its response before returning idle. Reset clears local
packet and byte state. The enumerator must assert cancellation on disconnect;
the controller itself has no separate connection-status input.

The implementation does not provide arbitrary OUT data stages, class/vendor
requests, high-speed EP0 sizes, or recovery from a host-engine backend fault.
The USB 2.0 specification defines short-packet termination and requires the
status stage; the MAX3421E Programming Guide describes SETUP and the special
HS-OUT/HS-IN status tokens (pp. 13–15). These saved references are under
`docs/usb_host/references/`.
