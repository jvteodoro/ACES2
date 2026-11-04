#!/usr/bin/env python3
"""Create a low-level stereo tone for checking UM2→FPGA PCM capture."""

import argparse
import math
import struct
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="um2_test_tone.wav")
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--left-hz", type=float, default=997.0)
    parser.add_argument("--right-hz", type=float, default=1597.0)
    parser.add_argument("--amplitude", type=float, default=0.1,
                        help="peak amplitude as a fraction of full scale")
    args = parser.parse_args()
    if args.seconds <= 0 or args.sample_rate <= 0:
        parser.error("seconds and sample-rate must be positive")
    if not 0 < args.amplitude <= 0.5:
        parser.error("amplitude must be in (0, 0.5] to leave headroom")
    if max(args.left_hz, args.right_hz) >= args.sample_rate / 2:
        parser.error("tone frequency must be below Nyquist")

    frames = round(args.seconds * args.sample_rate)
    peak = round(args.amplitude * 32767)
    pcm = bytearray()
    for n in range(frames):
        left = round(peak * math.sin(2 * math.pi * args.left_hz * n / args.sample_rate))
        right = round(peak * math.sin(2 * math.pi * args.right_hz * n / args.sample_rate))
        pcm.extend(struct.pack("<hh", left, right))
    with wave.open(args.output, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(args.sample_rate)
        wav.writeframes(pcm)
    print(f"{args.output}: {frames} stereo frames at {args.sample_rate} Hz; "
          f"left={args.left_hz:g} Hz, right={args.right_hz:g} Hz, peak={peak}")


if __name__ == "__main__":
    main()
