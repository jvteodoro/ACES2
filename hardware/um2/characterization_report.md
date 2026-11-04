# UM2 / PCM2902 characterization report

Date: 2026-11-01 (host observation)

## Identity and observed state

The connected device was `08bb:2902` (Texas Instruments PCM2902 Audio Codec), bus 001 device 006, sysfs path `/sys/bus/usb/devices/1-2`, full speed (12 Mbps). Sysfs reported `Burr-Brown from TI` / `USB Audio CODEC`, configuration value 1. Device descriptor EP0 maximum packet is 8 bytes. Raw evidence is retained in `device_descriptors.txt` (complete `lsusb -v`) and `device_descriptors.bin` (sysfs binary); `device_descriptors.json` is the parsed representation.

At inspection, ALSA playback was Running at interface 1 alt 1, stereo S16_LE 48 kHz, endpoint 0x02 OUT, reported packet size 192. Capture was Stop at interface 2. Its 18 altsets are retained in `alsa_capabilities.txt`. Capture alt 1 advertises stereo S16_LE 48 kHz, endpoint 0x84 IN, descriptor maximum 196 bytes. Alt 10 advertises mono S16_LE 16 kHz, maximum 34 bytes. Descriptor maxima are not measurements of actual packets.

## ALSA observations and capture side effect

A restricted-context attempt to run `arecord -l/-L` returned no devices, and a `hw:1,0` probe failed with “Cannot get card index for 1.” These were sandbox-limited results. Retrying with host access succeeded: CODEC is capture card 1, device 0, with `default:CARD=CODEC`, `sysdefault:CARD=CODEC`, and `front:CARD=CODEC,DEV=0` aliases. Host `arecord --dump-hw-params` reported S8/S16_LE, channels 1–2, rates 8–48 kHz, period sizes 16–48000, periods 2–1024, and buffer sizes 32–96000. The command then continued into recording and emitted PCM to stdout. A follow-up process check found the arecord PID 813689 still running; that exact process was terminated with SIGTERM. Follow-up checks found no arecord process, playback Running, and capture Stop. The PCM output was not saved as an artifact. This incident did not constitute controlled validation of audio quality or a target host capture profile.

`audio_stream_profile.json` selects `stereoS16_48k` (interface 2, alt 1). A later controlled native ALSA capture validated the requested PCM shape on the PC, as described below. USB packet cadence and FPGA-host acquisition remain unverified by physical measurement.

## Controlled one-second capture

After dynamically confirming `/proc/asound/card1/usbid` as `08bb:2902`, card ID `CODEC`, and capture state Stop, a bounded command opened `hw:CARD=CODEC,DEV=0` directly: stereo S16_LE, 48000 Hz, WAV, duration one second, with an outer five-second timeout. It completed successfully in about 1.013 seconds. `capture_48k_stereo_1s.wav` contains exactly 48000 stereo frames (192000 PCM bytes). The full command, file hash, dimensions, sample-value statistics, and before/after ALSA stream states are retained in `controlled_capture.json`. Capture was Stop afterward and playback remained Running.

This used the native `hw:` PCM, without ALSA plug-format conversion. The alternate-setting mapping comes from the unique matching advertised profile; no SET_INTERFACE URB was observed. The signal was quiet, with sample values from -13 to +6; there was no calibrated input stimulus, so this is not an audio-quality test. It does not establish individual USB payload lengths, transfer timing, or FPGA operation. An additional noninteractive read-access check using `sudo -n` failed because a password is required; usbmon remained unavailable.

## Other inspection

- `lsusb -d 08bb:2902 -v` completed with host USB access; its complete output is retained.
- A dynamic VID/PID search found `/sys/bus/usb/devices/1-2`; read-only identity, speed, configuration, strings, and descriptor attributes were inspected.
- `/sys/kernel/debug/usb/usbmon/1u` remained unreadable (`Permission denied`) even with host access. No transfer-level URB trace was obtained; no mount or module operation was attempted.
- The HID interface advertises a 31-byte report descriptor. Although `lsusb -v` reports its body unavailable, a later read-only inspection found it under the Linux HID bus at `/sys/bus/hid/devices/0003:08BB:2902.0001/report_descriptor`. The 31 observed bytes are retained in `hid_report_descriptor.bin` and `.txt`, with structured interpretation in `.json`. The report has three one-bit Consumer-page usages (Mute, Volume Increment, Volume Decrement), followed by five constant padding bits, with no report ID. The usage names come from the USB-IF HID Usage Tables, saved under `docs/usb_host/references/`. These are advertised controls; no physical button event was exercised.
- `scripts/parse_descriptors.py` passed structural checks for device identity, configuration bounds (1191 bytes), interface and alternate settings, and capture endpoint values. All 3 parser unit tests pass.

## Limits

The evidence establishes enumerated descriptors and ALSA-advertised capabilities on this PC. It does not establish measured capture payload cadence, actual packet lengths, audio quality, transfer error rates, or behavior on the planned FPGA host. The selected profile remains a planning choice based on advertised evidence.

## Recheck on 2026-11-02

The device was again visible at `/sys/bus/usb/devices/1-2`; its `idVendor` and
`idProduct` read `08bb` and `2902`. `/proc/asound/card1/usbid` reported the same
identity, and `/proc/asound/card1/stream0` reported capture interface 2 alt 1
as stereo S16_LE at 48 kHz on endpoint `0x84` IN. Capture was stopped while
playback on interface 1 alt 1 was running at stereo S16_LE/48 kHz. This
read-only check did not start capture or observe USB transfers. The sandbox's
`lsusb` could not initialize libusb (`-99`), ALSA tools could not open/list the
device although procfs exposed it, and usbmon remained inaccessible. The UM2
was therefore available on the PC for inspection, but not connected to the
FPGA/MAX3421E host.
