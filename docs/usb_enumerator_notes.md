# USB descriptor parser and enumeration sequencer

## Scope and boundary

`rtl/usb/usb_enumerator.sv` performs the descriptor and standard-request sequence over an abstract control-transfer interface. It does not generate USB tokens, PIDs, CRCs, handshakes, retries, or MAX3421E SPI transactions. A separate control-transfer backend must connect to the enumerator ports.

The characterized target is the UM2 / PCM2902 (`08bb:2902`). Device identification is parameterized by VID/PID. The parser's default profile is PCM Type I, stereo, 16-bit at 48 kHz and service interval 1. `TARGET_ENDPOINT=0` (the default) selects the first matching isochronous IN endpoint; an explicit endpoint can be required by setting `TARGET_ENDPOINT`. Minimum and maximum advertised packet sizes are parameters, defaulting to 4 and 256 bytes. With the captured UM2 descriptors and default parameters, the selected endpoint is `0x84`, alternate setting 1, with `wMaxPacketSize=196`. The interface number and alternate setting are discovered from bytes and exposed as outputs. The captured descriptor evidence is under `hardware/um2/`; the test memory image `tb/usb/pcm2902_config.mem` contains the 1191-byte configuration descriptor copied from the saved sysfs descriptor blob, excluding the preceding 18-byte device descriptor.

## Control-transfer contract

Each request uses `ctrl_req_valid_o` / `ctrl_req_ready_i`. `ctrl_setup_o[63:0]` carries the eight setup bytes in wire order, byte 0 in bits `[7:0]`; multibyte setup fields are little-endian. `ctrl_in_length_o` is the requested IN data length (zero for no-data requests). `ctrl_address_o` and `ctrl_ep0_size_o` tell the backend which device address and EP0 packet size to use. The backend streams IN data using `ctrl_data_i`, `ctrl_data_valid_i`, and `ctrl_data_ready_o`.

`ctrl_done_i` means the entire control transfer has completed, including its status stage. `ctrl_error_i` means the backend has reached an unrecoverable transfer error. The backend must honor backpressure and abort an active transfer when `ctrl_cancel_o` is asserted. `ctrl_cancel_o` is asserted during reset, when `connected_i` is low, and while the enumerator is in its terminal error state.

Enumeration sequence:

1. At address 0, GET_DEVICE_DESCRIPTOR with `wLength=8`; validate descriptor prefix and accept EP0 sizes 8, 16, 32, or 64.
2. GET_DEVICE_DESCRIPTOR with `wLength=18`; validate length/type, target VID/PID, EP0 packet-size encoding, and one or more configurations.
3. SET_ADDRESS(1); update the exposed address only after the control transfer's status stage completes; wait `2 ms` (`CLK_HZ` parameter) before another request.
4. At address 1, GET_CONFIGURATION_DESCRIPTOR with `wLength=9`; check type, nonzero configuration value, and `9 <= wTotalLength <= MAX_CONFIG_BYTES`.
5. GET_CONFIGURATION_DESCRIPTOR with `wLength=wTotalLength`; stream all bytes to the parser and require exactly the declared number of bytes.
6. SET_CONFIGURATION using the value observed in the descriptor, then SET_INTERFACE using the selected interface and alternate setting.
7. Assert `enumerated_o` only after the SET_INTERFACE status stage completes.

Each accepted request/transfer is subject to `CTRL_TIMEOUT_CYCLES`. A stuck request-ready handshake and a transfer that does not complete both enter terminal error and assert cancellation. `enum_error_code_o` distinguishes backend error, timeout, malformed device descriptor, device identity/field mismatch, malformed configuration header, short/long configuration body, parser/profile failure, and internal illegal state. Error recovery is explicit: disconnect (`connected_i=0`) or reset clears state/address/metadata and allows another enumeration attempt. There is no hidden retry loop.

## Parser behavior and limits

`usb_descriptor_parser.sv` consumes one byte per valid/ready handshake. It accepts a declared configuration length of 9 through 2048 bytes, checks every descriptor `bLength` against minimums and the remaining byte count, and stores one descriptor in a bounded 255-byte scratch array. Unknown descriptor types are skipped by their validated length. It checks configuration `wTotalLength`, declared versus distinct interface numbers, per-alternate endpoint counts, relevant AudioStreaming general/format descriptors, and endpoint descriptors. A profile match requires:

- Audio class / Streaming subclass interface alternate
- AS_GENERAL PCM format tag
- FORMAT_TYPE_I with the configured channel count, subframe size, bit resolution, and target sample rate (defaults: 2 channels, 2-byte subframe, 16 bits, 48 kHz)
- IN endpoint, isochronous transfer type, interval 1, no high-bandwidth transaction bits, and packet size within the configured minimum/maximum (defaults: 4–256 bytes); `TARGET_ENDPOINT=0` is a wildcard, otherwise the endpoint address must match exactly

For discrete sample rates, `bLength` must exactly match the advertised frequency count. Continuous rates must have the exact 14-byte descriptor form and the target rate must fall in the inclusive advertised range. Malformed frequency lists fail parsing. The integrated top currently consumes only stereo S16 samples at interval 1, even though sample rate, endpoint, and packet bounds are configurable. The parser does not preserve or interpret string contents, HID report contents, every AudioControl semantic, or profiles outside its configurable PCM Type-I shape. Its output is a selected advertised profile, not proof of successful traffic or audio capture.

## Verification

The committed tests use Verilator and the captured UM2 configuration bytes:

```sh
verilator --binary --timing -Wno-fatal --top-module usb_descriptor_parser_tb \
  --Mdir /tmp/usb-parser-build rtl/usb/usb_descriptor_parser.sv tb/usb/usb_descriptor_parser_tb.sv
/tmp/usb-parser-build/Vusb_descriptor_parser_tb

verilator --binary --timing -Wno-fatal --top-module usb_enumerator_tb \
  --Mdir /tmp/usb-enumerator-build rtl/usb/usb_descriptor_parser.sv \
  rtl/usb/usb_enumerator.sv tb/usb/usb_enumerator_tb.sv
/tmp/usb-enumerator-build/Vusb_enumerator_tb
```

The parser test checks the real configuration (including all 1191 bytes), expected interface/alt/endpoint/rate/packet metadata, a valid seven-byte endpoint descriptor whose interval is its final byte, a descriptor length crossing the config boundary, inconsistent `wTotalLength`, a truncated discrete-frequency list, an endpoint count mismatch, and a malformed trailing interface descriptor after a valid earlier profile. The enumerator test checks request setup byte ordering and stage lengths/addresses, full successful sequencing, disconnect clearing, an incomplete control-transfer timeout, and a stalled request-ready timeout. The control-transfer model is synthetic; no physical host-control transaction is performed by these RTL tests.
